//
// Videx VideoTerm 80-Column Card — Combined Emulation Module
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
//   - Firmware ROM (1 KB VideoTerm ROM 2.4)
//   - MC6845 CRTC register file with R14/R15 read-back
//   - 2 KB VRAM via dual sdpram32 (scanner + CPU read-back)
//   - Expansion ROM ownership protocol
//   - a2mem_if VIDEX_* signals for the VIDEX_LINE renderer
//
// Follows the Mockingboard/SSC slot_if.card pattern.
// See VIDEX_IMPLEMENTATION_SPEC.md for complete hardware behavior spec.
//

module videx_card #(
    parameter bit [7:0] ID = 5,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave   a2bus_if,
    a2mem_if.videx   a2mem_if,       // writes VIDEX_* signals, reads INTCXROM
    slot_if.card     slot_if,

    output [7:0]     data_o,         // bus data for CPU reads
    output           rd_en_o,        // active when card drives data_o
    output           rom_en_o,       // C8 space ownership status

    // Scanner VRAM read port (wired to apple_video VIDEX_LINE pipeline)
    input [8:0]      videx_vram_addr_i,
    input            videx_vram_rd_i,
    output [31:0] videx_vram_data_o
);

    // ========================================================================
    // Card Enable (Mockingboard/SSC pattern, synchronous reset)
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
    wire cfff_access   = (a2bus_if.addr == 16'hCFFF);

    // ========================================================================
    // Expansion ROM Ownership (C8 space)
    // ========================================================================

    reg rom_ownership;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n)
            rom_ownership <= 1'b0;
        else if (card_io_sel)
            rom_ownership <= 1'b1;
        else if (!a2mem_if.INTCXROM && cfff_access)
            rom_ownership <= 1'b0;
    end

    wire rom_c8_active = rom_ownership && !a2mem_if.INTCXROM;
    assign rom_en_o = rom_c8_active;

    // ========================================================================
    // Firmware ROM (1 KB in BSRAM)
    // ========================================================================

    reg [7:0] rom[0:1023];
    initial $readmemh("videx_rom.hex", rom);

    // ROM address mux:
    //   Slot ROM ($C300-$C3FF): rom[{2'b11, addr[7:0]}] = offset $300-$3FF
    //   Expansion ROM ($C800-$CBFF): rom[addr[9:0]] = offset $000-$3FF
    wire [9:0] rom_addr = card_io_sel ? {2'b11, a2bus_if.addr[7:0]} : a2bus_if.addr[9:0];

    // 2-stage pipeline read for GoWin BSRAM inference
    reg [7:0] rom_data_r;
    reg [7:0] rom_data_rr;

    always_ff @(posedge a2bus_if.clk_logic) begin
        rom_data_r <= rom[rom_addr];
        rom_data_rr <= rom_data_r;
    end

    // ========================================================================
    // CRTC Register File (single copy, R0-R15)
    // ========================================================================

    reg [4:0] crtc_idx;
    reg [7:0] crtc_regs[0:15];
    reg videx_mode_r;

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
            videx_mode_r <= 1'b0;
            for (int i = 0; i < 16; i++)
                crtc_regs[i] <= 8'h00;
        end else if (a2bus_if.phi1_posedge && !a2bus_if.m2sel_n &&
                     (a2bus_if.addr[15:4] == 12'hC0B) && card_enable) begin
            // Bank selection on ANY $C0Bx access (read or write)
            bank_sel <= a2bus_if.addr[3:2];

            // CRTC register writes only
            if (!a2bus_if.rw_n) begin
                videx_mode_r <= 1'b1;  // Videx mode detected on first write
                if (!a2bus_if.addr[0])                  // even addr = index select
                    crtc_idx <= a2bus_if.data[4:0];
                else if (crtc_idx < 5'd16)              // odd addr = data write
                    crtc_regs[crtc_idx] <= a2bus_if.data[7:0];
            end
        end
    end

    // Drive a2mem_if VIDEX signals for the VIDEX_LINE renderer
    assign a2mem_if.VIDEX_MODE     = videx_mode_r;
    assign a2mem_if.VIDEX_CRTC_R9  = {4'h0, crtc_regs[9][3:0]};   // only [3:0] valid
    assign a2mem_if.VIDEX_CRTC_R10 = crtc_regs[10];
    assign a2mem_if.VIDEX_CRTC_R11 = crtc_regs[11];
    assign a2mem_if.VIDEX_CRTC_R12 = crtc_regs[12];
    assign a2mem_if.VIDEX_CRTC_R13 = crtc_regs[13];
    assign a2mem_if.VIDEX_CRTC_R14 = crtc_regs[14];
    assign a2mem_if.VIDEX_CRTC_R15 = crtc_regs[15];

    // CRTC read: R14/R15 only (MC6845 Type 0, R0-R13 write-only)
    wire crtc_readable = (crtc_idx == 5'd14) || (crtc_idx == 5'd15);
    wire crtc_read = card_dev_sel && a2bus_if.rw_n && a2bus_if.addr[0] && crtc_readable;

    // ========================================================================
    // VRAM (2 KB, two sdpram32 instances for GoWin BSRAM inference)
    //   Scanner VRAM: CPU writes + scanner reads (for apple_video)
    //   CPU VRAM:     CPU writes + CPU reads (for VRAM read-back)
    //   Both receive identical writes; separate read ports avoid DP inference
    //   issues that cause GoWin to use 4+ DPB blocks instead of 2 SDPB.
    // ========================================================================

    // VRAM address computation
    wire [10:0] vram_addr = {bank_sel, a2bus_if.addr[8:0]};
    wire [8:0]  vram_word_addr = vram_addr[10:2];
    wire [1:0]  vram_byte_sel  = vram_addr[1:0];

    // VRAM write control
    wire vram_we = !a2bus_if.rw_n && a2bus_if.data_in_strobe &&
                   rom_c8_active && vram_window;

    // Byte enable: replicate CPU byte into 32-bit word, select with byte_enable
    wire [31:0] vram_wdata = {a2bus_if.data, a2bus_if.data, a2bus_if.data, a2bus_if.data};
    wire [3:0]  vram_be = (4'b0001 << vram_byte_sel);

    // Scanner VRAM: CPU writes, scanner reads (sdpram32 = 1 SDPB)
    sdpram32 #(.ADDR_WIDTH(9)) videx_vram_scan (
        .clk(a2bus_if.clk_logic),
        .write_addr(vram_word_addr),
        .write_data(vram_wdata),
        .write_enable(vram_we),
        .byte_enable(vram_be),
        .read_addr(videx_vram_addr_i),
        .read_enable(videx_vram_rd_i),
        .read_data(videx_vram_data_o)
    );

    // CPU VRAM: CPU writes, CPU reads (sdpram32 = 1 SDPB)
    wire cpu_vram_rd = rom_c8_active && vram_window && a2bus_if.rw_n;
    wire [31:0] vram_cpu_data;

    sdpram32 #(.ADDR_WIDTH(9)) videx_vram_cpu (
        .clk(a2bus_if.clk_logic),
        .write_addr(vram_word_addr),
        .write_data(vram_wdata),
        .write_enable(vram_we),
        .byte_enable(vram_be),
        .read_addr(vram_word_addr),
        .read_enable(cpu_vram_rd),
        .read_data(vram_cpu_data)
    );

    // CPU read byte extraction (registered byte select for pipeline alignment)
    reg [1:0] vram_byte_sel_r;
    reg [1:0] vram_byte_sel_rr;

    always_ff @(posedge a2bus_if.clk_logic) begin
        vram_byte_sel_r <= vram_byte_sel;
        vram_byte_sel_rr <= vram_byte_sel_r;
    end

    wire [7:0] vram_read_byte = vram_byte_sel_rr == 2'd0 ? vram_cpu_data[7:0] :
                                vram_byte_sel_rr == 2'd1 ? vram_cpu_data[15:8] :
                                vram_byte_sel_rr == 2'd2 ? vram_cpu_data[23:16] :
                                                           vram_cpu_data[31:24];

    // ========================================================================
    // Read Response Signals
    // ========================================================================

    wire slot_rom_read = card_io_sel && a2bus_if.rw_n;
    wire exp_rom_read  = rom_c8_active && card_io_strobe && exp_rom_range && a2bus_if.rw_n;
    wire vram_read     = rom_c8_active && vram_window && a2bus_if.rw_n;

    // rd_en_o: card is driving data_o
    assign rd_en_o = card_enable && (crtc_read || slot_rom_read || exp_rom_read || vram_read);

    // data_o mux: CRTC (combinational) > VRAM (registered) > ROM (registered)
    assign data_o = crtc_read    ? crtc_regs[crtc_idx] :
                    vram_read    ? vram_read_byte :
                    rom_data_rr;

endmodule
