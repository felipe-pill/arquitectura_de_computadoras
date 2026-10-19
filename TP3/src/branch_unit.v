`timescale 1ns/1ps
`default_nettype none

// Branch / jalr resolution (combinational, EX stage). docs/arquitectura.md 3.3.
// Static not-taken prediction: redirect only for a taken beq/bne or a jalr.
//   beq/bne: taken if (rs1 == rs2) xor is_bne; target = pc + imm
//   jalr:    always;                          target = (rs1 + imm) & ~1
// rs1_val/rs2_val are the forwarded operands; alu_y = rs1 + imm for jalr.
// The equality comparator is separate from the ALU (parallel path).

module branch_unit (
  input  wire        valid,
  input  wire        branch,
  input  wire        jalr,
  input  wire        is_bne,
  input  wire [31:0] rs1_val,
  input  wire [31:0] rs2_val,
  input  wire [31:0] pc,
  input  wire [31:0] imm,
  input  wire [31:0] alu_y,
  output wire        redirect,
  output wire [31:0] target
);

  wire equal = (rs1_val == rs2_val);
  wire taken = branch && (equal != is_bne);

  assign redirect = valid && (taken || jalr);
  assign target   = jalr ? {alu_y[31:1], 1'b0} : (pc + imm);

endmodule

`default_nettype wire
