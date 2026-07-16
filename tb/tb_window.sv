`timescale 1ns / 1ps

module tb_window_generator;
    logic clk, rst, valid_in, valid_out;
    logic [7:0] pixel_in;
    logic [7:0] p11, p12, p13, p21, p22, p23, p31, p32, p33;

    window_generator uut (.*);

    always #5 clk = ~clk; // 100 MHz clock

    initial begin
        clk = 0; rst = 1; valid_in = 0; pixel_in = 0;
        
        // Wait 100ns for global reset
        #100;
        rst = 0;
        #10;
        
        // Feed in exactly 3 rows of data (3 * 64 = 192 pixels).
        // We use incrementing numbers (1 to 192) so you can track them in the waveform.
        for (int i = 1; i <= 192; i++) begin
            valid_in = 1;
            pixel_in = i;
            #10;
        end
        valid_in = 0;
        
        #50;
        $stop;
    end
endmodule