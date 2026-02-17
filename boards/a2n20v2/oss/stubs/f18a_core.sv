(* blackbox *)
module f18a_core (
    input  logic        clk_logic_i,
    input  logic        clk_pixel_i,

    // 9918A to Host System Interface
    input  logic        reset_n_i,
    input  logic        mode_i,
    input  logic        csw_n_i,
    input  logic        csr_n_i,
    output logic        int_n_o,
    input  logic [7:0]  cd_i,
    output logic [7:0]  cd_o,

    input  logic [9:0]  raster_x_i,
    input  logic [9:0]  raster_y_i,

    // Video Output
    output logic        blank_o,
    output logic        hsync_o,
    output logic        vsync_o,
    output logic [3:0]  red_o,
    output logic [3:0]  grn_o,
    output logic [3:0]  blu_o,
    output logic        transparent_o,
    output logic        ext_video_o,
    output logic        scanlines_o,

    // Feature Selection
    input  logic        sprite_max_i,
    input  logic        scanlines_i,
    output logic        unlocked_o,
    output logic [3:0]  gmode_o,

    // GPU Status Interface
    output logic        gpu_trigger_o,
    input  logic        gpu_running_i,
    output logic        gpu_pause_o,
    input  logic        gpu_pause_ack_i,
    output logic [15:0] gpu_load_pc_o,

    // GPU VRAM Interface
    output logic [7:0]  gpu_vdin_o,
    input  logic        gpu_vwe_i,
    input  logic [13:0] gpu_vaddr_i,
    input  logic [7:0]  gpu_vdout_i,

    // GPU Palette Interface
    output logic [11:0] gpu_pdin_o,
    input  logic        gpu_pwe_i,
    input  logic [5:0]  gpu_paddr_i,
    input  logic [11:0] gpu_pdout_i,

    // GPU Register Interface
    output logic [7:0]  gpu_rdin_o,
    input  logic [13:0] gpu_raddr_i,
    input  logic        gpu_rwe_i,

    // GPU Data inputs
    output logic [7:0]  gpu_scanline_o,
    output logic        gpu_blank_o,
    output logic [7:0]  gpu_bmlba_o,
    output logic [7:0]  gpu_bml_w_o,
    output logic        gpu_pgba_o,

    // GPU Data output
    input  logic [6:0]  gpu_gstatus_i
);
endmodule
