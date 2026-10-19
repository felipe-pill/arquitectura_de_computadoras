`timescale 1ns/1ps
`default_nettype none

// HALT / drain state and cycle counter. docs/arquitectura.md 5.
// - halt_accept (a stop slot accepted in ID) sets halting and latches the
//   reason.
// - When the HALT marker leaves MEM/WB (wb_halt), halted is set and halting
//   is cleared: the pipeline is empty from then on.
// - cycle_cnt counts enabled cycles since reset; timeout = cycle_cnt >=
//   MAX_CYCLES.
// en is the core's internal enable (en && !halted), so nothing changes once
// halted.

module halt_ctrl #(
  parameter integer MAX_CYCLES = 1000000
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        en,
  input  wire        halt_accept,
  input  wire [2:0]  halt_reason_in,
  input  wire        wb_halt,
  output reg         halting,
  output reg         halted,
  output reg  [2:0]  halt_reason,
  output reg  [31:0] cycle_cnt,
  output wire        timeout
);

  always @(posedge clk) begin
    if (rst) begin
      halting     <= 1'b0;
      halted      <= 1'b0;
      halt_reason <= 3'd0;
      cycle_cnt   <= 32'd0;
    end else if (en) begin
      cycle_cnt <= cycle_cnt + 32'd1;
      if (halt_accept) begin
        halting     <= 1'b1;
        halt_reason <= halt_reason_in;
      end
      if (wb_halt) begin
        halting <= 1'b0;
        halted  <= 1'b1;
      end
    end
  end

  assign timeout = (cycle_cnt >= MAX_CYCLES);

endmodule

`default_nettype wire
