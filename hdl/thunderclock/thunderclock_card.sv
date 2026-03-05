//
// ThunderClock Plus Card Emulation
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
// Emulates the Thunderware ThunderClock Plus for the Apple II.
// Contains 2KB firmware ROM and NEC uPD1990AC clock chip emulation.
// Bus interface provides device-select register, slot ROM, and expansion ROM.
//
// Reference: ThunderClock Plus Technical Manual, MAME thunderclock.cpp

module thunderclock_card #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter bit [7:0] ID = 6,
    parameter bit ENABLE = 1'b1
) (
    a2bus_if.slave a2bus_if,
    a2mem_if.slave a2mem_if,
    slot_if.card slot_if,

    output [7:0] data_o,
    output rd_en_o,
    output irq_n_o,
    output rom_en_o
);

    // ========================================================================
    // Card enable (standard A2FPGA config_select pattern)
    // ========================================================================
    reg card_enable;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            card_enable <= 1'b0;
        end else if (!slot_if.config_select_n) begin
            if (slot_if.slot == 3'd0) begin
                card_enable <= 1'b0;
            end else if (slot_if.card_id == ID) begin
                card_enable <= slot_if.card_enable && ENABLE;
            end
        end
    end

    wire card_sel = card_enable && (slot_if.card_id == ID) && a2bus_if.phi0;
    wire card_dev_sel = card_sel && !slot_if.dev_select_n;
    wire card_io_sel = card_sel && !slot_if.io_select_n;
    wire card_io_strobe = !slot_if.io_strobe_n && a2bus_if.phi0;

    // ========================================================================
    // C8-space ownership (phi0-qualified, self-clearing)
    // ========================================================================
    // Learn our slot number dynamically from slotmaker on first io_select
    reg [2:0] my_slot;
    reg my_slot_known;

    wire cfff_access = a2bus_if.phi0 && (a2bus_if.addr == 16'hCFFF);
    wire other_slot_rom = a2bus_if.phi0 &&
        my_slot_known &&
        (a2bus_if.addr[15:11] == 5'b1100_0) &&
        (a2bus_if.addr[10:8] != my_slot) &&
        (a2bus_if.addr[10:8] != 3'd0);

    reg c8_owned;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            c8_owned <= 1'b0;
            my_slot <= 3'd0;
            my_slot_known <= 1'b0;
        end else begin
            if (card_io_sel) begin
                c8_owned <= 1'b1;
                my_slot <= slot_if.slot;
                my_slot_known <= 1'b1;
            end else if (!a2mem_if.INTCXROM && (cfff_access || other_slot_rom)) begin
                c8_owned <= 1'b0;
            end
        end
    end

    wire rom_c8_active = c8_owned && !a2mem_if.INTCXROM;

    // ========================================================================
    // Firmware ROM (2KB pROM)
    // ========================================================================
    // Slot ROM ($Cnxx):      addr[7:0] → ROM offset 0x000-0x0FF
    // Expansion ROM ($C800): addr[10:0] → ROM offset 0x000-0x7FF
    wire [10:0] rom_addr = (rom_c8_active && card_io_strobe) ?
        a2bus_if.addr[10:0] : {3'b000, a2bus_if.addr[7:0]};

    reg [7:0] rom[0:2047];
    initial $readmemh("thunderclock_rom.hex", rom);

    wire [7:0] rom_data = rom[rom_addr];

    // ========================================================================
    // uPD1990AC Clock Chip
    // ========================================================================
    reg [5:0] control_reg;  // Device-select write: {C2,C1,C0,STB,CLK,DI}

    wire upd_data_out;
    wire upd_tp_out;

    upd1990 #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) upd1990_inst (
        .clk(a2bus_if.clk_logic),
        .reset_n(a2bus_if.device_reset_n),  // Survives Apple II reset (like battery-backed chip)
        .data_in(control_reg[0]),    // Bit 0: DI
        .clk_in(control_reg[1]),     // Bit 1: CLK
        .stb_in(control_reg[2]),     // Bit 2: STB
        .cmd_in(control_reg[5:3]),   // Bits 5:3: C2:C1:C0
        .data_out(upd_data_out),
        .tp_out(upd_tp_out)
    );

    // ========================================================================
    // IRQ Logic
    // ========================================================================
    // IRQ triggers on TP rising edge, cleared by reading device-select register
    reg irq_status;
    reg prev_tp;

    always @(posedge a2bus_if.clk_logic) begin
        if (!a2bus_if.system_reset_n) begin
            irq_status <= 1'b0;
            prev_tp <= 1'b0;
            control_reg <= 6'd0;
        end else begin
            prev_tp <= upd_tp_out;

            // TP rising edge sets IRQ
            if (upd_tp_out && !prev_tp) begin
                irq_status <= 1'b1;
            end

            // Device-select access
            if (card_dev_sel) begin
                if (a2bus_if.rw_n) begin
                    // Read clears IRQ
                    irq_status <= 1'b0;
                end else begin
                    // Write latches control register
                    control_reg <= a2bus_if.data[5:0];
                end
            end
        end
    end

    assign irq_n_o = !(irq_status && card_enable);

    // ========================================================================
    // Data output mux and bus drive
    // ========================================================================
    // Device-select read: bit 7 = DATA OUT, bit 5 = IRQ status
    wire [7:0] dev_sel_data = {upd_data_out, 1'b0, irq_status, 5'd0};

    assign data_o = card_dev_sel ? dev_sel_data : rom_data;
    assign rom_en_o = rom_c8_active;
    assign rd_en_o = card_enable && a2bus_if.rw_n &&
        (card_io_sel || (rom_c8_active && card_io_strobe) || card_dev_sel);

endmodule
