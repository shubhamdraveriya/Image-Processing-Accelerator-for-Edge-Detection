`timescale 1ns / 1ps

module top_accelerator (
    input  logic       sys_clk,   
    input  logic       rst,       
    input  logic       ready_in,  
    

    output logic       final_serial_out,
    output logic       final_valid_out
);
    
    logic [7:0] pool_data_out;
    logic       pool_valid_out;
    logic       serial_ready_out;
    logic       clk_100, clk_200;
    
    clk_wiz_0 clk_gen (
        .clk_in1  (sys_clk),
        .clk_out1 (clk_100),
        .clk_out2 (clk_200)
    );

    logic [12:0] bram_addr;
    logic        bram_rd_en;
    logic [7:0]  bram_dout;
    logic        bram_valid;
    logic        fifo_full;

    always_ff @(posedge clk_100) begin
        if (rst) begin
            bram_addr  <= 12'd0;
            bram_rd_en <= 1'b0;
        end else if (~fifo_full && bram_addr < 13'd4096) begin
            bram_rd_en <= 1'b1;
            bram_addr  <= bram_addr + 1;
        end else begin
            bram_rd_en <= 1'b0;
        end
    end

    image_bram u_bram (
        .clk       (clk_100),
        .rd_en     (bram_rd_en),
        .addr      (bram_addr[11:0]),
        .dout      (bram_dout),
        .valid_out (bram_valid)
    );

    logic [7:0] fifo_dout;
    logic       fifo_empty;
    logic       fifo_rd_en;
    logic       fifo_data_valid;

    async_fifo u_fifo (
        .rst    (rst),
        .wr_clk (clk_100),
        .rd_clk (clk_200),
        .din    (bram_dout),
        .wr_en  (bram_valid),
        .rd_en  (fifo_rd_en),
        .dout   (fifo_dout),
        .full   (fifo_full),
        .empty  (fifo_empty)
    );

    assign fifo_rd_en = ~fifo_empty;

    always_ff @(posedge clk_200) begin
        if (rst) fifo_data_valid <= 1'b0;
        else     fifo_data_valid <= fifo_rd_en;
    end

    logic [7:0] p11, p12, p13, p21, p22, p23, p31, p32, p33;
    logic       win_valid;
    logic [7:0] sobel_pixel;
    logic       sobel_valid;

    window_generator u_window (
        .clk       (clk_200),
        .rst       (rst),
        .pixel_in  (fifo_dout),
        .valid_in  (fifo_data_valid),
        .p11(p11), .p12(p12), .p13(p13),
        .p21(p21), .p22(p22), .p23(p23),
        .p31(p31), .p32(p32), .p33(p33),
        .valid_out (win_valid)
    );

    sobel_filter u_sobel (
        .clk       (clk_200),
        .rst       (rst),
        .p11(p11), .p12(p12), .p13(p13),
        .p21(p21), .p22(p22), .p23(p23),
        .p31(p31), .p32(p32), .p33(p33),
        .valid_in  (win_valid),
        .pixel_out (sobel_pixel),
        .valid_out (sobel_valid)
    );

    avg_pooling u_pool (
        .clk       (clk_200),
        .rst       (rst),
        .pixel_in  (sobel_pixel),
        .valid_in  (sobel_valid),
        .ready_in  (serial_ready_out),
        .pixel_out (pool_data_out),
        .valid_out (pool_valid_out)
    );
    
    serializer u_serializer (
        .clk           (clk_200),
        .rst           (rst),              
        .parallel_data (pool_data_out),
        .valid_in      (pool_valid_out),
        .ready_out     (serial_ready_out), 
       
        .serial_out    (final_serial_out), 
        .valid_out     (final_valid_out),
        .ready_in      (ready_in)          
    );

endmodule