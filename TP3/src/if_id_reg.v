`timescale 1ns/1ps
`default_nettype none

// IF/ID pipeline register.
// rst or flush load a bubble (pc = 0, instr = NOP, stop_code = 0,
// valid = 0); flush has priority over hold; hold keeps the contents
// (load-use stall). Nothing changes while en = 0.

module if_id_reg (
  input  wire        clk,
  input  wire        rst,
  input  wire        en,
  input  wire        flush,
  input  wire        hold,
  input  wire [31:0] in_pc,
  input  wire [31:0] in_instr,
  input  wire [2:0]  in_stop_code,
  output reg  [31:0] pc,
  output reg  [31:0] instr,
  output reg  [2:0]  stop_code,
  output reg         valid
);

  localparam [31:0] NOP = 32'h00000013;

  always @(posedge clk) begin
    if (rst) begin
      pc        <= 32'd0;
      instr     <= NOP;
      stop_code <= 3'd0;
      valid     <= 1'b0;
    end else if (en) begin
      if (flush) begin
        pc        <= 32'd0;
        instr     <= NOP;
        stop_code <= 3'd0;
        valid     <= 1'b0;
      end else if (!hold) begin
        pc        <= in_pc;
        instr     <= in_instr;
        stop_code <= in_stop_code;
        valid     <= 1'b1;
      end
    end
  end

endmodule

`default_nettype wire
