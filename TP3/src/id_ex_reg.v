`timescale 1ns/1ps
`default_nettype none

// ID/EX pipeline register.
// ctrl is packed in the state-dump layout (docs/protocol.md 6.2):
//   [4:0] rs1  [9:5] rs2  [14:10] rd  [18:15] alu_op  [19] alu_src
//   [20] link  [21] reg_write  [22] mem_read  [23] mem_write
//   [26:24] funct3  [27] branch  [28] jalr  [29] is_halt  [30] valid
// rst or flush load a bubble: every field 0.
// The core drives flush = ex_redirect | load_use | !if_id_valid
// (docs/arquitectura.md 3.4). Nothing changes while en = 0.

module id_ex_reg #(
  parameter integer CTRL_W = 31
)(
  input  wire              clk,
  input  wire              rst,
  input  wire              en,
  input  wire              flush,
  input  wire [31:0]       in_pc,
  input  wire [31:0]       in_rs1_data,
  input  wire [31:0]       in_rs2_data,
  input  wire [31:0]       in_imm,
  input  wire [CTRL_W-1:0] in_ctrl,
  output reg  [31:0]       pc,
  output reg  [31:0]       rs1_data,
  output reg  [31:0]       rs2_data,
  output reg  [31:0]       imm,
  output reg  [CTRL_W-1:0] ctrl
);

  always @(posedge clk) begin
    if (rst) begin
      pc       <= 32'd0;
      rs1_data <= 32'd0;
      rs2_data <= 32'd0;
      imm      <= 32'd0;
      ctrl     <= {CTRL_W{1'b0}};
    end else if (en) begin
      if (flush) begin
        pc       <= 32'd0;
        rs1_data <= 32'd0;
        rs2_data <= 32'd0;
        imm      <= 32'd0;
        ctrl     <= {CTRL_W{1'b0}};
      end else begin
        pc       <= in_pc;
        rs1_data <= in_rs1_data;
        rs2_data <= in_rs2_data;
        imm      <= in_imm;
        ctrl     <= in_ctrl;
      end
    end
  end

endmodule

`default_nettype wire
