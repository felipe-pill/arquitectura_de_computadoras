`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for dbg_tx_frame.
// Spec (docs/protocol.md 3.2, 3.3): on start, send 5A RSP LEN_lo LEN_hi
// PAYLOAD[LEN] CHK with CHK = -(RSP + LEN_lo + LEN_hi + payload) mod 256;
// payload byte i is requested from the source with src_idx = i, in order;
// done pulses once at the end.
// The UART transmitter is modeled with the TP2 uart_tx handshake: tx_start
// accepted only while !tx_busy, busy rises the next cycle and stays high for
// a random number of cycles. The byte source answers after a random delay
// with byte(i) = i * 7 + 3 (mod 256).

module tb_dbg_tx_frame;

  localparam integer CLK_PERIOD = 10;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg         rst = 1'b1, start = 1'b0;
  reg  [7:0]  rsp = 8'd0;
  reg  [15:0] len = 16'd0;
  wire        src_req, tx_start, done, busy;
  wire [15:0] src_idx;
  reg         src_valid = 1'b0;
  reg  [7:0]  src_byte = 8'd0;
  wire [7:0]  tx_data;
  reg         tx_busy = 1'b0;

  dbg_tx_frame dut (
    .clk(clk), .rst(rst), .start(start), .rsp(rsp), .len(len),
    .src_req(src_req), .src_idx(src_idx), .src_valid(src_valid), .src_byte(src_byte),
    .tx_start(tx_start), .tx_data(tx_data), .tx_busy(tx_busy), .done(done), .busy(busy)
  );

  integer seed = 2026;

  // ---------------- UART tx model ----------------
  reg [7:0] sent [0:4999];
  integer   n_sent = 0;
  integer   busy_left = 0;
  integer   start_while_busy = 0;

  always @(posedge clk) begin
    if (tx_start && tx_busy) start_while_busy = start_while_busy + 1;
    if (tx_start && !tx_busy) begin
      sent[n_sent] = tx_data;
      n_sent = n_sent + 1;
      busy_left = 2 + ($unsigned($random(seed)) % 6);
      tx_busy <= 1'b1;
    end else if (busy_left > 0) begin
      busy_left = busy_left - 1;
      if (busy_left == 0) tx_busy <= 1'b0;
    end
  end

  // ---------------- byte source model ----------------
  integer    n_req = 0;
  integer    req_order_errors = 0;
  integer    countdown = -1;     // cycles until the answer, -1 = idle
  reg [15:0] req_idx = 16'd0;

  always @(posedge clk) begin
    src_valid <= 1'b0;
    if (src_req) begin
      if (src_idx != n_req) req_order_errors = req_order_errors + 1;
      n_req = n_req + 1;
      req_idx = src_idx;
      countdown = $unsigned($random(seed)) % 5;
    end else if (countdown == 0) begin
      src_byte  <= req_idx * 7 + 3;
      src_valid <= 1'b1;
      countdown = -1;
    end else if (countdown > 0) begin
      countdown = countdown - 1;
    end
  end

  integer n_done = 0;
  always @(posedge clk) if (done) n_done = n_done + 1;

  // ---------------- checks ----------------
  integer errors = 0, checks = 0;
  integer i, k;
  reg [7:0] sum;
  reg       good;

  task run_frame;
    input [7:0]  t_rsp;
    input [15:0] t_len;
    begin
      n_sent = 0; n_req = 0; n_done = 0; req_order_errors = 0; start_while_busy = 0;
      @(negedge clk);
      rsp = t_rsp; len = t_len; start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      k = 0;
      while (n_done == 0 && k < 20 * (t_len + 10)) begin @(negedge clk); k = k + 1; end
      repeat (5) @(negedge clk);

      checks = checks + 1;
      good = (n_sent == t_len + 5) && (n_done == 1) && (n_req == t_len) &&
             (req_order_errors == 0) && (start_while_busy == 0) && !busy;
      if (good) good = (sent[0] == 8'h5A) && (sent[1] == t_rsp) &&
                       (sent[2] == t_len[7:0]) && (sent[3] == t_len[15:8]);
      sum = t_rsp + t_len[7:0] + t_len[15:8];
      for (i = 0; i < t_len && good; i = i + 1) begin
        if (sent[4 + i] !== (i * 7 + 3) % 256) good = 1'b0;
        sum = sum + sent[4 + i];
      end
      if (good && sent[4 + t_len] !== (8'd0 - sum)) good = 1'b0;
      if (good) begin
        $display("PASS frame rsp=%02h len=%0d: %0d bytes, checksum %02h, done once",
                 t_rsp, t_len, n_sent, sent[4 + t_len]);
      end else begin
        errors = errors + 1;
        $display("FAIL frame rsp=%02h len=%0d: sent=%0d (exp %0d) done=%0d req=%0d order_err=%0d start_while_busy=%0d busy=%b  TEST FAILED",
                 t_rsp, t_len, n_sent, t_len + 5, n_done, n_req, req_order_errors, start_while_busy, busy);
        for (i = 0; i < n_sent && i < 12; i = i + 1) $display("     byte %0d = %02h", i, sent[i]);
      end
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;
    run_frame(8'h82, 16'd0);      // RESET ok, no payload (5A 82 00 00 7E)
    run_frame(8'hE4, 16'd1);      // error, 1 byte
    run_frame(8'h81, 16'd2);      // LOAD ok
    run_frame(8'h85, 16'd204);    // STATE without dmem
    run_frame(8'h83, 16'd300);    // STATE with dmem words, length above 255
    run_frame(8'h85, 16'd17);

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
