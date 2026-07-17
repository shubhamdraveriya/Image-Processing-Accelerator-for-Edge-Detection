`timescale 1ns / 1ps

module tb_top_accelerator;

// -------------------------------------------------------------------------
    // Testbench Signals
    // -------------------------------------------------------------------------
    logic sys_clk;
    logic rst;
    logic ready_in;
    
    logic final_serial_out; // Changed from [7:0] final_pixel_out
    logic final_valid_out;

    // -------------------------------------------------------------------------
    // Unit Under Test (UUT) Instantiation
    // -------------------------------------------------------------------------
    top_accelerator uut (
        .sys_clk          (sys_clk),
        .rst              (rst),
        .ready_in         (ready_in),
        .final_serial_out (final_serial_out), // Changed to serial port
        .final_valid_out  (final_valid_out)
    );

    // -------------------------------------------------------------------------
    // Clock Generation
    // -------------------------------------------------------------------------
    // 100 MHz oscillator from the Basys 3 board (10 ns period)
    always #5 sys_clk = ~sys_clk;

// -------------------------------------------------------------------------
        // Test Stimulus
        // -------------------------------------------------------------------------
        initial begin
            sys_clk  = 0;
            rst      = 1; 
            ready_in = 1; 
    
            // Wait for MMCM to Lock
            #5000; 
            rst = 0;
    
            // Allow pipeline to fill naturally for a bit
            #2000; 
        end
    
        // -------------------------------------------------------------------------
        // RANDOMIZED BACKPRESSURE GENERATOR (The Professor's Request)
        // -------------------------------------------------------------------------
        always @(posedge sys_clk) begin
            if (!rst) begin
                // $urandom_range(0,100) generates a random number.
                // If it's > 30, ready_in = 1. If < 30, ready_in = 0.
                // This randomly halts the downstream flow 30% of the time, 
                // violently testing your pipeline's backpressure robustness.
                if ($urandom_range(0, 100) > 30) begin
                    ready_in <= 1'b1;
                end else begin
                    ready_in <= 1'b0;
                end
            end
        end
endmodule