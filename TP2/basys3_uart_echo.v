`timescale 1ns/1ps
`default_nettype none

module basys3_uart_echo (
  input  wire clk100mhz,     // 100 MHz system clock
  input  wire btn_reset_n,   // center button, active-low
  input  wire uart_rxd,      // from PC (FTDI)
  output wire uart_txd      // to PC (FTDI)

  // optional debug LEDs (uncomment ports + XDC if you want)
  // output wire led_tx_busy,
  // output wire led_rx_valid
);

  // --------------------------------------------------------------------------
  // Reset: make it active-high and synchronize
  // --------------------------------------------------------------------------
reg rst_sync = 1'b1;
always @(posedge clk100mhz) begin
  rst_sync <= btn_reset_n;  // direct sample, active high
end

wire rst = rst_sync;



  // --------------------------------------------------------------------------
  // UART instance (your core)
  // --------------------------------------------------------------------------
  localparam integer CLK_FREQ_HZ = 100_000_000;  // Basys-3 clock
  localparam integer BAUD        = 115200;       // PC terminal default

  // TX iface
  reg        tx_start = 1'b0;
  reg  [7:0] tx_data  = 8'h00;
  wire       tx_busy;
  wire       txd;

  // RX iface
  wire       rxd = uart_rxd;  // your RX does oversampling; direct is fine
  wire [7:0] rx_data;
  wire       rx_valid;
  wire       rx_ferr;

  uart #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .BAUD(BAUD)
  ) u_uart (
    .clk     (clk100mhz),
    .rst     (rst),

    .tx_start(tx_start),
    .tx_data (tx_data),
    .tx_busy (tx_busy),
    .txd     (txd),

    .rxd     (rxd),
    .rx_data (rx_data),
    .rx_valid(rx_valid),
    .rx_ferr (rx_ferr)
  );

  assign uart_txd = txd;

  // --------------------------------------------------------------------------
  // Simple echo path with a tiny 1-byte holding register
  // --------------------------------------------------------------------------
  reg        hold_v = 1'b0;
  reg  [7:0] hold_b = 8'h00;

  // tx_start must be a 1-cycle pulse on clk
  always @(posedge clk100mhz or posedge rst) begin
    if (rst) begin
      tx_start <= 1'b0;
      tx_data  <= 8'h00;
      hold_v   <= 1'b0;
      hold_b   <= 8'h00;
    end else begin
      // default deassert
      tx_start <= 1'b0;

      // capture newly received byte
      if (rx_valid) begin
        if (!tx_busy) begin
          // transmitter free -> send immediately
          tx_data  <= rx_data;
          tx_start <= 1'b1;
        end else begin
          // transmitter busy -> stash one byte
          hold_b <= rx_data;
          hold_v <= 1'b1;
        end
      end

      // if we have a stashed byte and TX became free, send it
      if (hold_v && !tx_busy) begin
        tx_data  <= hold_b;
        tx_start <= 1'b1;
        hold_v   <= 1'b0;
      end
    end
  end

  // optional LEDs
  // assign led_tx_busy = tx_busy;
  // assign led_rx_valid = rx_valid;

endmodule

`default_nettype wire
