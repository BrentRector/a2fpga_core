(* blackbox *)
module via6522 (
    input  logic        clock,
    input  logic        rising,
    input  logic        falling,
    input  logic        reset,

    input  logic [3:0]  addr,
    input  logic        wen,
    input  logic        ren,
    input  logic [7:0]  data_in,
    output logic [7:0]  data_out,

    output logic        phi2_ref,

    // pio
    output logic [7:0]  port_a_o,
    output logic [7:0]  port_a_t,
    input  logic [7:0]  port_a_i,

    output logic [7:0]  port_b_o,
    output logic [7:0]  port_b_t,
    input  logic [7:0]  port_b_i,

    // handshake pins
    input  logic        ca1_i,

    output logic        ca2_o,
    input  logic        ca2_i,
    output logic        ca2_t,

    output logic        cb1_o,
    input  logic        cb1_i,
    output logic        cb1_t,

    output logic        cb2_o,
    input  logic        cb2_i,
    output logic        cb2_t,

    output logic        irq
);
endmodule
