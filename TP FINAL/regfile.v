`timescale 1ns/1ps
`default_nettype none

module regfile (
    input  wire        clk,
    input  wire  [4:0] rs1,
    input  wire  [4:0] rs2,
    input  wire  [4:0] rd,
    input  wire [31:0] wd,
    input  wire        we,

    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data
);

  // 32 registros de 32 bits
  reg [31:0] regs [0:31];

  // Lecturas combinacionales
  assign rs1_data = (rs1 == 5'd0) ? 32'h0 : regs[rs1];
  assign rs2_data = (rs2 == 5'd0) ? 32'h0 : regs[rs2];

  // Escritura síncrona
  always @(posedge clk) begin
    if (we && (rd != 5'd0)) begin
      regs[rd] <= wd;
    end
  end

endmodule

`default_nettype wire
