`timescale 1ns / 1ps

module tb_sobel_filter;
    logic clk, rst, valid_in, valid_out;
    logic [7:0] p11, p12, p13, p21, p22, p23, p31, p32, p33, pixel_out;

    sobel_filter uut (.*);

    always #5 clk = ~clk; // 100 MHz clock

    initial begin
        clk = 0; rst = 1; valid_in = 0;
        p11=0; p12=0; p13=0; p21=0; p22=0; p23=0; p31=0; p32=0; p33=0;
        
        #100 rst = 0; #10;
        
        // Test 1: Flat Region (All pixels same color)
        // Expected behavior: pixel_out stays 0
        p11=100; p12=100; p13=100;
        p21=100; p22=100; p23=100;
        p31=100; p32=100; p33=100;
        valid_in = 1;
        #100;
        
        // Test 2: Sharp Vertical Edge (Left is black, Right is white)
        // Expected behavior: Gx spikes, pixel_out hits 255
        p11=0; p12=0; p13=255;
        p21=0; p22=0; p23=255;
        p31=0; p32=0; p33=255;
        #100;
        
        // Test 3: Sharp Horizontal Edge (Top is white, Bottom is black)
        // Expected behavior: Gy spikes, pixel_out hits 255
        p11=255; p12=255; p13=255;
        p21=0;   p22=0;   p23=0;
        p31=0;   p32=0;   p33=0;
        #100;
        
        valid_in = 0;
        #50;
        $stop;
    end
endmodule