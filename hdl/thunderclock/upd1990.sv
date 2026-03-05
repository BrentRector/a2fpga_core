//
// uPD1990AC Serial I/O Calendar Clock Emulation
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
// Emulates the NEC uPD1990AC used by the ThunderClock Plus.
// Implements the 40-bit serial shift register, BCD time counter,
// and command decoder. No external crystal — time is derived from
// the FPGA's 54 MHz logic clock.
//
// Reference: uPD1990AC datasheet, MAME upd1990a.cpp, izapple2 microPD1990ac.go

module upd1990 #(
    parameter int CLOCK_SPEED_HZ = 54_000_000
) (
    input  clk,
    input  reset_n,

    // Control signals from ThunderClock device-select register
    input  data_in,       // Bit 0: Serial data input
    input  clk_in,        // Bit 1: Shift clock (rising edge active)
    input  stb_in,        // Bit 2: Strobe (rising edge latches command)
    input  [2:0] cmd_in,  // Bits 5:3: Command code

    // Outputs
    output data_out,      // Bit 7 of read: shift register LSB or 1 Hz pulse
    output tp_out         // Timer pulse output (for IRQ generation)
);

    // ========================================================================
    // Command codes
    // ========================================================================
    localparam [2:0] CMD_REG_HOLD = 3'd0;  // Normal timekeeping, data_out = 1 Hz
    localparam [2:0] CMD_SHIFT    = 3'd1;  // Shift register on CLK edges
    localparam [2:0] CMD_TIME_SET = 3'd2;  // Load shift register → time counter
    localparam [2:0] CMD_TIME_RD  = 3'd3;  // Copy time counter → shift register
    localparam [2:0] CMD_TP_64    = 3'd4;  // Timer pulse at 64 Hz
    localparam [2:0] CMD_TP_256   = 3'd5;  // Timer pulse at 256 Hz
    localparam [2:0] CMD_TP_2048  = 3'd6;  // Timer pulse at 2048 Hz
    localparam [2:0] CMD_TP_4096  = 3'd7;  // Timer pulse at 4096 Hz

    // ========================================================================
    // State registers
    // ========================================================================
    reg [39:0] shift_reg;       // 40-bit serial shift register
    reg [39:0] time_counter;    // BCD time counter
    reg [2:0]  command;         // Latched command
    reg        prev_clk;        // Previous CLK state (for edge detection)
    reg        prev_stb;        // Previous STB state (for edge detection)

    // ========================================================================
    // 1 Hz Prescaler
    // ========================================================================
    localparam PRESCALER_MAX = CLOCK_SPEED_HZ - 1;
    localparam PRESCALER_BITS = $clog2(CLOCK_SPEED_HZ);

    reg [PRESCALER_BITS-1:0] prescaler;
    wire tick_1hz = (prescaler == PRESCALER_MAX[PRESCALER_BITS-1:0]);
    reg  hz1_toggle;  // 1 Hz square wave for data_out in REG_HOLD mode

    always @(posedge clk) begin
        if (!reset_n) begin
            prescaler <= '0;
            hz1_toggle <= 1'b0;
        end else if (tick_1hz) begin
            prescaler <= '0;
            hz1_toggle <= ~hz1_toggle;
        end else begin
            prescaler <= prescaler + 1'd1;
        end
    end

    // ========================================================================
    // Timer Pulse Prescaler
    // ========================================================================
    localparam TP_64_MAX   = CLOCK_SPEED_HZ / 128 - 1;   // 64 Hz square wave
    localparam TP_256_MAX  = CLOCK_SPEED_HZ / 512 - 1;   // 256 Hz square wave
    localparam TP_2048_MAX = CLOCK_SPEED_HZ / 4096 - 1;  // 2048 Hz square wave
    localparam TP_4096_MAX = CLOCK_SPEED_HZ / 8192 - 1;  // 4096 Hz square wave
    localparam TP_BITS = $clog2(CLOCK_SPEED_HZ / 128);

    reg [TP_BITS-1:0] tp_prescaler;
    reg tp_toggle;

    wire [TP_BITS-1:0] tp_max = (command == CMD_TP_64)  ? TP_64_MAX[TP_BITS-1:0] :
                                (command == CMD_TP_256)  ? TP_256_MAX[TP_BITS-1:0] :
                                (command == CMD_TP_2048) ? TP_2048_MAX[TP_BITS-1:0] :
                                                           TP_4096_MAX[TP_BITS-1:0];

    assign tp_out = (command >= CMD_TP_64) ? tp_toggle : 1'b0;

    // ========================================================================
    // Data output mux
    // ========================================================================
    assign data_out = (command == CMD_REG_HOLD) ? hz1_toggle : shift_reg[0];

    // ========================================================================
    // BCD time counter field extraction (for increment logic)
    // ========================================================================
    wire [3:0] sec_ones  = time_counter[3:0];
    wire [3:0] sec_tens  = time_counter[7:4];
    wire [3:0] min_ones  = time_counter[11:8];
    wire [3:0] min_tens  = time_counter[15:12];
    wire [3:0] hr_ones   = time_counter[19:16];
    wire [3:0] hr_tens   = time_counter[23:20];
    wire [3:0] day_ones  = time_counter[27:24];
    wire [3:0] day_tens  = time_counter[31:28];
    wire [3:0] dow       = time_counter[35:32];
    wire [3:0] month     = time_counter[39:36];

    // Days per month lookup (simplified — no leap year since uPD1990 has no year)
    // Feb = 28, Apr/Jun/Sep/Nov = 30, all others = 31
    reg [5:0] days_in_month;
    always @(*) begin
        case (month)
            4'd2:    days_in_month = 6'd28;
            4'd4:    days_in_month = 6'd30;
            4'd6:    days_in_month = 6'd30;
            4'd9:    days_in_month = 6'd30;
            4'd11:   days_in_month = 6'd30;
            default: days_in_month = 6'd31;
        endcase
    end

    wire [5:0] current_day = {2'b0, day_tens} * 6'd10 + {2'b0, day_ones};

    // ========================================================================
    // BCD increment function
    // ========================================================================
    // Returns {carry, new_tens, new_ones} for a 2-digit BCD field
    function automatic [8:0] bcd_inc(
        input [3:0] ones,
        input [3:0] tens,
        input [3:0] max_tens,
        input [3:0] max_ones_at_max_tens,
        input       carry_in
    );
        reg [3:0] new_ones, new_tens;
        reg       carry_out;
        begin
            carry_out = 1'b0;
            new_ones = ones;
            new_tens = tens;
            if (carry_in) begin
                if (tens == max_tens && ones == max_ones_at_max_tens) begin
                    // Rollover
                    new_ones = 4'd0;
                    new_tens = 4'd0;
                    carry_out = 1'b1;
                end else if (ones == 4'd9) begin
                    new_ones = 4'd0;
                    new_tens = tens + 4'd1;
                end else begin
                    new_ones = ones + 4'd1;
                end
            end
            bcd_inc = {carry_out, new_tens, new_ones};
        end
    endfunction

    // ========================================================================
    // Main sequential logic
    // ========================================================================
    always @(posedge clk) begin
        if (!reset_n) begin
            shift_reg    <= 40'd0;
            time_counter <= 40'h01_01_00_00_00;  // Sun Jan 01 00:00:00
            command      <= CMD_REG_HOLD;
            prev_clk     <= 1'b0;
            prev_stb     <= 1'b0;
            tp_prescaler <= '0;
            tp_toggle    <= 1'b0;
        end else begin
            prev_clk <= clk_in;
            prev_stb <= stb_in;

            // Timer pulse prescaler (free-running)
            if (tp_prescaler >= tp_max) begin
                tp_prescaler <= '0;
                tp_toggle <= ~tp_toggle;
            end else begin
                tp_prescaler <= tp_prescaler + 1'd1;
            end

            // STB rising edge: latch command
            if (stb_in && !prev_stb) begin
                command <= cmd_in;

                case (cmd_in)
                    CMD_TIME_SET: begin
                        // Copy shift register → time counter
                        time_counter <= shift_reg;
                    end
                    CMD_TIME_RD: begin
                        // Copy time counter → shift register
                        shift_reg <= time_counter;
                    end
                    CMD_TP_64, CMD_TP_256, CMD_TP_2048, CMD_TP_4096: begin
                        // Reset timer pulse prescaler on command change
                        tp_prescaler <= '0;
                        tp_toggle <= 1'b0;
                    end
                    default: ;
                endcase
            end

            // CLK rising edge: shift register (when in SHIFT mode)
            if (clk_in && !prev_clk && command == CMD_SHIFT) begin
                // Shift right: MSB gets data_in, LSB is data_out
                shift_reg <= {data_in, shift_reg[39:1]};
            end

            // 1 Hz tick: increment time counter
            if (tick_1hz) begin
                reg sec_carry, min_carry, hr_carry, day_carry;
                reg [8:0] sec_result, min_result, hr_result;
                reg [3:0] new_day_ones, new_day_tens, new_dow, new_month;

                // Seconds: 00 → 59
                sec_result = bcd_inc(sec_ones, sec_tens, 4'd5, 4'd9, 1'b1);
                sec_carry = sec_result[8];

                // Minutes: 00 → 59
                min_result = bcd_inc(min_ones, min_tens, 4'd5, 4'd9, sec_carry);
                min_carry = min_result[8];

                // Hours: 00 → 23
                hr_result = bcd_inc(hr_ones, hr_tens, 4'd2, 4'd3, min_carry);
                hr_carry = hr_result[8];

                // Day of week: 0 → 6
                new_dow = dow;
                if (hr_carry) begin
                    new_dow = (dow == 4'd6) ? 4'd0 : dow + 4'd1;
                end

                // Day of month: 1 → days_in_month
                new_day_ones = day_ones;
                new_day_tens = day_tens;
                day_carry = 1'b0;
                if (hr_carry) begin
                    if (current_day >= days_in_month) begin
                        // Day rollover
                        new_day_ones = 4'd1;
                        new_day_tens = 4'd0;
                        day_carry = 1'b1;
                    end else if (day_ones == 4'd9) begin
                        new_day_ones = 4'd0;
                        new_day_tens = day_tens + 4'd1;
                    end else begin
                        new_day_ones = day_ones + 4'd1;
                    end
                end

                // Month: 1 → 12 (binary, not BCD)
                new_month = month;
                if (day_carry) begin
                    new_month = (month == 4'd12) ? 4'd1 : month + 4'd1;
                end

                time_counter <= {
                    new_month,
                    new_dow,
                    new_day_tens, new_day_ones,
                    hr_result[7:0],
                    min_result[7:0],
                    sec_result[7:0]
                };
            end
        end
    end

endmodule
