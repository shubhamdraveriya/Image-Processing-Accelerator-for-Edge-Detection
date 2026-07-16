`timescale 1ns / 1ps

module sobel_filter (
    input  logic       clk,
    input  logic       rst,
    
    // 3x3 Window Inputs
    input  logic [7:0] p11, p12, p13,
    input  logic [7:0] p21, p22, p23,
    input  logic [7:0] p31, p32, p33,
    input  logic       valid_in,
    
    output logic [7:0] pixel_out,
    output logic       valid_out
);

    // ==========================================
    // STAGE 1: Calculate Differences 
    // (Only 1 subtraction per clock)
    // ==========================================
    logic signed [9:0] d1x, d2x, d3x, d1y, d2y, d3y;
    logic v1;

    // ==========================================
    // STAGE 2: Calculate Gradients (Gx, Gy)
    // (Only 2 additions per clock)
    // ==========================================
    logic signed [10:0] gx, gy;
    logic v2;

    // ==========================================
    // STAGE 3: Absolute Sum (Manhattan Distance)
    // ==========================================
    logic [11:0] sum;
    logic v3;

    always_ff @(posedge clk) begin
        if (rst) begin
            d1x<=0; d2x<=0; d3x<=0;
            d1y<=0; d2y<=0; d3y<=0; v1<=0;
            gx<=0; gy<=0; v2<=0;
            sum<=0; v3<=0;
            pixel_out<=0; valid_out<=0;
        end else begin
            // --- STAGE 1: Subtract columns/rows ---
            d1x <= $signed({2'b0, p13}) - $signed({2'b0, p11});
            d2x <= $signed({2'b0, p23}) - $signed({2'b0, p21});
            d3x <= $signed({2'b0, p33}) - $signed({2'b0, p31});

            d1y <= $signed({2'b0, p11}) - $signed({2'b0, p31});
            d2y <= $signed({2'b0, p12}) - $signed({2'b0, p32});
            d3y <= $signed({2'b0, p13}) - $signed({2'b0, p33});
            v1  <= valid_in;

            // --- STAGE 2: Multiply by 2 (shift) and accumulate ---
            gx <= d1x + (d2x <<< 1) + d3x;
            gy <= d1y + (d2y <<< 1) + d3y;
            v2 <= v1;

            // --- STAGE 3: Absolute values and Add ---
            sum <= ((gx[10]) ? -gx : gx) + ((gy[10]) ? -gy : gy);
            v3  <= v2;

            // --- STAGE 4: Clamp to 255 (Output Register) ---
            pixel_out <= (sum > 12'd255) ? 8'd255 : sum[7:0];
            valid_out <= v3;
        end
    end
endmodule