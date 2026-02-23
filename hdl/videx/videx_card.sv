//
// Videx VideoTerm 80-Column Card Emulation
//
// (c) 2025 A2FPGA contributors
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Description:
//
// Combined Videx VideoTerm emulation providing:
//   - Firmware ROM (1 KB VideoTerm ROM 2.4 in distributed RAM)
//   - MC6845 CRTC register file (R0-R15, all readable per HD6845SP Type 1)
//   - 2 KB VRAM via GoWin SDPB primitive (8-bit write, 32-bit read)
//   - C8-space ownership matching real Videx PAL16L8 behavior
//   - a2mem_if VIDEX_* signals for the VIDEX_LINE renderer
//
// Follows the Mockingboard/SSC slot_if.card pattern.
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
// io_strobe_n-based gating causes PR#3 to hang (root cause TBD).
//
// Mode Switching:
//
// VIDEX_MODE = card_enable (always active when card is configured in slot).
// The 40/80-column switch is controlled by AN0 ($C058/$C059), matching
// real Videx hardware and A2DVI. The rendering gate in apple_video.sv is:
//   VIDEX_LINE active when (VIDEX_MODE && TEXT_MODE && AN0)
// Ctrl-Reset clears AN0 via Autostart ROM ($FA6F), restoring 40-col mode.
//

module videx_card #(
    parameter bit [7:0] ID = 5,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave   a2bus_if,
    a2mem_if.videx   a2mem_if,
    slot_if.card     slot_if,

    output [7:0]     data_o,
    output           rd_en_o,
    output           rom_en_o,

    // Scanner VRAM read port (wired to apple_video VIDEX_LINE pipeline)
    input [8:0]      videx_vram_addr_i,
    input            videx_vram_rd_i,
    output [31:0]    videx_vram_data_o
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
    // was tried but causes PR#3 to hang (root cause TBD). The is_iie fix
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

    // Drive a2mem_if VIDEX signals for the VIDEX_LINE renderer.
    // VIDEX_MODE = card_enable: card is always "in mode" when configured.
    // The actual 40/80-col switch is controlled by AN0 in apple_video.sv.
    assign a2mem_if.VIDEX_MODE     = card_enable;
    assign a2mem_if.VIDEX_CRTC_R9  = {4'h0, crtc_regs[9][3:0]};
    assign a2mem_if.VIDEX_CRTC_R10 = crtc_regs[10];
    assign a2mem_if.VIDEX_CRTC_R11 = crtc_regs[11];
    assign a2mem_if.VIDEX_CRTC_R12 = crtc_regs[12];
    assign a2mem_if.VIDEX_CRTC_R13 = crtc_regs[13];
    assign a2mem_if.VIDEX_CRTC_R14 = crtc_regs[14];
    assign a2mem_if.VIDEX_CRTC_R15 = crtc_regs[15];

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

    // Muxed read port: scanner has priority.
    // cpu_vram_rd is phi0-qualified to prevent spurious reads during phi1
    // from corrupting the CPU hold register.
    wire cpu_vram_rd = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;
    wire [8:0]  vram_rd_addr = videx_vram_rd_i ? videx_vram_addr_i : vram_addr[10:2];
    wire        vram_rd_en   = videx_vram_rd_i || cpu_vram_rd;
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
        scanner_rd_d1 <= videx_vram_rd_i;
        scanner_rd_d2 <= scanner_rd_d1;
        cpu_rd_d1 <= cpu_vram_rd && !videx_vram_rd_i;
        cpu_rd_d2 <= cpu_rd_d1;
    end

    // Scanner hold register: captures 32-bit word for apple_video
    reg [31:0] scanner_hold;

    always_ff @(posedge a2bus_if.clk_logic) begin
        if (scanner_rd_d2)
            scanner_hold <= vram_rd_data;
    end

    assign videx_vram_data_o = scanner_hold;

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
    // Read Response Signals
    // ========================================================================

    wire slot_rom_read = card_io_sel && a2bus_if.rw_n;

    // C8-space reads gated by phi0 and c8_owned directly (not io_strobe_n).
    // io_strobe_n was tried but caused PR#3 hang because INTC8ROM was
    // permanently set on ][+ (fixed by is_iie in apple_memory.sv).
    // TODO: Consider switching to card_io_strobe now that is_iie prevents
    // the INTC8ROM bug. This would add INTC8ROM protection for IIe support.
    wire exp_rom_read  = rom_c8_active && a2bus_if.phi0 && exp_rom_range && a2bus_if.rw_n;

    // VRAM CPU read-back disabled: real Videx (HD6845SP) and A2DVI both
    // return open bus for $CC00-$CDFF reads. Only scanner reads VRAM.
    // wire vram_read  = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;

    assign rd_en_o = card_enable && (crtc_read || slot_rom_read || exp_rom_read);

    // data_o mux: CRTC (combinational) > ROM (registered)
    assign data_o = crtc_read    ? crtc_data :
                    rom_data_rr;

endmodule
