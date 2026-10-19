`timescale 1ns/1ps
`default_nettype none

// EX/MEM pipeline register. Never stalled or flushed by hazards
// (docs/arquitectura.md 3.4): only rst (bubble, every field 0) and en.
// ctrl is packed in the state-dump layout (docs/protocol.md 6.2):
//   [4:0] rd  [5] reg_write  [6] mem_read  [7] mem_write  [10:8] funct3
//   [11] is_halt  [12] valid

module ex_mem_reg #(
  parameter integer CTRL_W = 13
)(
  input  wire              clk,
  input  wire              rst,
  input  wire              en,
  input  wire [31:0]       in_pc,
  input  wire [31:0]       in_result,
  input  wire [31:0]       in_store_data,
  input  wire [CTRL_W-1:0] in_ctrl,
  output reg  [31:0]       pc,
  output reg  [31:0]       result,
  output reg  [31:0]       store_data,
  output reg  [CTRL_W-1:0] ctrl
);

  always @(posedge clk) begin
    if (rst) begin
      pc         <= 32'd0;
      result     <= 32'd0;
      store_data <= 32'd0;
      ctrl       <= {CTRL_W{1'b0}};
    end else if (en) begin
      pc         <= in_pc;
      result     <= in_result;
      store_data <= in_store_data;
      ctrl       <= in_ctrl;
    end
  end

endmodule

`default_nettype wire
