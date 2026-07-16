`timescale 1ns / 1ps

module image_bram (
    input  logic        clk,
    input  logic        rd_en,
    input  logic [11:0] addr,
    output logic [7:0]  dout,
    output logic        valid_out
);
    (* ram_style = "block" *) logic [7:0] ram [0:4095];

    
    initial begin
        
        for (int i = 0; i < 4096; i++) begin
            ram[i] = 8'h00;
        end
        
        $readmemh("image.mem", ram);
    end

    
    always_ff @(posedge clk) begin
        if (rd_en) begin
            dout      <= ram[addr];
            valid_out <= 1'b1;
        end else begin
            dout      <= 8'h00; 
            valid_out <= 1'b0;
        end
    end
endmodule