module tb_uart;
  reg  clk=0, rst=1;
  wire txd;
  wire rxd = txd; // loopback
  reg        tx_valid=0;
  reg  [7:0] tx_data = 8'h00;
  wire       tx_ready;
  wire       rx_valid;
  wire [7:0] rx_data;
  reg        rx_ready=1;
  wire       frame_err;

  // 100 MHz clock
  always #5 clk = ~clk;

  uart #(.CLK_FREQ_HZ(100_000_000), .BAUD(115200)) dut (
    .clk(clk), .rst(rst),
    .rxd(rxd), .txd(txd),
    .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready),
    .rx_valid(rx_valid), .rx_data(rx_data), .rx_ready(rx_ready),
    .frame_err(frame_err)
  );

  reg [7:0] vec [0:3];
  integer i;

  initial begin
    vec[0]=8'h55; vec[1]=8'h00; vec[2]=8'hFF; vec[3]=8'hA5;

    // reset
    repeat(10) @(posedge clk);
    rst = 0;

    // send bytes when ready
    for (i=0; i<4; i=i+1) begin
      @(posedge clk);
      wait(tx_ready);
      tx_data  <= vec[i];
      tx_valid <= 1'b1;
      @(posedge clk);
      tx_valid <= 1'b0;

      // wait for rx
      wait(rx_valid);
      if (frame_err) $display("FRAME ERR at i=%0d", i);
      if (rx_data !== vec[i]) begin
        $display("MISMATCH: got %02x expected %02x at %0t", rx_data, vec[i], $time);
      end else begin
        $display("OK: %02x at %0t", rx_data, $time);
      end
      @(posedge clk); // consume
    end

    // small drain
    repeat(10000) @(posedge clk);
    $finish;
  end
endmodule
