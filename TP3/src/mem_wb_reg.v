`timescale 1ns/1ps
`default_nettype none

// MEM/WB pipeline register. Never stalled or flushed by hazards
// (docs/arquitectura.md 3.4): only rst (bubble, every field 0) and en.
// ctrl is packed in the state-dump layout (docs/protocol.md 6.2):
//   [4:0] rd  [5] reg_write  [6] mem_read  [7] is_halt  [8] valid

module mem_wb_reg #(
  parameter integer CTRL_W = 9
)(
  input  wire              clk,
  input  wire              rst,
  input  wire              en,
  input  wire [31:0]       in_pc,
  input  wire [31:0]       in_wb_data,
  input  wire [CTRL_W-1:0] in_ctrl,
  output reg  [31:0]       pc,
  output reg  [31:0]       wb_data,
  output reg  [CTRL_W-1:0] ctrl
);

  always @(posedge clk) begin
    if (rst) begin
      pc      <= 32'd0;
      wb_data <= 32'd0;
      ctrl    <= {CTRL_W{1'b0}};
    end else if (en) begin
      pc      <= in_pc;
      wb_data <= in_wb_data;
      ctrl    <= in_ctrl;
    end
  end

endmodule

`default_nettype wire
