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
// Clock Domains:
//
// Two clock domains operate at a fixed 2:1 ratio from the same PLL:
//   - clk_logic (54 MHz): Bus interface, CRTC writes, VRAM read/write.
//     All Apple II bus timing (phi0, phi1_posedge, data_in_strobe) is
//     synchronous to this clock.
//   - clk_pixel (27 MHz): Rendering pipeline, character ROM lookup, pixel
//     shift register, color generation, video output. The 2:1 ratio means
//     each pixel clock cycle spans exactly 2 logic clock cycles, so the
//     SDPB's 2-cycle read pipeline completes within one pixel step.
//   No explicit clock-domain crossing synchronizers are needed because
//   both clocks share the same PLL and maintain a fixed phase relationship.
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
// real Videx hardware. Ctrl-Reset clears AN0 via Autostart ROM
// ($FA6F), restoring 40-col mode.
//

module videx_card #(
    parameter bit [7:0] ID = 5,         // Card ID from slots.hex (5 = Videx)
    parameter bit ENABLE = 1'b1         // Build-time enable/disable
) (
    a2bus_if.slave   a2bus_if,          // Apple II bus (active-low signals, dual clock)
    a2mem_if.slave   a2mem_if,          // Memory soft-switches (TEXT_MODE, AN0, colors, etc.)
    slot_if.card     slot_if,           // Slot interface (select signals, config, card_id)

    output [7:0]     data_o,            // Data bus output (ROM, CRTC, or VRAM read data)
    output           rd_en_o,           // Read enable: asserted when card is driving data_o
    output           rom_en_o,          // ROM enable: asserted when card owns C8-space

    // Video chain: SuperSprite mux pattern
    // Each stage in the video pipeline receives the previous stage's RGB output
    // and either replaces it (when active) or passes it through unchanged.
    // Chain: apple_video -> VGC -> Videx -> SuperSprite -> DebugOverlay -> HDMI
    input wire [9:0] screen_x_i,        // Horizontal pixel position (0-719 active)
    input wire [9:0] screen_y_i,        // Vertical pixel position (0-479 active)
    input [7:0]      apple_vga_r_i,     // Red channel from previous pipeline stage
    input [7:0]      apple_vga_g_i,     // Green channel from previous pipeline stage
    input [7:0]      apple_vga_b_i,     // Blue channel from previous pipeline stage
    output [7:0]     videx_r_o,         // Red channel to next pipeline stage
    output [7:0]     videx_g_o,         // Green channel to next pipeline stage
    output [7:0]     videx_b_o          // Blue channel to next pipeline stage
);

    // ========================================================================
    // Card Enable (standard Mockingboard/SSC pattern)
    // ========================================================================
    //
    // The A2FPGA slot configuration system uses a shared config bus to
    // enable/disable cards at runtime. When config_select_n is asserted,
    // the slot number and card_id on the bus indicate which card is being
    // configured. Slot 0 disables the card; any other slot with matching
    // card_id enables it (if the ENABLE parameter allows).
    //
    // This pattern is identical across all emulated cards (Mockingboard,
    // SSC, SuperSprite, Videx) — it's the A2FPGA equivalent of physically
    // inserting a card into a specific slot.

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

    // Derived select signals combining card_enable with slot interface active-low signals.
    // All gated by phi0 to ensure they're only valid during the bus phase when the
    // Apple II CPU is driving a stable address (phi0 high = CPU address valid).
    wire card_sel       = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
    wire card_dev_sel   = card_sel && !slot_if.dev_select_n;   // Device select: $C0Bx (CRTC I/O)
    wire card_io_sel    = card_sel && !slot_if.io_select_n;    // I/O select: $C300-$C3FF (slot ROM)
    wire card_io_strobe = !slot_if.io_strobe_n && a2bus_if.phi0; // I/O strobe: $C800-$CFFF range

    // ========================================================================
    // Address Decode
    // ========================================================================
    //
    // These address decoders identify specific memory regions the Videx card
    // responds to. All are raw combinational decodes — qualification by
    // ownership/phi0 happens where they're used.

    wire vram_window   = (a2bus_if.addr[15:9] == 7'b1100_110);   // $CC00-$CDFF (2 KB VRAM window)
    wire exp_rom_range = (a2bus_if.addr[15:10] == 6'b110010);    // $C800-$CBFF (1 KB expansion ROM)

    // $CFFF access clears C8-space ownership on ALL cards (Apple II bus protocol).
    // CRITICAL: Must be phi0-qualified. During phi1, the address bus can have
    // transient values as the CPLD bus transceivers transition. Without phi0
    // gating, these transients can look like $CFFF and spuriously clear
    // ownership, causing non-deterministic C8 read failures.
    wire cfff_access   = a2bus_if.phi0 && (a2bus_if.addr == 16'hCFFF);

    // Detect other-slot $Csxx ROM access ($C100-$C7FF, slot != 3).
    // Used to clear C8 ownership when another slot's ROM is accessed.
    // This is an FPGA-specific addition — real hardware doesn't need this
    // because each physical card has its own bus transceiver. In the shared
    // FPGA bus mux, we must explicitly yield C8 space to avoid bus contention.
    // phi0-qualified for the same transient-address reason as cfff_access.
    wire other_slot_rom = a2bus_if.phi0 &&
                          (a2bus_if.addr[15:11] == 5'b1100_0) &&  // $C100-$C7FF
                          (a2bus_if.addr[10:8] != 3'd3) &&        // not slot 3 ($C3xx)
                          (a2bus_if.addr[10:8] != 3'd0);          // not $C0xx (I/O space)

    // ========================================================================
    // C8-Space Ownership
    // ========================================================================
    //
    // The Apple II uses a shared $C800-$CFFF "expansion ROM" address space.
    // Only one card may drive this space at a time. On real hardware, the
    // Videx PAL16L8 tracks ownership with a flip-flop:
    //   - SET by /IOSEL going low (CPU accesses $C3xx, slot 3 ROM)
    //   - CLEARED by $CFFF access (universal release) or, in this FPGA
    //     implementation, by detecting another slot's $Csxx access.
    //
    // The INTCXROM soft-switch ($C006/$C007 on IIe) can redirect $Cxxx reads
    // to internal ROM. When INTCXROM=1, the card must not respond to C8
    // reads even if it "owns" the space — the internal ROM takes priority.
    //
    // Read responses are gated by phi0 directly rather than io_strobe_n.
    // Using io_strobe_n was tried but causes PR#3 to hang, likely because
    // io_strobe_n depends on SLOTROM which is updated on phi1_posedge in
    // apple_memory.sv — a timing mismatch with the phi0-based bus cycle.

    reg c8_owned;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            c8_owned <= 1'b0;
        end else if (card_io_sel) begin
            // Accessing our slot ROM ($C3xx) claims C8-space ownership
            c8_owned <= 1'b1;
        end else if (!a2mem_if.INTCXROM && (cfff_access || other_slot_rom)) begin
            // Release ownership when $CFFF is hit or another slot's ROM is accessed.
            // Only act when INTCXROM=0 (card ROM space is active). When INTCXROM=1,
            // the CPU is reading internal ROM and bus transactions aren't real
            // slot accesses — don't change ownership state.
            c8_owned <= 1'b0;
        end
    end

    // Active C8-space: we own it AND internal ROM isn't overriding
    wire rom_c8_active = c8_owned && !a2mem_if.INTCXROM;
    assign rom_en_o = rom_c8_active;

    // ========================================================================
    // Firmware ROM (1 KB in distributed RAM / LUTs, not BSRAM)
    // ========================================================================
    //
    // The Videx VideoTerm firmware occupies 1 KB (256 bytes of slot ROM at
    // $C300-$C3FF plus 768 bytes of expansion ROM at $C800-$CBFF, but the
    // slot ROM IS the top 256 bytes of the expansion ROM). The ROM image is
    // loaded from videx_rom.hex at synthesis time.
    //
    // Distributed RAM (LUT-based) is used instead of BSRAM to conserve the
    // limited BSRAM blocks for VRAM. The syn_ramstyle attribute hints to
    // GoWin to use LUTs, though GoWin may ignore it depending on optimization.
    //
    // The ROM has a 2-stage pipeline to match GoWin distributed RAM inference
    // requirements. Both stages run on clk_logic.

    reg [7:0] rom[0:1023] /*synthesis syn_ramstyle="distributed_ram"*/;
    initial $readmemh("videx_rom.hex", rom);

    // ROM address mux:
    //   Slot ROM ($C300-$C3FF): The slot ROM window maps to the TOP 256 bytes
    //     of the 1 KB ROM. {2'b11, addr[7:0]} = offsets $300-$3FF = bytes 768-1023.
    //   Expansion ROM ($C800-$CBFF): Direct 10-bit addressing = offsets $000-$3FF.
    //   This works because the Videx ROM image has the slot ROM at the end,
    //   matching how the real hardware maps it.
    wire [9:0] rom_addr = card_io_sel ? {2'b11, a2bus_if.addr[7:0]} : a2bus_if.addr[9:0];

    // 2-stage pipeline read for GoWin distributed RAM inference.
    // Stage 1 (rom_data_r): RAM output register
    // Stage 2 (rom_data_rr): Output register — this is what data_o reads
    reg [7:0] rom_data_r;
    reg [7:0] rom_data_rr;

    always_ff @(posedge a2bus_if.clk_logic) begin
        rom_data_r  <= rom[rom_addr];
        rom_data_rr <= rom_data_r;
    end

    // ========================================================================
    // CRTC Register File (R0-R15, all readable per HD6845SP Type 1)
    // ========================================================================
    //
    // The Videx VideoTerm uses a Hitachi HD6845SP (MC6845 Type 1) CRT
    // controller. In real hardware, the 6845 generates timing signals and
    // manages the display address counter. In this emulation, we only need
    // the register file — the rendering pipeline reads these registers
    // directly rather than using 6845 timing outputs.
    //
    // Key registers for rendering:
    //   R10-R11: Cursor start/end scanlines + blink mode
    //   R12-R13: Display start address (11-bit, wraps at 2 KB)
    //   R14-R15: Cursor address (11-bit)
    //
    // The HD6845SP (Type 1) allows reading back ALL R0-R15. Some 6845
    // variants only allow reading R14-R15. Our implementation matches
    // Type 1 behavior, confirmed by VIDEX_DIAG tests.

    reg [4:0] crtc_idx;                 // 5-bit index: selects which register to read/write
    reg [7:0] crtc_regs[0:15];         // 16 x 8-bit register file

    // ========================================================================
    // Bank Selection
    // ========================================================================
    //
    // The Videx VRAM is 2 KB but the Apple II C8-space window ($CC00-$CDFF)
    // is only 512 bytes. The Videx uses a 2-bit bank selector to address
    // all 4 banks of 512 bytes. The bank is selected by the address bits
    // [3:2] of ANY access to $C0Bx (the device-select range). This happens
    // on both reads AND writes to $C0Bx — even CRTC register reads will
    // change the bank as a side effect.
    //
    // bank_sel forms the upper 2 bits of the 11-bit VRAM byte address:
    //   Full address = {bank_sel[1:0], addr[8:0]} = 11 bits = 2048 bytes

    reg [1:0] bank_sel;

    // ========================================================================
    // CRTC + Bank Writes (phi1_posedge, direct address decode)
    // ========================================================================
    //
    // CRTC register writes and bank selection are processed on the falling
    // edge of phi0 (= rising edge of phi1). This matches the Apple II bus
    // protocol: data is stable on the bus just before phi0 falls, which is
    // when peripheral cards latch it.
    //
    // The address decode ($C0Bx) is done directly on the bus address rather
    // than using slot_if signals, because this happens during a different
    // bus phase than the slot_if selection logic provides.
    //
    // Register access protocol (matches MC6845):
    //   Even address ($C0B0): Write sets the 5-bit register index (R0-R31).
    //     Only R0-R15 are writable, but the index goes to R31 for read-back
    //     compatibility (R16+ read as $00).
    //   Odd address ($C0B1): Write stores data into the selected register.
    //     Only R0-R15 are writable; writes to R16+ are silently ignored.

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            crtc_idx <= 5'h0;
            bank_sel <= 2'b0;
            for (int i = 0; i < 16; i++)
                crtc_regs[i] <= 8'h00;
        end else if (a2bus_if.phi1_posedge && !a2bus_if.m2sel_n &&
                     (a2bus_if.addr[15:4] == 12'hC0B) && card_enable) begin
            // Bank selection on ANY $C0Bx access (read or write).
            // addr[3:2] selects one of 4 banks (0-3), giving access to all 2 KB.
            // This side-effect is why the firmware carefully sequences $C0Bx
            // accesses — even reading the CRTC status register changes the bank.
            bank_sel <= a2bus_if.addr[3:2];

            // CRTC register writes only (rw_n=0 means write)
            if (!a2bus_if.rw_n) begin
                if (!a2bus_if.addr[0])                  // even addr = index select
                    crtc_idx <= a2bus_if.data[4:0];
                else if (crtc_idx < 5'd16)              // odd addr = data write (R0-R15 only)
                    crtc_regs[crtc_idx] <= a2bus_if.data[7:0];
            end
        end
    end

    // CRTC read-back logic:
    //   Even address ($C0B0): Returns $00 (address/status — real HD6845SP
    //     returns $00 in VIDEX_DIAG T01, A2DVI does the same)
    //   Odd address ($C0B1): Returns the value of the selected register.
    //     R0-R15 return the last written value (Type 1 behavior).
    //     R16-R31 return $00 (no such registers).
    wire crtc_read = card_dev_sel && a2bus_if.rw_n;
    wire [7:0] crtc_data = (a2bus_if.addr[0] && crtc_idx < 5'd16)
                         ? crtc_regs[crtc_idx] : 8'h00;

    // ========================================================================
    // VRAM (2 KB, GoWin SDPB primitive with asymmetric port widths)
    // ========================================================================
    //
    // VRAM stores the 80-column text buffer (80 columns x 24 rows = 1920 bytes,
    // with 128 bytes unused per 2 KB bank). The Videx hardware uses a standard
    // 2114-type SRAM, but for the FPGA we use a GoWin SDPB (Simple Dual-Port
    // Block RAM) primitive to get optimal resource usage:
    //
    //   Write port: 8-bit wide (matches Apple II byte writes from CPU)
    //   Read port:  32-bit wide (reads 4 characters at once for the scanner)
    //
    // This asymmetric configuration uses exactly 1 SDPB block for 2 KB.
    // Using the generic sdpram32 module with byte_enable would cost 4 blocks
    // due to GoWin's byte-lane splitting penalty — a 4x waste.
    //
    // The SDPB has a 2-cycle read pipeline (READ_MODE=1). Since clk_logic
    // runs at 2x clk_pixel, two logic cycles fit within one pixel cycle,
    // making the pipeline latency invisible to the rendering scanner.
    //
    // Two consumers share the read port via a mux:
    //   1. Scanner (rendering pipeline): reads 4 chars per 32-step cycle
    //   2. CPU (6502 read-back): reads VRAM for firmware diagnostics/copy
    // Scanner has priority; CPU reads are blocked during scanner activity.
    // Each consumer has a "hold register" that captures the 32-bit SDPB
    // output after the 2-cycle pipeline, so the data remains stable while
    // the SDPB serves the other consumer.

    // VRAM byte address: {bank_sel, addr[8:0]} = 11 bits = 2048 bytes.
    // bank_sel is latched from $C0Bx accesses; addr[8:0] comes from the
    // $CC00-$CDFF window (addr[8:0] covers the 512-byte bank window).
    wire [10:0] vram_addr = {bank_sel, a2bus_if.addr[8:0]};

    // VRAM write: qualified by C8 ownership and the VRAM address window.
    // data_in_strobe is the GoWin-specific write strobe from the bus bridge.
    // Note: writes are internal to the card (they change VRAM content but
    // don't drive the Apple II bus), so they're gated by rom_c8_active
    // rather than io_strobe_n.
    wire vram_we = !a2bus_if.rw_n && a2bus_if.data_in_strobe &&
                   rom_c8_active && vram_window;

    // Scanner VRAM read signals (directly access SDPB read port).
    // These are driven by the rendering pipeline's state machine (below).
    // Declared here because they're used in the read-port mux logic.
    reg [8:0] scanner_vram_addr;        // 9-bit word address (512 x 32-bit words = 2 KB)
    reg scanner_vram_rd;                // Pulse high for one clk_logic cycle to start read

    // Muxed read port: scanner has priority over CPU.
    // cpu_vram_rd is phi0-qualified to prevent spurious reads during phi1
    // bus transitions from corrupting the CPU hold register.
    wire cpu_vram_rd = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;
    wire [8:0]  vram_rd_addr = scanner_vram_rd ? scanner_vram_addr : vram_addr[10:2];
    wire        vram_rd_en   = scanner_vram_rd || cpu_vram_rd;
    wire [31:0] vram_rd_data;

    // GoWin SDPB primitive instantiation: 1 BSRAM block for 2 KB VRAM.
    //
    // Address encoding (GoWin SDPB convention):
    //   Write (8-bit):  ADA[13:3] = byte_addr[10:0], ADA[2:0] = 0
    //     The byte address occupies bits [13:3] with 3 zero-padding bits below.
    //   Read (32-bit):  ADB[13:5] = word_addr[8:0], ADB[4:0] = 0
    //     The word address occupies bits [13:5] with 5 zero-padding bits below.
    //     Each 32-bit read returns 4 consecutive bytes (little-endian within word).
    //
    // READ_MODE=1 selects pipelined output: data appears 2 clk_logic cycles
    // after CEB is asserted. This is necessary for timing closure at 54 MHz.
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

    // Track which consumer initiated each read through the SDPB's 2-cycle pipeline.
    // After 2 clk_logic cycles, the corresponding hold register captures the output.
    // scanner_rd_d1/d2: scanner read in pipeline stages 1 and 2
    // cpu_rd_d1/d2: CPU read in pipeline stages 1 and 2 (only when scanner isn't active)
    reg scanner_rd_d1, scanner_rd_d2;
    reg cpu_rd_d1, cpu_rd_d2;

    always_ff @(posedge a2bus_if.clk_logic) begin
        scanner_rd_d1 <= scanner_vram_rd;
        scanner_rd_d2 <= scanner_rd_d1;
        cpu_rd_d1 <= cpu_vram_rd && !scanner_vram_rd;  // CPU read blocked when scanner active
        cpu_rd_d2 <= cpu_rd_d1;
    end

    // Scanner hold register: captures the 32-bit SDPB output when a scanner-
    // initiated read completes. Holds 4 consecutive character codes that the
    // rendering pipeline will look up in the character ROM one at a time.
    reg [31:0] scanner_hold;

    always_ff @(posedge a2bus_if.clk_logic) begin
        if (scanner_rd_d2)
            scanner_hold <= vram_rd_data;
    end

    // CPU hold register: captures the 32-bit SDPB output when a CPU-initiated
    // read completes. The CPU reads one byte at a time, so we extract the
    // appropriate byte from this 32-bit word using the original byte address.
    reg [31:0] cpu_hold;

    always_ff @(posedge a2bus_if.clk_logic) begin
        if (cpu_rd_d2)
            cpu_hold <= vram_rd_data;
    end

    // CPU byte extraction: selects which of the 4 bytes in the 32-bit word
    // to return for a CPU read. vram_addr[1:0] identifies the byte position,
    // but it must be pipelined by 2 cycles to align with the SDPB output.
    reg [1:0] vram_byte_sel_r;
    reg [1:0] vram_byte_sel_rr;

    always_ff @(posedge a2bus_if.clk_logic) begin
        vram_byte_sel_r  <= vram_addr[1:0];
        vram_byte_sel_rr <= vram_byte_sel_r;
    end

    // Byte mux: extract the addressed byte from the 32-bit hold register.
    // Byte 0 = bits [7:0] (lowest address), byte 3 = bits [31:24] (highest).
    wire [7:0] vram_read_byte = vram_byte_sel_rr == 2'd0 ? cpu_hold[7:0] :
                                vram_byte_sel_rr == 2'd1 ? cpu_hold[15:8] :
                                vram_byte_sel_rr == 2'd2 ? cpu_hold[23:16] :
                                                           cpu_hold[31:24];

    // ========================================================================
    // Video Mode State (latched during blanking for stability)
    // ========================================================================
    //
    // The Apple II soft-switch state (TEXT_MODE, AN0, colors) can change at
    // any time during the frame. To prevent visual tearing and glitches, we
    // latch these values during vertical/horizontal blanking and use the
    // latched copies for the entire active display period.
    //
    // CRTC registers are similarly latched during blanking. The firmware
    // updates R12-R15 (display start and cursor address) during vertical
    // blanking, so latching ensures a consistent snapshot for rendering.
    //
    // These latches cross from clk_logic domain (where soft-switches and
    // CRTC writes happen) to clk_pixel domain (where rendering happens).
    // The blanking window provides a safe crossing point — values are
    // stable well before the rendering pipeline reads them.

    localparam [9:0] SCREEN_WIDTH = 720;     // VGA 480p active width
    localparam [9:0] SCREEN_HEIGHT = 480;    // VGA 480p active height

    // Blanking is active when the scan position is beyond the visible area
    wire blanking_active_w = (screen_x_i > SCREEN_WIDTH) | (screen_y_i > SCREEN_HEIGHT);

    reg text_mode_r;                         // TEXT_MODE soft-switch (latched)
    reg an0_r;                               // AN0 annunciator ($C058/$C059, latched)
    reg [3:0] text_color_r;                  // Foreground color index (latched)
    reg [3:0] background_color_r;            // Background color index (latched)
    reg [3:0] border_color_r;               // Border color index (latched)

    // CRTC registers latched during blanking (from internal register file).
    // Only the registers needed for rendering are latched:
    //   R10-R11: Cursor start/end scanlines and blink mode
    //   R12-R13: Display start address (determines which VRAM byte is top-left)
    //   R14-R15: Cursor position in VRAM
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

    // Videx display is active when: the card is enabled, the Apple II is in
    // text mode (not graphics), and AN0 is high (the 40/80 column switch).
    // AN0=$C059 activates 80-column mode; AN0=$C058 returns to 40-column.
    wire videx_active = card_enable && text_mode_r && an0_r;

    // ========================================================================
    // Display Geometry
    // ========================================================================
    //
    // The Videx display is rendered into a centered window within the VGA
    // 720x480 frame. The window dimensions are:
    //   Width:  640 pixels = 80 characters x 8 pixels/character
    //   Height: 432 pixels = 24 rows x 9 scanlines/row x 2 (line doubling)
    //
    // Line doubling converts the Videx's native 216-line display (24 rows x
    // 9 scanlines) to 432 lines for the 480p VGA output. Each Videx scanline
    // is displayed twice consecutively.
    //
    // The content window is centered horizontally with 40-pixel borders on
    // each side: (720 - 640) / 2 = 40. Vertically, 24-pixel borders:
    // (480 - 432) / 2 = 24.

    localparam [9:0] WINDOW_WIDTH = 640;
    localparam [9:0] VIDEX_WINDOW_HEIGHT = 432;    // 9 scanlines x 24 rows x 2 (doubling)
    localparam [9:0] H_BORDER = (SCREEN_WIDTH - WINDOW_WIDTH) / 2;   // 40
    localparam [9:0] VIDEX_V_BORDER = (SCREEN_HEIGHT - VIDEX_WINDOW_HEIGHT) / 2;  // 24

    // Border edges (exclusive): content starts at LEFT+1, ends before RIGHT
    localparam [9:0] H_LEFT_BORDER = H_BORDER - 1;
    localparam [9:0] H_RIGHT_BORDER = H_BORDER + WINDOW_WIDTH;
    localparam [9:0] VIDEX_V_TOP_BORDER = VIDEX_V_BORDER - 1;
    localparam [9:0] VIDEX_V_BOTTOM_BORDER = VIDEX_V_BORDER + VIDEX_WINDOW_HEIGHT;

    // Rendering pipeline timing constants:
    //   STEP_LENGTH: Pixels per pipeline cycle = 4 chars x 8 pixels = 32.
    //     The pipeline fetches 4 characters from VRAM per cycle and renders
    //     all 32 pixels before fetching the next group.
    //   PIX_BUFFER_SIZE: Pixel buffer width = STEP_LENGTH + 1 = 33.
    //     The extra bit is a "gap pixel" (always 0/background) that provides
    //     a clean transition at the buffer boundary.
    //   PIX_HISTORY_SIZE: Delay line depth for pixel output alignment.
    //     Compensates for the pipeline's look-ahead: the scanner runs ahead
    //     of the display position, and the history buffer delays the pixel
    //     output to align with the current screen_x position.
    //   SCAN_PIX_OFFSET: How far ahead the scanner runs vs. the display.
    //     The scanner starts this many pixels before the visible window so
    //     that rendered pixels are ready when the display reaches them.
    localparam STEP_LENGTH = 32;
    localparam PIX_BUFFER_SIZE = STEP_LENGTH + 1;  // 33
    localparam PIX_HISTORY_SIZE = 8;
    localparam SCAN_PIX_OFFSET = STEP_LENGTH + PIX_HISTORY_SIZE - 4;  // 36

    // Active region detection for the display output (content window)
    wire x_active_w = (screen_x_i > H_LEFT_BORDER) & (screen_x_i < H_RIGHT_BORDER);
    wire y_active_w = (screen_y_i > VIDEX_V_TOP_BORDER) & (screen_y_i < VIDEX_V_BOTTOM_BORDER);
    wire videx_pixel_active = videx_active & x_active_w & y_active_w;

    // Scanner active region: offset left by SCAN_PIX_OFFSET pixels.
    // The scanner must start processing VRAM data well before the display
    // reaches the visible window, because the pipeline needs time to:
    //   1. Issue VRAM read (1 pixel step)
    //   2. Wait for SDPB pipeline (2 clk_logic cycles = ~1 pixel step)
    //   3. Latch VRAM data (steps 2-14 settle time)
    //   4. Look up 4 characters in charrom (steps 15-20)
    //   5. Load shift register (step 31)
    //   6. Shift through pixel history buffer (PIX_HISTORY_SIZE steps)
    wire scan_x_active_w = (screen_x_i > (H_LEFT_BORDER - SCAN_PIX_OFFSET)) & (screen_x_i < (H_RIGHT_BORDER - SCAN_PIX_OFFSET));
    wire scan_active_w = scan_x_active_w & y_active_w;
    wire scan_start_w = (screen_x_i == (H_LEFT_BORDER - SCAN_PIX_OFFSET)) & y_active_w;

    // ========================================================================
    // Videx Geometry Calculations
    // ========================================================================
    //
    // These combinational calculations convert the VGA screen position into
    // Videx display coordinates (row, column, scanline within row, VRAM address).
    // All are pure functions of screen_y_i and the latched CRTC registers.

    // Display start address from CRTC R12:R13.
    // Only the lower 3 bits of R12 are used (11-bit address, 2 KB wrap).
    // This determines which VRAM byte appears at the top-left of the screen.
    // The firmware updates this during scrolling.
    wire [10:0] videx_text_base_w = {videx_r12_r[2:0], videx_r13_r};

    // Cursor address from CRTC R14:R15 (11-bit, same format as start address).
    wire [10:0] videx_cursor_addr_w = {videx_r14_r[2:0], videx_r15_r};

    // Convert VGA Y position to Videx content line.
    // Remove the top border offset and divide by 2 to undo line-doubling.
    // Result: 0-215 for the 216 unique scanlines (24 rows x 9 scanlines).
    wire [9:0] videx_content_y_full_w = (screen_y_i - VIDEX_V_BORDER) >> 1;
    wire [7:0] videx_content_y_w = (screen_y_i > VIDEX_V_TOP_BORDER) ?
        videx_content_y_full_w[7:0] : 8'd0;

    // Integer division by 9 to find the character row (0-23).
    // Uses the reciprocal approximation: row = (content_y * 57) >> 9.
    // 57/512 ≈ 0.1113 ≈ 1/8.98, which gives exact results for 0-215.
    // This avoids a hardware divider (expensive in LUTs and timing).
    wire [13:0] videx_div9_w = videx_content_y_w * 8'd57;
    wire [4:0] videx_row_w = videx_div9_w[13:9];

    // Scanline within the current row (0-8 for 9 scanlines per row).
    // Computed as: content_y - (row * 9).
    // row * 9 is computed as (row << 3) + row = row*8 + row.
    wire [7:0] videx_row_x9_w = {videx_row_w[4:0], 3'b0} + {3'b0, videx_row_w[4:0]};
    wire [7:0] videx_scanline_full_w = videx_content_y_w - videx_row_x9_w;
    wire [3:0] videx_scanline_w = videx_scanline_full_w[3:0];

    // ========================================================================
    // Character ROM (2 KB half-size, 128 chars x 16 scanlines)
    // ========================================================================
    //
    // The character ROM stores glyph bitmaps: 128 characters x 16 scanlines
    // = 2048 bytes. Only 9 of the 16 scanlines per character are used (the
    // Videx uses 9-scanline character cells); the extra 7 scanlines per char
    // are padding/unused in the ROM layout.
    //
    // Characters 0x80-0xFF are the INVERSE (reverse video) of 0x00-0x7F.
    // Rather than storing all 256 characters (4 KB), we store only 128 and
    // generate the inverse at the pixel capture stage by XORing with bit 7
    // of the character code. This "charrom halving" saves 1 BSRAM block.
    //
    // The ROM data is pre-bit-reversed from the original hardware dumps:
    // the physical Videx 74LS166 shift register outputs MSB-first (bit 7 =
    // leftmost pixel), but our FPGA pipeline shifts LSB-first (bit 0 =
    // leftmost pixel). The bit reversal is baked into the .hex file.
    //
    // Address format: {char_code[6:0], scanline[3:0]} = 11 bits.
    //   char_code[6:0]: lower 7 bits (0x00-0x7F, inverse handled by XOR)
    //   scanline[3:0]: which scanline of the character (0-8 used, 9-15 padding)

    reg [10:0] videxrom_a_r;            // Character ROM address register
    reg [7:0] videxrom_d_r;             // Character ROM data output (1-cycle latency)
    reg [7:0] videxrom_r[2047:0];       // 2 KB character ROM (inferred as pROM BSRAM)
    initial $readmemh("videx_charrom.hex", videxrom_r, 0);
    always @(posedge a2bus_if.clk_pixel) videxrom_d_r <= videxrom_r[videxrom_a_r];

    // ========================================================================
    // Cursor Logic
    // ========================================================================
    //
    // The MC6845 cursor is defined by:
    //   R10[6:5]: Blink mode — 00=steady, 01=invisible, 10=blink(1/8), 11=blink(1/16)
    //   R10[3:0]: Cursor start scanline (topmost scanline of cursor block)
    //   R11[3:0]: Cursor end scanline (bottommost scanline of cursor block)
    //
    // The cursor is rendered by XORing the character ROM output with the
    // cursor state (on/off × blink × scanline range × position match).
    // This creates a reverse-video block at the cursor position, matching
    // real MC6845 behavior.
    //
    // Blink timing uses a frame counter incremented once per VGA frame
    // (detected by screen_y transitioning past SCREEN_HEIGHT). The two
    // blink rates divide the frame counter at different bit positions:
    //   Bit 3: ~1/8 frame rate (~3.75 Hz at 60 Hz VGA)
    //   Bit 4: ~1/16 frame rate (~1.875 Hz at 60 Hz VGA)

    wire [1:0] videx_cursor_blink_mode_w = videx_r10_r[6:5];
    wire [3:0] videx_cursor_start_line_w = videx_r10_r[3:0];
    wire [3:0] videx_cursor_end_line_w = videx_r11_r[3:0];

    // Frame counter for cursor blink timing.
    // Increments on the rising edge of (screen_y >= SCREEN_HEIGHT), i.e.,
    // once per VGA frame when vertical blanking begins.
    reg videx_frame_edge_r;
    reg [5:0] videx_frame_cnt_r;
    always @(posedge a2bus_if.clk_pixel) begin
        videx_frame_edge_r <= (screen_y_i >= SCREEN_HEIGHT);
        if ((screen_y_i >= SCREEN_HEIGHT) && !videx_frame_edge_r)
            videx_frame_cnt_r <= videx_frame_cnt_r + 1'b1;
    end

    // Cursor visibility based on blink mode:
    //   00: Always visible (steady cursor)
    //   01: Always invisible (no cursor displayed)
    //   10: Blink at 1/8 frame rate (toggle every 8 frames)
    //   11: Blink at 1/16 frame rate (toggle every 16 frames)
    wire videx_cursor_blink_w =
        (videx_cursor_blink_mode_w == 2'b00) ? 1'b1 :
        (videx_cursor_blink_mode_w == 2'b01) ? 1'b0 :
        (videx_cursor_blink_mode_w == 2'b10) ? videx_frame_cnt_r[3] :
        videx_frame_cnt_r[4];

    // Cursor scanline range: true when the current scanline falls within
    // the cursor block defined by R10[3:0] (start) and R11[3:0] (end).
    wire videx_cursor_scanline_w = (videx_scanline_w >= videx_cursor_start_line_w) &&
                                    (videx_scanline_w <= videx_cursor_end_line_w);

    // ========================================================================
    // Rendering Pipeline (32-step pixel cycle)
    // ========================================================================
    //
    // The rendering pipeline produces 32 pixels per cycle (4 characters x
    // 8 pixels each). It operates on clk_pixel (27 MHz), producing one
    // pixel per clock cycle via a shift register.
    //
    // Pipeline timing within a 32-step cycle:
    //   Step 0:          Issue VRAM read for next 4 characters
    //   Steps 1-13:      SDPB pipeline settles (2 clk_logic cycles = ~1 step),
    //                    then scanner_hold captures the 32-bit VRAM word
    //   Step 14:         Latch VRAM data from scanner_hold into videx_data_r;
    //                    clear gap pixel (pix_buffer_r[32] = 0)
    //   Step 15:         Issue charrom lookup for char 0 (videx_data_r[6:0])
    //   Step 16:         Issue charrom lookup for char 1 (videx_data_r[14:8])
    //   Step 17:         Capture char 0 pixels; issue charrom lookup for char 2
    //   Step 18:         Capture char 1 pixels; issue charrom lookup for char 3
    //   Step 19:         Capture char 2 pixels
    //   Step 20:         Capture char 3 pixels
    //   Steps 21-30:     (shift register draining previous cycle's pixels)
    //   Step 31:         Load shift register from pix_buffer_r; advance h_offset
    //
    // The charrom has 1-cycle latency (registered output). So each character
    // needs 2 steps: one to issue the address, one to capture the data.
    // Chars 0 and 1 are pipelined with chars 2 and 3 to overlap lookups
    // with captures, completing all 4 characters in 6 steps (15-20).
    //
    // VRAM address calculation:
    //   The scanner maintains h_offset_r (column counter, 0-78 by 2s).
    //   Each VRAM read fetches 4 bytes (32-bit word), so h_offset increments
    //   by 2 per cycle (each word contains chars at columns 4n, 4n+1, 4n+2, 4n+3;
    //   but the word address is char_addr >> 2, and we step by 4 chars = +2 words?
    //   Actually: h_offset is used in videx_char_addr_w which adds h_offset*2 to
    //   the line start, and the VRAM read address is char_addr[10:2] = word address).
    //
    // Pixel buffer layout (33 bits):
    //   [7:0]   = char 0 pixels (8 pixels, LSB = leftmost)
    //   [15:8]  = char 1 pixels
    //   [23:16] = char 2 pixels
    //   [31:24] = char 3 pixels
    //   [32]    = gap pixel (always 0, background color)
    //
    // Cursor rendering:
    //   Each character's pixels are XORed with a cursor flag. The flag combines:
    //   - videx_data_r[7/15/23/31]: bit 7 of the char code (inverse flag)
    //   - videx_cursor_active_w: cursor is visible AND on this scanline AND
    //     at this character position (videx_cursor_byte_w matches 0/1/2/3)
    //   The XOR inverts pixels for: inverse characters (bit 7=1), cursor
    //   position, or both (double-invert = normal, which is correct behavior
    //   for a cursor on an inverse character).

    localparam [4:0] STEP_FIRST = 0;
    localparam [4:0] STEP_LAST = STEP_LENGTH - 1;          // 31
    localparam [4:0] STEP_LOAD_MEM = STEP_FIRST;           // Step 0: issue VRAM read
    localparam [4:0] STEP_LATCH_MEM = 14;                  // Step 14: latch VRAM data

    reg [4:0] pix_step_r;              // Current step within 32-step cycle (0-31)
    reg [5:0] h_offset_r;              // Horizontal character offset (0-78 by 2s, 20 groups)
    reg [31:0] videx_data_r;           // 4 character codes from VRAM (latched at step 14)
    reg [PIX_BUFFER_SIZE-1:0] pix_buffer_r;   // 33-bit pixel assembly buffer
    reg [PIX_BUFFER_SIZE-1:0] pix_shift_r /* synthesis syn_srlstyle = "registers" */;
    wire pix_out_w = pix_shift_r[0];   // Current pixel being shifted out (LSB-first)

    // VRAM linear address for the current 4-character group.
    // row * 80 = (row << 6) + (row << 4) = row*64 + row*16
    // This avoids a hardware multiplier.
    wire [10:0] videx_row_x80_w = ({videx_row_w, 6'd0}) + ({2'b0, videx_row_w, 4'd0});

    // Line start address: base + row*80, wrapped to 2 KB (& 0x7FF).
    wire [10:0] videx_line_start_w = (videx_text_base_w + videx_row_x80_w) & 11'h7FF;

    // Character address for the current 4-char group.
    // h_offset_r counts in pairs (0, 2, 4, ... 38), multiplied by 2 to get
    // the character offset (0, 4, 8, ... 76). The VRAM word address is
    // char_addr[10:2], reading 4 consecutive characters per word.
    wire [10:0] videx_char_addr_w = (videx_line_start_w + {4'b0, h_offset_r, 1'b0}) & 11'h7FF;

    // Cursor position matching for the current 4-character group.
    // videx_cursor_delta_w: distance from the first character of this group
    // to the cursor position, wrapped to 2 KB.
    // videx_cursor_in_group_w: true if the cursor falls within this 4-char group.
    // videx_cursor_byte_w: which of the 4 characters (0-3) the cursor is on.
    wire [10:0] videx_cursor_delta_w = (videx_cursor_addr_w - videx_char_addr_w) & 11'h7FF;
    wire videx_cursor_in_group_w = videx_cursor_delta_w < 11'd4;
    wire [1:0] videx_cursor_byte_w = videx_cursor_delta_w[1:0];
    wire videx_cursor_active_w = videx_cursor_blink_w && videx_cursor_scanline_w && videx_cursor_in_group_w;

    always @(posedge a2bus_if.clk_pixel) begin

        // Default action: shift the pixel register right by 1 (LSB-first output).
        // A zero is shifted into the MSB, so after all 33 bits are shifted out,
        // the register naturally produces background pixels.
        pix_shift_r <= {1'b0, pix_shift_r[PIX_BUFFER_SIZE-1:1]};

        // Scanner VRAM read is a single-cycle pulse; clear it each cycle
        // unless the state machine explicitly sets it below.
        scanner_vram_rd <= 1'b0;

        // At the start of each scanline, reset the step counter and column offset.
        // scan_start_w fires once when screen_x reaches the scanner's start position
        // (SCAN_PIX_OFFSET pixels before the visible content window).
        if (scan_start_w) begin
            pix_step_r <= '0;
            h_offset_r <= '0;
        end else if (videx_active) begin
            // Free-running 32-step counter (0 to STEP_LAST=31, then wraps to 0)
            pix_step_r <= (pix_step_r == STEP_LAST) ? 5'b0 : pix_step_r + 5'b1;
        end

        if (scan_active_w && videx_active) begin
            case (pix_step_r)
                // Step 0: Issue VRAM read for the next group of 4 characters.
                // The word address (char_addr[10:2]) selects a 32-bit word
                // containing 4 consecutive character codes from VRAM.
                STEP_LOAD_MEM: begin
                    scanner_vram_addr <= videx_char_addr_w[10:2];
                    scanner_vram_rd <= 1'b1;
                end

                // Step 14: Latch the 4-character VRAM word from the scanner hold
                // register. The SDPB 2-cycle pipeline has long since completed
                // (steps 0-2), and scanner_hold has been stable since ~step 3.
                // Also clear the gap pixel (bit 32) to ensure a background-color
                // pixel between the last character of this group and the first
                // character of the next group.
                STEP_LATCH_MEM: begin
                    videx_data_r <= scanner_hold;
                    pix_buffer_r[32] <= 1'b0;
                end

                // Step 15: Issue character ROM lookup for char 0.
                // Address = {char_code[6:0], scanline[3:0]}.
                // char_code[6:0] from videx_data_r[6:0] (strip bit 7, the inverse flag).
                // The charrom output will be ready on the NEXT clk_pixel edge (step 17).
                (STEP_LATCH_MEM + 5'd1): begin
                    videxrom_a_r <= {videx_data_r[6:0], videx_scanline_w};
                end

                // Step 16: Issue character ROM lookup for char 1.
                // videx_data_r[14:8] = char 1's code bits [6:0].
                // Meanwhile, char 0's ROM data is being registered (available next step).
                (STEP_LATCH_MEM + 5'd2): begin
                    videxrom_a_r <= {videx_data_r[14:8], videx_scanline_w};
                end

                // Step 17: Capture char 0's pixels from charrom; issue char 2 lookup.
                // videxrom_d_r now contains char 0's glyph bitmap (8 pixels).
                // XOR with: bit 7 of char code (inverse flag) ^ cursor active.
                // This handles normal, inverse, cursor, and inverse+cursor correctly:
                //   Normal char, no cursor:  XOR 0 = show pixels as-is
                //   Inverse char, no cursor: XOR 1 = invert all pixels
                //   Normal char, cursor:     XOR 1 = invert (shows cursor)
                //   Inverse char, cursor:    XOR 0 = double invert = normal
                (STEP_LATCH_MEM + 5'd3): begin
                    pix_buffer_r[7:0] <= videxrom_d_r[7:0] ^
                        {8{videx_data_r[7] ^ (videx_cursor_active_w && videx_cursor_byte_w == 2'd0)}};
                    videxrom_a_r <= {videx_data_r[22:16], videx_scanline_w};
                end

                // Step 18: Capture char 1 pixels; issue char 3 lookup.
                (STEP_LATCH_MEM + 5'd4): begin
                    pix_buffer_r[15:8] <= videxrom_d_r[7:0] ^
                        {8{videx_data_r[15] ^ (videx_cursor_active_w && videx_cursor_byte_w == 2'd1)}};
                    videxrom_a_r <= {videx_data_r[30:24], videx_scanline_w};
                end

                // Step 19: Capture char 2 pixels (char 3 ROM lookup in progress).
                (STEP_LATCH_MEM + 5'd5): begin
                    pix_buffer_r[23:16] <= videxrom_d_r[7:0] ^
                        {8{videx_data_r[23] ^ (videx_cursor_active_w && videx_cursor_byte_w == 2'd2)}};
                end

                // Step 20: Capture char 3 pixels (final character in this group).
                (STEP_LATCH_MEM + 5'd6): begin
                    pix_buffer_r[31:24] <= videxrom_d_r[7:0] ^
                        {8{videx_data_r[31] ^ (videx_cursor_active_w && videx_cursor_byte_w == 2'd3)}};
                end

                // Step 31: Transfer completed pixel buffer into the shift register.
                // The shift register immediately begins outputting pixels (LSB first)
                // on the next clk_pixel edge. Also advance h_offset_r by 2 to point
                // to the next group of 4 characters (h_offset counts in pairs:
                // 0, 2, 4, ..., 38 for 20 groups of 4 = 80 columns total).
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
    //
    // Converts the 1-bit pixel stream from the shift register into colored
    // RGB output using the Apple II's configurable color palette. The palette
    // supports both Apple II (16 colors) and Apple IIgs (16 colors) palettes,
    // selected by the GSP (GS palette) switch.
    //
    // Each pixel is colored as:
    //   - Text foreground color (text_color_r) if the pixel is ON (1)
    //   - Background color (background_color_r) if the pixel is OFF (0)
    //   - Border color (border_color_r) if outside the content window
    //
    // A pixel history shift register provides alignment between the scanner's
    // output and the VGA display position. The scanner runs SCAN_PIX_OFFSET
    // pixels ahead of the display, and the history buffer delays the pixel
    // stream by HISTORY_PIXEL_OFFSET positions to compensate. The exact offset
    // was tuned to align with apple_video's pipeline delay so that the Videx
    // content window is correctly centered.

    wire GSP = a2bus_if.sw_gs;          // GS palette select (0=Apple II, 1=IIgs)

    // 12-bit RGB palette: {R[3:0], G[3:0], B[3:0]} for each of 32 entries.
    // Entries 0-15: Apple II sRGB palette
    // Entries 16-31: Apple IIgs palette
    // The palette index is {GSP, color_index[3:0]}.
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

    // Pixel history: a shift register that delays the pixel stream from the
    // scanner by PIX_HISTORY_SIZE positions. The pixel at position
    // HISTORY_PIXEL_OFFSET is the one that aligns with the current screen_x.
    reg [PIX_HISTORY_SIZE-1:0] pix_history_r;

    localparam HISTORY_PIXEL_OFFSET = 4;

    // Registered color output: one pipeline stage to select the color index
    // based on pixel value and active region. This registered output ensures
    // clean timing for the palette lookup that follows.
    reg [3:0] pix_color_r;

    always @(posedge a2bus_if.clk_pixel) begin
        // Shift the pixel history register: newest pixel enters at MSB,
        // oldest pixel exits at LSB.
        pix_history_r <= {pix_out_w, pix_history_r[PIX_HISTORY_SIZE-1:1]};

        // Default to background color
        pix_color_r <= background_color_r;
        if (videx_pixel_active) begin
            // Inside the content window: foreground if pixel is ON
            if (pix_history_r[HISTORY_PIXEL_OFFSET])
                pix_color_r <= text_color_r;
        end else begin
            // Outside the content window: border color
            pix_color_r <= border_color_r;
        end
    end

    // Palette lookup: convert the 4-bit color index to 12-bit RGB.
    // The GSP bit selects between Apple II (0-15) and IIgs (16-31) palettes.
    wire [11:0] pix_rgb = palette_rgb_r[{GSP, pix_color_r}];
    wire [3:0] pix_b = pix_rgb[3:0];
    wire [3:0] pix_g = pix_rgb[7:4];
    wire [3:0] pix_r = pix_rgb[11:8];

    // Video mux: the final output stage of the SuperSprite video chain pattern.
    // When Videx is active AND the current pixel is within the content window,
    // output the Videx-rendered pixel (expanded from 4-bit to 8-bit by shifting
    // left 4 bits, filling the lower nibble with zeros).
    // Otherwise, pass through the Apple video from the previous pipeline stage.
    assign videx_r_o = videx_pixel_active ? {pix_r, 4'h0} : apple_vga_r_i;
    assign videx_g_o = videx_pixel_active ? {pix_g, 4'h0} : apple_vga_g_i;
    assign videx_b_o = videx_pixel_active ? {pix_b, 4'h0} : apple_vga_b_i;

    // ========================================================================
    // Read Response Signals
    // ========================================================================
    //
    // When the CPU reads from an address the Videx card is responsible for,
    // these signals control what data is placed on the bus and whether the
    // card's bus drivers are enabled.
    //
    // Three read sources with different enable conditions:
    //   1. Slot ROM ($C300-$C3FF): enabled by card_io_sel (slotmaker /IOSEL)
    //   2. Expansion ROM ($C800-$CBFF): enabled by C8 ownership + phi0
    //   3. VRAM ($CC00-$CDFF): enabled by C8 ownership + phi0
    //   4. CRTC ($C0Bx): enabled by card_dev_sel (slotmaker /DEVSEL)
    //
    // All C8-space reads (expansion ROM and VRAM) are gated by phi0 directly
    // rather than io_strobe_n. This is the key behavioral difference from the
    // canonical approach — see the C8 ownership section for the rationale.

    wire slot_rom_read = card_io_sel && a2bus_if.rw_n;

    // C8-space reads gated by phi0 and c8_owned directly (not io_strobe_n).
    // io_strobe_n-based gating was tried but causes PR#3 hang due to
    // SLOTROM timing mismatch (phi1_posedge update vs phi0 evaluation).
    wire exp_rom_read  = rom_c8_active && a2bus_if.phi0 && exp_rom_range && a2bus_if.rw_n;

    wire vram_read = rom_c8_active && a2bus_if.phi0 && vram_window && a2bus_if.rw_n;

    // rd_en_o: tells the bus arbiter that this card is driving data_o.
    // Only one card should assert rd_en_o at a time; the bus arbiter in
    // top.sv selects the highest-priority card (Videx > SSC > SuperSprite > Mockingboard).
    assign rd_en_o = card_enable && (crtc_read || slot_rom_read || exp_rom_read || vram_read);

    // data_o mux priority: CRTC > VRAM > ROM.
    // CRTC is combinational (crtc_data from register file, zero latency).
    // VRAM uses the CPU hold register (2-cycle pipeline, but byte_sel is aligned).
    // ROM uses the 2-stage pipeline output (rom_data_rr).
    // The priority order doesn't matter in practice because the address ranges
    // are non-overlapping ($C0Bx vs $CC00-$CDFF vs $C800-$CBFF), but the
    // ternary chain provides a clean default.
    assign data_o = crtc_read ? crtc_data :
                    vram_read ? vram_read_byte :
                    rom_data_rr;

endmodule
