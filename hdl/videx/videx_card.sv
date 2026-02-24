//
// Videx VideoTerm 80-Column Card Emulation
//
// Copyright (c) 2026 Brent Rector
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// Description:
//
// Self-contained Videx VideoTerm emulation providing:
//   - Firmware ROM (1 KB VideoTerm ROM 2.4 in distributed RAM)
//   - MC6845 CRTC register file (R0-R15, all readable per HD6845SP Type 1)
//   - 2 KB VRAM via GoWin SDPB primitive (8-bit write, 32-bit read)
//   - C8-space ownership matching real Videx PAL16L8 behavior
//   - Complete 80-column rendering pipeline (character ROM, cursor, color)
//   - Video mux: outputs Videx pixels when active, passes through Apple video
//
// Follows the SuperSprite video mux pattern: receives Apple video RGB in,
// outputs either Videx-rendered or pass-through Apple video RGB out.
// Follows the Mockingboard/SSC slot_if.card pattern for bus logic.
// See VIDEX_IMPLEMENTATION_SPEC.md for complete hardware behavior spec.
//
// C8-Space Ownership:
//
// Based on real Videx PAL16L8 behavior with FPGA-specific additions:
//   - SET when slot ROM is accessed (card_io_sel = /IOSEL equivalent)
//   - CLEARED when $CFFF is accessed or another slot's $Csxx is accessed
// The other-slot clearing prevents bus contention in the shared FPGA
// bus mux (real hardware has per-slot bus transceivers).
// C8 read responses are gated by phi0 directly (not io_strobe_n).
// io_strobe_n-based gating causes PR#3 to hang (probable SLOTROM timing mismatch).
//
// Mode Switching:
//
// videx_active = card_enable && TEXT_MODE && AN0.
// The 40/80-column switch is controlled by AN0 ($C058/$C059), matching
// real Videx hardware and A2DVI. Ctrl-Reset clears AN0 via Autostart ROM
// ($FA6F), restoring 40-col mode.
//

