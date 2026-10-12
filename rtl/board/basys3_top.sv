`timescale 1ns / 1ps
// Built in Vivado 2018.2 (timing met, bitstream written); not yet run on a board.
// -----------------------------------------------------------------------------
// basys3_top: Basys 3 (XC7A35T) wrapper. The only board-specific RTL:
// it instantiates the clk_wiz_0 IP (100 MHz in -> 100 MHz + 200 MHz out) and
// maps the vendor-neutral edge_accel_top to the board pins in
// constraints/basys3.xdc.
// -----------------------------------------------------------------------------
module basys3_top (
    input  logic sys_clk,        // 100 MHz oscillator (W5)
    input  logic rst,            // BTNC, active high
    input  logic ready_in,       // SW0: downstream ready

    output logic final_serial_out,   // Pmod JA1
    output logic final_valid_out,    // Pmod JA2 and LED0
    output logic final_bit_last,     // Pmod JA3
    output logic led_valid,          // LED0 (mirror of final_valid_out)
    output logic led_framing_err,    // LED14
    output logic led_done            // LED15
);
    logic clk_100, clk_200;

    clk_wiz_0 u_clk (
        .clk_in1  (sys_clk),
        .clk_out1 (clk_100),
        .clk_out2 (clk_200)
    );

    logic framing_err_q;

    // SW0 is asynchronous to clk_200 and fans out to the whole output stage:
    // bring it in through two flip-flops first
    (* ASYNC_REG = "TRUE" *) logic [1:0] ready_sync;
    always_ff @(posedge clk_200) ready_sync <= {ready_sync[0], ready_in};

    edge_accel_top #(
        .DW(8), .IMG_W(64), .IMG_H(64), .NUM_FRAMES(0),
        .INIT_FILE("image_stripes_64x64.mem")
    ) u_core (
        .clk_src      (clk_100),
        .clk_proc     (clk_200),
        .rst          (rst),
        .serial_out   (final_serial_out),
        .serial_valid (final_valid_out),
        .serial_last  (final_bit_last),
        .serial_ready (ready_sync[1]),
        .framing_err  (framing_err_q),
        .src_done     (led_done)
    );

    assign led_valid = final_valid_out;

    // Make the single-cycle framing error pulse visible on an LED.
    logic rst_200, err_sticky;
    reset_sync u_rst_200 (.clk(clk_200), .rst_async(rst), .rst_sync(rst_200));
    always_ff @(posedge clk_200) begin
        if (rst_200)            err_sticky <= 1'b0;
        else if (framing_err_q) err_sticky <= 1'b1;
    end
    assign led_framing_err = err_sticky;
endmodule
