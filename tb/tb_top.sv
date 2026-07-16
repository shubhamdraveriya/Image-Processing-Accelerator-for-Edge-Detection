`timescale 1ns / 1ps

module tb_top_accelerator;

    // -------------------------------------------------------------------------
    // Testbench Signals
    // -------------------------------------------------------------------------
    logic       sys_clk;
    logic       rst;
    logic       ready_in;
    
    logic [7:0] final_pixel_out;
    logic       final_valid_out;

    // -------------------------------------------------------------------------
    // Unit Under Test (UUT) Instantiation
    // -------------------------------------------------------------------------
    top_accelerator uut (
        .sys_clk         (sys_clk),
        .rst             (rst),
        .ready_in        (ready_in),
        .final_pixel_out (final_pixel_out),
        .final_valid_out (final_valid_out)
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
        // 1. Initialize Inputs
        sys_clk  = 0;
        rst      = 1;  // Start in reset
        ready_in = 1;  // Tell the FPGA we are ready to receive data

        // 2. Wait for MMCM to Lock (Crucial for Xilinx Simulations)
        // Hold reset HIGH for 5,000 ns to guarantee clk_100 and clk_200 
        // are actively toggling before the Async FIFO releases from reset.
        #5000; 
        
        // Release global reset
        rst = 0;

        // 3. Wait for the pipeline to fill
        // It takes roughly 130 clocks just to fill the Window Generator's line buffers,
        // plus the Sobel pipeline and the Pooling module's math stages.
        #5000; 

        // 4. Test Downstream Backpressure (Handshaking)
        // Simulate the receiving device (e.g., UART or another FPGA) being busy
        ready_in = 0;
        #250; // Pause for 250 ns 
        
        // Re-assert ready_in
        ready_in = 1;

        // 5. Steady-State Run
        // Let the simulation run long enough to process several rows of the image.
        // A full 64x64 image at 100 MHz takes roughly 40,960 ns.
        #50000;

        // Safely end simulation
        $stop;
    end

endmodule