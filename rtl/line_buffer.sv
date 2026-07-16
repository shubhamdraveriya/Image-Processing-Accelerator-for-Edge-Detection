`timescale 1ns / 1ps

module window_generator (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] pixel_in,
    input  logic       valid_in,
    
    output logic [7:0] p11, p12, p13, 
    output logic [7:0] p21, p22, p23, 
    output logic [7:0] p31, p32, p33, 
    output logic       valid_out
);
    logic [7:0] lb1 [0:63];
    logic [7:0] lb2 [0:63];
    integer i;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_out <= 1'b0;
            p11<=0; p12<=0; p13<=0;
            p21<=0; p22<=0; p23<=0;
            p31<=0; p32<=0; p33<=0;
            // CRITICAL FIX: Removed the for-loop reset for lb1 and lb2
        end else if (valid_in) begin
            lb1[0] <= pixel_in;
            for (i = 1; i < 64; i = i + 1) lb1[i] <= lb1[i-1];
            
            lb2[0] <= lb1[63];
            for (i = 1; i < 64; i = i + 1) lb2[i] <= lb2[i-1];

            p33 <= pixel_in; p32 <= p33; p31 <= p32;
            p23 <= lb1[63];  p22 <= p23; p21 <= p22;
            p13 <= lb2[63];  p12 <= p13; p11 <= p12;

            valid_out <= 1'b1; 
        end else begin
            valid_out <= 1'b0;
        end
    end
endmodule