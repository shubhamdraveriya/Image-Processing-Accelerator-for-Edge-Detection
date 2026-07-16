`timescale 1ns / 1ps

module avg_pooling (
    input  logic       clk,
    input  logic       rst,
    input  logic [7:0] pixel_in,
    input  logic       valid_in,
    input  logic       ready_in,  
    
    output logic [7:0] pixel_out,
    output logic       valid_out
);
    // Depth of 65 holds a full row + 1 extra pixel
    logic [7:0] lb [0:64]; 
    logic [6:0] col_count;
    logic [6:0] row_count;

    logic [8:0] sum_top;
    logic [8:0] sum_bot;
    logic       valid_d1;
    integer i;

    always_ff @(posedge clk) begin
        if (rst) begin
            col_count  <= 0;
            row_count  <= 0;
            valid_out  <= 0;
            pixel_out  <= 0;
            valid_d1   <= 0;
            sum_top    <= 0;
            sum_bot    <= 0;
            // No reset for shift register array 'lb'
        end else if (valid_in && ready_in) begin
            // 1. Shift Register (No dynamic multiplexers!)
            lb[0] <= pixel_in;
            for (i = 1; i <= 64; i = i + 1) begin
                lb[i] <= lb[i-1];
            end

            // 2. Math Stage 1: Add the 2x2 grid using fixed physical taps
            if (col_count[0] == 1'b1 && row_count[0] == 1'b1) begin
                sum_bot  <= pixel_in + lb[0]; // Bottom row
                sum_top  <= lb[63] + lb[64];  // Top row
                valid_d1 <= 1'b1;
            end else begin
                valid_d1 <= 1'b0;
            end

            // 3. Update Counters
            if (col_count == 63) begin
                col_count <= 0;
                row_count <= row_count + 1;
            end else begin
                col_count <= col_count + 1;
            end
        end else begin
            valid_d1 <= 1'b0; 
        end

        // 4. Math Stage 2: Final addition and division
        if (rst) begin
            valid_out <= 1'b0;
            pixel_out <= 8'd0;
        end else if (ready_in) begin
            if (valid_d1) begin
                pixel_out <= (sum_top + sum_bot) >> 2;
            end
            valid_out <= valid_d1;
        end
    end
endmodule