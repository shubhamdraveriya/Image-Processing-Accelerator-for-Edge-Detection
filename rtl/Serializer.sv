`timescale 1ns / 1ps

module serializer (
    input  logic       clk,
    input  logic       rst,
    
   
    input  logic [7:0] parallel_data,
    input  logic       valid_in,
    output logic       ready_out, 
    

    output logic       serial_out,
    output logic       valid_out,
    input  logic       ready_in   
);

    logic [7:0] shift_reg;
    logic [2:0] bit_cnt;

   
    assign ready_out = (!valid_out) || (ready_in && bit_cnt == 0);

    always_ff @(posedge clk) begin
        if (rst) begin
            shift_reg  <= 8'd0;
            bit_cnt    <= 3'd0;
            serial_out <= 1'b0;
            valid_out  <= 1'b0;
        end else if (ready_out && valid_in) begin
       
            shift_reg  <= parallel_data;
            bit_cnt    <= 3'd7;
            serial_out <= parallel_data[7]; 
            valid_out  <= 1'b1;
        end else if (ready_in && valid_out) begin
           
            if (bit_cnt > 0) begin
                bit_cnt    <= bit_cnt - 1;
                shift_reg  <= {shift_reg[6:0], 1'b0}; 
                serial_out <= shift_reg[6];           
                valid_out  <= 1'b1;
            end else begin
                
                valid_out  <= 1'b0;
            end
        end
    end
endmodule