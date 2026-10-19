`timescale 1ns/1ps
`default_nettype none

// Immediate generator (combinational). imm_sel picks the RV32I format:
//   0 I: sext(instr[31:20])
//   1 S: sext({instr[31:25], instr[11:7]})
//   2 B: sext({instr[31], instr[7], instr[30:25], instr[11:8], 1'b0})
//   3 U: {instr[31:12], 12'b0}
//   4 J: sext({instr[31], instr[19:12], instr[20], instr[30:21], 1'b0})
// Other values give 0.

module imm_gen (
  input  wire [31:0] instr,
  input  wire [2:0]  imm_sel,
  output reg  [31:0] imm
);

  localparam [2:0] IMM_I = 3'd0;
  localparam [2:0] IMM_S = 3'd1;
  localparam [2:0] IMM_B = 3'd2;
  localparam [2:0] IMM_U = 3'd3;
  localparam [2:0] IMM_J = 3'd4;

  always @(*) begin
    imm = 32'd0;
    case (imm_sel)
      IMM_I: imm = {{20{instr[31]}}, instr[31:20]};
      IMM_S: imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
      IMM_B: imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
      IMM_U: imm = {instr[31:12], 12'd0};
      IMM_J: imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
      default: imm = 32'd0;
    endcase
  end

endmodule

`default_nettype wire