module videx_card #(
    parameter bit [7:0] ID = 5,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave   a2bus_if,
    a2mem_if.slave   a2mem_if,
    slot_if.card     slot_if,

    output [7:0]     data_o,
    output           rd_en_o,
    output           rom_en_o,

    // Video chain: SuperSprite mux pattern
    input wire [9:0] screen_x_i,
    input wire [9:0] screen_y_i,
    input [7:0]      apple_vga_r_i,
    input [7:0]      apple_vga_g_i,
    input [7:0]      apple_vga_b_i,
    output [7:0]     videx_r_o,
    output [7:0]     videx_g_o,
    output [7:0]     videx_b_o
);

    // ========================================================================
    // Card Enable (standard Mockingboard/SSC pattern)
    // ========================================================================

    reg card_enable;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            card_enable <= 1'b0;
        end else if (!slot_if.config_select_n) begin
            if (slot_if.slot == 3'd0)
                card_enable <= 1'b0;
            else if (slot_if.card_id == ID)
                card_enable <= slot_if.card_enable && ENABLE;
        end
    end

    wire card_sel       = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
    wire card_dev_sel   = card_sel && !slot_if.dev_select_n;
    wire card_io_sel    = card_sel && !slot_if.io_select_n;
    wire card_io_strobe = !slot_if.io_strobe_n && a2bus_if.phi0;

    // ========================================================================
    // Address Decode
    // ========================================================================

    wire vram_window   = (a2bus_if.addr[15:9] == 7'b1100_110);   // $CC00-$CDFF
    wire exp_rom_range = (a2bus_if.addr[15:10] == 6'b110010);    // $C800-$CBFF
    wire cfff_access   = a2bus_if.phi0 && (a2bus_if.addr == 16'hCFFF); // phi0-qualified like other_slot_rom

    // Detect other-slot $Csxx ROM access ($C100-$C7FF, slot != 3).
    // phi0-qualified to avoid transient address matches during phi1.
    wire other_slot_rom = a2bus_if.phi0 &&
                          (a2bus_if.addr[15:11] == 5'b1100_0) &&  // $C100-$C7FF
                          (a2bus_if.addr[10:8] != 3'd3) &&        // not slot 3
                          (a2bus_if.addr[10:8] != 3'd0);          // not $C0xx

    // ========================================================================
    // C8-Space Ownership
    // ========================================================================
    //
    // Ownership set on /IOSEL (slot ROM access at $C3xx), cleared on $CFFF
    // or when another slot's $Csxx ROM space is accessed. The other-slot
    // clearing prevents bus contention when multiple cards claim C8 space
    // (e.g., accessing $C200 for SSC should stop Videx responding to $C800).
    //
    // Read responses are gated by phi0 directly. io_strobe_n-based gating
    // was tried but causes PR#3 to hang (probable SLOTROM timing mismatch). The is_iie fix
    // in apple_memory.sv keeps INTC8ROM=0 on ][+ for correct ownership.

    reg c8_owned;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            c8_owned <= 1'b0;
        end else if (card_io_sel) begin
            c8_owned <= 1'b1;
        end else if (!a2mem_if.INTCXROM && (cfff_access || other_slot_rom)) begin
            c8_owned <= 1'b0;
        end
    end

    wire rom_c8_active = c8_owned && !a2mem_if.INTCXROM;
    assign rom_en_o = rom_c8_active;

    // ========================================================================
    // Firmware ROM (1 KB in distributed RAM / LUTs, not BSRAM)
    // ========================================================================

    reg [7:0] rom[0:1023] /*synthesis syn_ramstyle="distributed_ram"*/;
    initial $readmemh("videx_rom.hex", rom);

    // ROM address mux:
    //   Slot ROM ($C300-$C3FF): rom[{2'b11, addr[7:0]}] = offset $300-$3FF
    //   Expansion ROM ($C800-$CBFF): rom[addr[9:0]] = offset $000-$3FF
    wire [9:0] rom_addr = card_io_sel ? {2'b11, a2bus_if.addr[7:0]} : a2bus_if.addr[9:0];

    // 2-stage pipeline read for GoWin distributed RAM inference
    reg [7:0] rom_data_r;
    reg [7:0] rom_data_rr;

    always_ff @(posedge a2bus_if.clk_logic) begin
        rom_data_r  <= rom[rom_addr];
        rom_data_rr <= rom_data_r;
    end

    // ========================================================================
    // CRTC Register File (R0-R15, all readable per HD6845SP Type 1)
    // ========================================================================

    reg [4:0] crtc_idx;
    reg [7:0] crtc_regs[0:15];

    // ========================================================================
    // Bank Selection
    // ========================================================================

    reg [1:0] bank_sel;

    // ========================================================================
    // CRTC + Bank Writes (phi1_posedge, direct address decode)
    // ========================================================================

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            crtc_idx <= 5'h0;
            bank_sel <= 2'b0;
            for (int i = 0; i < 16; i++)
                crtc_regs[i] <= 8'h00;
        end else if (a2bus_if.phi1_posedge && !a2bus_if.m2sel_n &&
                     (a2bus_if.addr[15:4] == 12'hC0B) && card_enable) begin
            // Bank selection on ANY $C0Bx access (read or write)
            bank_sel <= a2bus_if.addr[3:2];

            // CRTC register writes only
            if (!a2bus_if.rw_n) begin
                if (!a2bus_if.addr[0])                  // even addr = index select
                    crtc_idx <= a2bus_if.data[4:0];
                else if (crtc_idx < 5'd16)              // odd addr = data write
                    crtc_regs[crtc_idx] <= a2bus_if.data[7:0];
            end
        end
    end

    // CRTC read: All R0-R15 readable (HD6845SP Type 1 / A2DVI behavior).
    // Even addr ($C0B0): address/status register -> always $00
    //   (Physical Videx returns $00 in VIDEX_DIAG T01, matching this)
    // Odd addr ($C0B1): data register -> R0-R15 return written value, R16+ -> $00
    wire crtc_read = card_dev_sel && a2bus_if.rw_n;
    wire [7:0] crtc_data = (a2bus_if.addr[0] && crtc_idx < 5'd16)
                         ? crtc_regs[crtc_idx] : 8'h00;

    // ========================================================================
    // VRAM (2 KB, GoWin SDPB primitive with asymmetric port widths)
    //   Write port: 8-bit (2048 byte entries), native byte addressing
    //   Read port:  32-bit (512 word entries), muxed scanner/CPU
    //   Uses 1 SDPB block -- avoids 4-block byte_enable splitting penalty.
    //   Hold registers capture each consumer's data after the 2-cycle
    //   SDPB pipeline. Extra clk_logic cycle invisible to clk_pixel.
    // ========================================================================

    // VRAM byte address: {bank_sel, addr[8:0]} = 11 bits -> 2048 bytes
    wire [10:0] vram_addr = {bank_sel, a2bus_if.addr[8:0]};

    // VRAM write: qualified by ownership, not by io_strobe_n (writes are
    // internal to the card and don't affect the bus).
    wire vram_we = !a2bus_if.rw_n && a2bus_if.data_in_strobe &&
                   rom_c8_active && vram_window;

    // Scanner VRAM read signals (directly access SDPB read port)
    // Declared here before use in the muxed read port logic.
    reg [8:0] scanner_vram_addr;
    reg scanner_vram_rd;

    // Muxed read port: scanner has priority.
    // cpu_vram_rd is phi0-qualified to prevent spurious reads during phi1
    // from corrupting the CPU hold register.
    wire cpu_vram_rd = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;
    wire [8:0]  vram_rd_addr = scanner_vram_rd ? scanner_vram_addr : vram_addr[10:2];
    wire        vram_rd_en   = scanner_vram_rd || cpu_vram_rd;
    wire [31:0] vram_rd_data;

    // GoWin SDPB primitive: 1 block for 2 KB VRAM
    //   Port A (write): BIT_WIDTH_0=8  -> ADA[13:3]=byte_addr, ADA[2:0]=0
    //   Port B (read):  BIT_WIDTH_1=32 -> ADB[13:5]=word_addr, ADB[4:0]=0
    SDPB videx_vram (
        .CLKA(a2bus_if.clk_logic),
        .CEA(vram_we),
        .RESETA(1'b0),
        .BLKSELA(3'b000),
        .ADA({vram_addr, 3'b000}),
        .DI({24'b0, a2bus_if.data}),

        .CLKB(a2bus_if.clk_logic),
        .CEB(vram_rd_en),
        .RESETB(1'b0),
        .OCE(1'b1),
        .BLKSELB(3'b000),
        .ADB({vram_rd_addr, 5'b00000}),
        .DO(vram_rd_data)
    );
    defparam videx_vram.READ_MODE   = 1'b1;    // Pipeline (2-cycle latency)
    defparam videx_vram.BIT_WIDTH_0 = 8;       // Write: 8-bit
    defparam videx_vram.BIT_WIDTH_1 = 32;      // Read: 32-bit
    defparam videx_vram.RESET_MODE  = "SYNC";
    defparam videx_vram.BLK_SEL_0   = 3'b000;
    defparam videx_vram.BLK_SEL_1   = 3'b000;

    // Track read sources through SDPB's 2-cycle pipeline
    reg scanner_rd_d1, scanner_rd_d2;
    reg cpu_rd_d1, cpu_rd_d2;

    always_ff @(posedge a2bus_if.clk_logic) begin
        scanner_rd_d1 <= scanner_vram_rd;
        scanner_rd_d2 <= scanner_rd_d1;
        cpu_rd_d1 <= cpu_vram_rd && !scanner_vram_rd;
        cpu_rd_d2 <= cpu_rd_d1;
    end

    // Scanner hold register: captures 32-bit word for rendering pipeline
    reg [31:0] scanner_hold;

    always_ff @(posedge a2bus_if.clk_logic) begin
        if (scanner_rd_d2)
            scanner_hold <= vram_rd_data;
    end

    // CPU hold register: captures 32-bit word for CPU read-back
    reg [31:0] cpu_hold;

    always_ff @(posedge a2bus_if.clk_logic) begin
        if (cpu_rd_d2)
            cpu_hold <= vram_rd_data;
    end

    // CPU read byte extraction (byte_sel stable for entire bus cycle)
    reg [1:0] vram_byte_sel_r;
    reg [1:0] vram_byte_sel_rr;

    always_ff @(posedge a2bus_if.clk_logic) begin
        vram_byte_sel_r  <= vram_addr[1:0];
        vram_byte_sel_rr <= vram_byte_sel_r;
    end

    wire [7:0] vram_read_byte = vram_byte_sel_rr == 2'd0 ? cpu_hold[7:0] :
                                vram_byte_sel_rr == 2'd1 ? cpu_hold[15:8] :
                                vram_byte_sel_rr == 2'd2 ? cpu_hold[23:16] :
                                                           cpu_hold[31:24];

    // ========================================================================
    // Video Mode State (latched during blanking for stability)
    // ========================================================================

    localparam [9:0] SCREEN_WIDTH = 720;
    localparam [9:0] SCREEN_HEIGHT = 480;

    wire blanking_active_w = (screen_x_i > SCREEN_WIDTH) | (screen_y_i > SCREEN_HEIGHT);

    reg text_mode_r;
    reg an0_r;
    reg [3:0] text_color_r;
    reg [3:0] background_color_r;
    reg [3:0] border_color_r;

    // CRTC registers latched during blanking (from internal register file)
    reg [7:0] videx_r10_r, videx_r11_r;
    reg [7:0] videx_r12_r, videx_r13_r, videx_r14_r, videx_r15_r;

    always @(posedge a2bus_if.clk_pixel) begin
        if (blanking_active_w) begin
            text_mode_r      <= a2mem_if.TEXT_MODE;
            an0_r            <= a2mem_if.AN0;
            text_color_r     <= a2mem_if.TEXT_COLOR;
            background_color_r <= a2mem_if.BACKGROUND_COLOR;
            border_color_r   <= a2mem_if.BORDER_COLOR;
            videx_r10_r      <= crtc_regs[10];
            videx_r11_r      <= crtc_regs[11];
            videx_r12_r      <= crtc_regs[12];
            videx_r13_r      <= crtc_regs[13];
            videx_r14_r      <= crtc_regs[14];
            videx_r15_r      <= crtc_regs[15];
        end
    end

    wire videx_active = card_enable && text_mode_r && an0_r;

    // ========================================================================
    // Display Geometry
    // ========================================================================

    localparam [9:0] WINDOW_WIDTH = 560;
    localparam [9:0] VIDEX_WINDOW_HEIGHT = 432;    // 9 scanlines x 24 rows x 2 (doubling)
    localparam [9:0] H_BORDER = (SCREEN_WIDTH - WINDOW_WIDTH) / 2;   // 80
    localparam [9:0] VIDEX_V_BORDER = (SCREEN_HEIGHT - VIDEX_WINDOW_HEIGHT) / 2;  // 24

    localparam [9:0] H_LEFT_BORDER = H_BORDER - 1;
    localparam [9:0] H_RIGHT_BORDER = H_BORDER + WINDOW_WIDTH;
    localparam [9:0] VIDEX_V_TOP_BORDER = VIDEX_V_BORDER - 1;
    localparam [9:0] VIDEX_V_BOTTOM_BORDER = VIDEX_V_BORDER + VIDEX_WINDOW_HEIGHT;

    localparam STEP_LENGTH = 28;
    localparam PIX_BUFFER_SIZE = STEP_LENGTH + 1;  // 29
    localparam PIX_HISTORY_SIZE = 8;
    localparam SCAN_PIX_OFFSET = STEP_LENGTH + PIX_HISTORY_SIZE - 4;  // 32

    wire x_active_w = (screen_x_i > H_LEFT_BORDER) & (screen_x_i < H_RIGHT_BORDER);
    wire y_active_w = (screen_y_i > VIDEX_V_TOP_BORDER) & (screen_y_i < VIDEX_V_BOTTOM_BORDER);
    wire videx_pixel_active = videx_active & x_active_w & y_active_w;

    wire scan_x_active_w = (screen_x_i > (H_LEFT_BORDER - SCAN_PIX_OFFSET)) & (screen_x_i < (H_RIGHT_BORDER - SCAN_PIX_OFFSET));
    wire scan_active_w = scan_x_active_w & y_active_w;
    wire scan_start_w = (screen_x_i == (H_LEFT_BORDER - SCAN_PIX_OFFSET)) & y_active_w;

    // ========================================================================
    // Videx Geometry Calculations
    // ========================================================================

    wire [10:0] videx_text_base_w = {videx_r12_r[2:0], videx_r13_r};
    wire [10:0] videx_cursor_addr_w = {videx_r14_r[2:0], videx_r15_r};

    // Content line after removing doubling: (screen_y - border) / 2, max 215
    wire [9:0] videx_content_y_full_w = (screen_y_i - VIDEX_V_BORDER) >> 1;
    wire [7:0] videx_content_y_w = (screen_y_i > VIDEX_V_TOP_BORDER) ?
        videx_content_y_full_w[7:0] : 8'd0;

    // Divide by 9: row = (content_y * 57) >> 9
    wire [13:0] videx_div9_w = videx_content_y_w * 8'd57;
    wire [4:0] videx_row_w = videx_div9_w[13:9];

    // Scanline within row: content_y - row * 9
    wire [7:0] videx_row_x9_w = {videx_row_w[4:0], 3'b0} + {3'b0, videx_row_w[4:0]};
    wire [7:0] videx_scanline_full_w = videx_content_y_w - videx_row_x9_w;
    wire [3:0] videx_scanline_w = videx_scanline_full_w[3:0];

    // ========================================================================
    // Character ROM (2 KB half-size, 128 chars x 16 scanlines)
    // Chars 0x80-0xFF are inverse of 0x00-0x7F, generated by XOR at capture
    // ========================================================================

    reg [10:0] videxrom_a_r;
    reg [7:0] videxrom_d_r;
    reg [7:0] videxrom_r[2047:0];
    initial $readmemh("videx_charrom.hex", videxrom_r, 0);
    always @(posedge a2bus_if.clk_pixel) videxrom_d_r <= videxrom_r[videxrom_a_r];

    // ========================================================================
    // Cursor Logic
    // ========================================================================

    wire [1:0] videx_cursor_blink_mode_w = videx_r10_r[6:5];
    wire [3:0] videx_cursor_start_line_w = videx_r10_r[3:0];
    wire [3:0] videx_cursor_end_line_w = videx_r11_r[3:0];

    reg videx_frame_edge_r;
    reg [5:0] videx_frame_cnt_r;
    always @(posedge a2bus_if.clk_pixel) begin
        videx_frame_edge_r <= (screen_y_i >= SCREEN_HEIGHT);
        if ((screen_y_i >= SCREEN_HEIGHT) && !videx_frame_edge_r)
            videx_frame_cnt_r <= videx_frame_cnt_r + 1'b1;
    end

    wire videx_cursor_blink_w =
        (videx_cursor_blink_mode_w == 2'b00) ? 1'b1 :
        (videx_cursor_blink_mode_w == 2'b01) ? 1'b0 :
        (videx_cursor_blink_mode_w == 2'b10) ? videx_frame_cnt_r[3] :
        videx_frame_cnt_r[4];
    wire videx_cursor_scanline_w = (videx_scanline_w >= videx_cursor_start_line_w) &&
                                    (videx_scanline_w <= videx_cursor_end_line_w);

    // ========================================================================
    // Rendering Pipeline (28-step pixel cycle)
    // ========================================================================

    localparam [4:0] STEP_FIRST = 0;
    localparam [4:0] STEP_LAST = STEP_LENGTH - 1;
    localparam [4:0] STEP_LOAD_MEM = STEP_FIRST;
    localparam [4:0] STEP_LATCH_MEM = 14;

    reg [4:0] pix_step_r;
    reg [5:0] h_offset_r;
    reg [31:0] videx_data_r;
    reg [PIX_BUFFER_SIZE-1:0] pix_buffer_r;
    reg [PIX_BUFFER_SIZE-1:0] pix_shift_r /* synthesis syn_srlstyle = "registers" */;
    wire pix_out_w = pix_shift_r[0];

    // VRAM address computation
    wire [10:0] videx_row_x80_w = ({videx_row_w, 6'd0}) + ({2'b0, videx_row_w, 4'd0});
    wire [10:0] videx_line_start_w = (videx_text_base_w + videx_row_x80_w) & 11'h7FF;
    wire [10:0] videx_char_addr_w = (videx_line_start_w + {4'b0, h_offset_r, 1'b0}) & 11'h7FF;

    // Cursor matching
    wire [10:0] videx_cursor_delta_w = (videx_cursor_addr_w - videx_char_addr_w) & 11'h7FF;
    wire videx_cursor_in_group_w = videx_cursor_delta_w < 11'd4;
    wire [1:0] videx_cursor_byte_w = videx_cursor_delta_w[1:0];
    wire videx_cursor_active_w = videx_cursor_blink_w && videx_cursor_scanline_w && videx_cursor_in_group_w;

    always @(posedge a2bus_if.clk_pixel) begin

        pix_shift_r <= {1'b0, pix_shift_r[PIX_BUFFER_SIZE-1:1]};
        scanner_vram_rd <= 1'b0;

        if (scan_start_w) begin
            pix_step_r <= '0;
            h_offset_r <= '0;
        end else if (videx_active) begin
            pix_step_r <= (pix_step_r == STEP_LAST) ? 5'b0 : pix_step_r + 5'b1;
        end

        if (scan_active_w && videx_active) begin
            case (pix_step_r)
                // Issue VRAM read
                STEP_LOAD_MEM: begin
                    scanner_vram_addr <= videx_char_addr_w[10:2];
                    scanner_vram_rd <= 1'b1;
                end
                // Latch VRAM data from scanner hold register
                STEP_LATCH_MEM: begin
                    videx_data_r <= scanner_hold;
                    pix_buffer_r[28] <= 1'b0;
                end
                // Videx pipeline: 4 chars x 7 pixels = 28 pixels per cycle
                // Stage 0: Issue ROM lookup for char 0
                (STEP_LATCH_MEM + 5'd1): begin
                    videxrom_a_r <= {videx_data_r[6:0], videx_scanline_w};
                end
                // Stage 1: Issue ROM lookup for char 1
                (STEP_LATCH_MEM + 5'd2): begin
                    videxrom_a_r <= {videx_data_r[14:8], videx_scanline_w};
                end
                // Stage 2: Capture char 0 pixels, issue ROM lookup for char 2
                (STEP_LATCH_MEM + 5'd3): begin
                    pix_buffer_r[6:0] <= videxrom_d_r[6:0] ^
                        {7{videx_data_r[7] ^ (videx_cursor_active_w && videx_cursor_byte_w == 2'd0)}};
                    videxrom_a_r <= {videx_data_r[22:16], videx_scanline_w};
                end
                // Stage 3: Capture char 1 pixels, issue ROM lookup for char 3
                (STEP_LATCH_MEM + 5'd4): begin
                    pix_buffer_r[13:7] <= videxrom_d_r[6:0] ^
                        {7{videx_data_r[15] ^ (videx_cursor_active_w && videx_cursor_byte_w == 2'd1)}};
                    videxrom_a_r <= {videx_data_r[30:24], videx_scanline_w};
                end
                // Stage 4: Capture char 2 pixels
                (STEP_LATCH_MEM + 5'd5): begin
                    pix_buffer_r[20:14] <= videxrom_d_r[6:0] ^
                        {7{videx_data_r[23] ^ (videx_cursor_active_w && videx_cursor_byte_w == 2'd2)}};
                end
                // Stage 5: Capture char 3 pixels
                (STEP_LATCH_MEM + 5'd6): begin
                    pix_buffer_r[27:21] <= videxrom_d_r[6:0] ^
                        {7{videx_data_r[31] ^ (videx_cursor_active_w && videx_cursor_byte_w == 2'd3)}};
                end
                // Load shift register
                STEP_LAST: begin
                    h_offset_r <= h_offset_r + 6'd2;
                    pix_shift_r <= pix_buffer_r;
                end
            endcase
        end
    end

    // ========================================================================
    // Color Generation and Video Mux
    // ========================================================================

    wire GSP = a2bus_if.sw_gs;

    reg [11:0] palette_rgb_r[0:31] = '{
    // Apple II color palette for sRGB
        12'h000, 12'h924, 12'h42a, 12'hd4e,
        12'h064, 12'h888, 12'h39e, 12'hcbf,
        12'h450, 12'hc73, 12'h888, 12'hfac,
        12'h3c2, 12'hcd6, 12'h7ec, 12'hfff,
    // Apple IIgs color palette
        12'h000, 12'hd03, 12'h009, 12'hd2d,
        12'h072, 12'h555, 12'h22f, 12'h6af,
        12'h850, 12'hf60, 12'haaa, 12'hf98,
        12'h1d0, 12'hff0, 12'h4f9, 12'hfff
    };

    // Pixel history for alignment with apple_video's pipeline delay
    reg [PIX_HISTORY_SIZE-1:0] pix_history_r;

    localparam HISTORY_PIXEL_OFFSET = 4;

    reg [3:0] pix_color_r;

    always @(posedge a2bus_if.clk_pixel) begin
        pix_history_r <= {pix_out_w, pix_history_r[PIX_HISTORY_SIZE-1:1]};
        pix_color_r <= background_color_r;
        if (videx_pixel_active) begin
            if (pix_history_r[HISTORY_PIXEL_OFFSET])
                pix_color_r <= text_color_r;
        end else begin
            pix_color_r <= border_color_r;
        end
    end

    wire [11:0] pix_rgb = palette_rgb_r[{GSP, pix_color_r}];
    wire [3:0] pix_b = pix_rgb[3:0];
    wire [3:0] pix_g = pix_rgb[7:4];
    wire [3:0] pix_r = pix_rgb[11:8];

    // Video mux: Videx pixels when active, pass-through Apple video otherwise
    assign videx_r_o = videx_pixel_active ? {pix_r, 4'h0} : apple_vga_r_i;
    assign videx_g_o = videx_pixel_active ? {pix_g, 4'h0} : apple_vga_g_i;
    assign videx_b_o = videx_pixel_active ? {pix_b, 4'h0} : apple_vga_b_i;

    // ========================================================================
    // Read Response Signals
    // ========================================================================

    wire slot_rom_read = card_io_sel && a2bus_if.rw_n;

    // C8-space reads gated by phi0 and c8_owned directly (not io_strobe_n).
    // io_strobe_n-based gating was tried but causes PR#3 hang due to
    // SLOTROM timing mismatch (phi1_posedge update vs phi0 evaluation).
    wire exp_rom_read  = rom_c8_active && a2bus_if.phi0 && exp_rom_range && a2bus_if.rw_n;

    wire vram_read = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;

    assign rd_en_o = card_enable && (crtc_read || slot_rom_read || exp_rom_read || vram_read);

    // data_o mux: CRTC (combinational) > VRAM (registered) > ROM (registered)
    assign data_o = crtc_read ? crtc_data :
                    vram_read ? vram_read_byte :
                    rom_data_rr;

endmodule
