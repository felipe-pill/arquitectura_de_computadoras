`timescale 1ns/1ps
`default_nettype none


module uart_baudgen #(
  parameter integer CLK_FREQ_HZ = 50_000_000,
  parameter integer BAUD        = 115200
)(
  input  wire clk,
  input  wire rst,
  output reg  tick16    // one-cycle pulse at 16x the baud rate
);

  // Integer-only divider: DIV = clk/(baud*16), at least 1
  localparam integer DIV_CALC = (CLK_FREQ_HZ / (BAUD * 16));
  localparam integer DIV      = (DIV_CALC < 1) ? 1 : DIV_CALC;

  localparam integer CNT_W = (DIV <= 1) ? 1 : $clog2(DIV);
  reg [CNT_W-1:0] cnt = {CNT_W{1'b0}};

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      cnt    <= 0;
      tick16 <= 1'b0;
    end else begin
      if (cnt == DIV-1) begin
        cnt    <= 0;
        tick16 <= 1'b1;
      end else begin
        cnt    <= cnt + 1'b1;
        tick16 <= 1'b0;
      end
    end
  end
endmodule

`default_nettype wire
