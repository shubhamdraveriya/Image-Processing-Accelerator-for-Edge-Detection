`timescale 1ns / 1ps

module tb_image_bram;
    logic        clk;
    logic        rd_en;
    logic [11:0] addr;
    logic [7:0]  dout;
    logic        valid_out;

    image_bram uut (.*);

    always #5 clk = ~clk; // 100 MHz clock

    initial begin
        clk = 0; rd_en = 0; addr = 0;
        
        // Wait 100ns for global reset (standard Vivado practice)
        #100;
        
        rd_en = 1;
        // Read the first 10 pixels
        for (int i = 0; i < 10; i++) begin
            addr = i;
            #10;
        end
        rd_en = 0;
        
        #50;
        $stop;
    end
endmodule