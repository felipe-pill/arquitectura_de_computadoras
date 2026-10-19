`timescale 1ns/1ps
`default_nettype none

// RV32I ALU (combinational).
// op = {alt, funct3}, the natural RISC-V encoding (docs/arquitectura.md 2.4):
//   0000 add  1000 sub  0001 sll  0010 slt  0011 sltu
//   0100 xor  0101 srl  1101 sra  0110 or   0111 and
// Shifts use b[4:0]. Any other op gives 0 (the decoder never emits one).

module alu #(
  parameter integer XLEN = 32
)(
  input  wire [XLEN-1:0] a,
  input  wire [XLEN-1:0] b,
  input  wire [3:0]      op,
  output reg  [XLEN-1:0] y
);

  localparam [3:0] ALU_ADD  = 4'b0000;
  localparam [3:0] ALU_SUB  = 4'b1000;
  localparam [3:0] ALU_SLL  = 4'b0001;
  localparam [3:0] ALU_SLT  = 4'b0010;
  localparam [3:0] ALU_SLTU = 4'b0011;
  localparam [3:0] ALU_XOR  = 4'b0100;
  localparam [3:0] ALU_SRL  = 4'b0101;
  localparam [3:0] ALU_SRA  = 4'b1101;
  localparam [3:0] ALU_OR   = 4'b0110;
  localparam [3:0] ALU_AND  = 4'b0111;

  localparam integer SHAMT_W = $clog2(XLEN);

  wire [SHAMT_W-1:0] shamt = b[SHAMT_W-1:0];

  always @(*) begin
    y = {XLEN{1'b0}};
    case (op)
      ALU_ADD:  y = a + b;
      ALU_SUB:  y = a - b;
      ALU_SLL:  y = a << shamt;
      ALU_SLT:  y = {{(XLEN-1){1'b0}}, $signed(a) < $signed(b)};
      ALU_SLTU: y = {{(XLEN-1){1'b0}}, a < b};
      ALU_XOR:  y = a ^ b;
      ALU_SRL:  y = a >> shamt;
      ALU_SRA:  y = $signed(a) >>> shamt;
      ALU_OR:   y = a | b;
      ALU_AND:  y = a & b;
      default:  y = {XLEN{1'b0}};
    endcase
  end

endmodule

`default_nettype wire
