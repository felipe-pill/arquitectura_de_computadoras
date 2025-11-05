`timescale 1ns/1ps
`default_nettype none

module tb_uart_loopback;

  // ----- Parameters -----
  localparam integer CLK_FREQ_HZ = 50_000_000;  // 50 MHz
  localparam integer BAUD        = 1_000_000;   // fast for sim; works with your baudgen math

  // ----- Clock & Reset -----
  reg clk = 1'b0;
  always #10 clk = ~clk; // 20 ns period -> 50 MHz

  reg rst = 1'b1;

  // ----- DUT Interface -----
  reg        tx_start = 1'b0;
  reg  [7:0] tx_data  = 8'h00;
  wire       tx_busy;
  wire       txd;

  wire       rxd;
  wire [7:0] rx_data;
  wire       rx_valid;
  wire       rx_ferr;

  // Add a tiny wire delay on loopback (avoids zero-delay feedback weirdness)
  wire rxd_delayed;
  assign #1 rxd_delayed = txd;
  assign rxd = rxd_delayed;

  // ----- DUT -----
  uart #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .BAUD(BAUD)
  ) dut (
    .clk(clk),
    .rst(rst),

    // TX side
    .tx_start(tx_start),
    .tx_data(tx_data),
    .tx_busy(tx_busy),
    .txd(txd),

    // RX side
    .rxd(rxd),
    .rx_data(rx_data),
    .rx_valid(rx_valid),
    .rx_ferr(rx_ferr)
  );

  // ----- Byte Vector -----
  reg [7:0] vec [0:5];
  integer i;

  // ----- Send one byte (stretched start until tx_busy=1) -----
  task send_byte(input [7:0] b);
    begin
      // Wait for transmitter idle
      @(posedge clk);
      wait (!tx_busy);

      // Present data and assert start
      tx_data  <= b;
      tx_start <= 1'b1;

      // Keep tx_start high until the DUT acknowledges by asserting tx_busy
      while (!tx_busy) @(posedge clk);

      // One extra cycle for safety
      @(posedge clk);
      tx_start <= 1'b0;
    end
  endtask

  // ----- Expect one byte -----
  task expect_byte(input [7:0] b);
    integer timeout;
    begin
      timeout = 0;
      // Wait for rx_valid (simple guard)
      while (!rx_valid) begin
        @(posedge clk);
        timeout = timeout + 1;
        if (timeout > 100000) begin
          $display("** TIMEOUT waiting for byte 0x%02h **", b);
          $fatal;
        end
      end

      if (rx_ferr) begin
        $display("** FRAMING ERROR receiving 0x%02h **", b);
        $fatal;
      end

      if (rx_data !== b) begin
        $display("** MISMATCH sent=0x%02h received=0x%02h **", b, rx_data);
        $fatal;
      end

      $display("[%0t ns] PASS - byte 0x%02h OK", $time, b);
    end
  endtask

  // ----- Stimulus -----
  initial begin
    // VCD for waveform (Icarus/Verilator/etc.)
    $dumpfile("uart_loopback.vcd");
    $dumpvars(0, tb_uart_loopback);

    $display("\n=== UART LOOPBACK TEST START ===");

    // Load bytes
    vec[0] = 8'h00;
    vec[1] = 8'hFF;
    vec[2] = 8'h55;
    vec[3] = 8'hA5;
    vec[4] = 8'h7E;
    vec[5] = 8'h3C;

    // Reset
    rst <= 1'b1;
    repeat (10) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);

    // Send + verify
    for (i = 0; i < 6; i = i + 1) begin
      send_byte(vec[i]);
      expect_byte(vec[i]);
      // small gap
      repeat (4) @(posedge clk);
    end

    $display("=== ALL BYTES RECEIVED CORRECTLY ✅ ===\n");
    #200;
    $finish;
  end

endmodule

`default_nettype wire
