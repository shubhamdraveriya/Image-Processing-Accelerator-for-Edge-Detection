`timescale 1ns / 1ps

module tb_avg_pooling;
    logic clk, rst, valid_in, ready_in, valid_out;
    logic [7:0] pixel_in, pixel_out;

    // Instantiate Unit Under Test
    avg_pooling uut (.*);

    // 200 MHz clock (5 ns period)
    always #2.5 clk = ~clk; 

    initial begin
        // ---------------------------------------------------------
        // 1. Initialize and Reset
        // ---------------------------------------------------------
        clk      = 0; 
        rst      = 1; 
        valid_in = 0; 
        ready_in = 1; 
        pixel_in = 0;
        
        // Hold reset for 100ns, then release exactly on a clock edge
        #100;
        @(posedge clk);
        rst <= 0;
        #20; // Brief pause before sending data

        // ---------------------------------------------------------
        // 2. Simulate Row 0 (Even Row - 64 pixels)
        // ---------------------------------------------------------
        // We want the first two pixels to be 170, and the rest 0
        for (int i = 0; i < 64; i++) begin
            @(posedge clk);
            valid_in <= 1;
            if (i == 0 || i == 1) 
                pixel_in <= 8'd170;
            else                  
                pixel_in <= 8'd0;
        end

        // ---------------------------------------------------------
        // 3. Simulate Row 1 (Odd Row - 64 pixels)
        // ---------------------------------------------------------
        // We want the first two pixels to be 50, and the rest 0
        // When i == 1, the 2x2 grid (170, 170, 50, 50) is complete!
        for (int i = 0; i < 64; i++) begin
            @(posedge clk);
            valid_in <= 1;
            if (i == 0 || i == 1) 
                pixel_in <= 8'd50;
            else                  
                pixel_in <= 8'd0;
        end

        // ---------------------------------------------------------
        // 4. Flush the Pipeline
        // ---------------------------------------------------------
        // Drop valid_in and wait for the math pipeline to finish
        @(posedge clk);
        valid_in <= 0;
        pixel_in <= 8'd0;

        #100;
        $stop;
    end
endmodule