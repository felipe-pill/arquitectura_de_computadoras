`timescale 1ns/1ps
`default_nettype none

module uart #(
  parameter integer CLK_FREQ_HZ = 50_000_000,
  parameter integer BAUD        = 115200
)(
  input  wire clk,
  input  wire rst,

  // TX side
  input  wire        tx_start,
  input  wire [7:0]  tx_data,
  output wire        tx_busy,
  output wire        txd,

  // RX side
  input  wire        rxd,
  output wire [7:0]  rx_data,
  output wire        rx_valid,
  output wire        rx_ferr
);
  wire tick16;

  uart_baudgen #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .BAUD(BAUD)
  ) u_baud (
    .clk(clk), .rst(rst),
    .tick16(tick16)
  );

  uart_tx #(.DATA_BITS(8)) u_tx (
    .clk(clk), .rst(rst),
    .tick16(tick16),
    .start(tx_start),
    .data(tx_data),
    .tx(txd),
    .busy(tx_busy)
  );

  uart_rx #(.DATA_BITS(8)) u_rx (
    .clk(clk), .rst(rst),
    .tick16(tick16),
    .rx(rxd),
    .data(rx_data),
    .data_valid(rx_valid),
    .framing_error(rx_ferr)
  );

endmodule

`default_nettype wire
