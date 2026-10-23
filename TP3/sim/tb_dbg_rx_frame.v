`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for dbg_rx_frame (byte level, no UART).
// Spec (docs/protocol.md 3.1, 3.3, 3.4): frame SOF(A5) CMD LEN_lo LEN_hi
// PAYLOAD CHK; the 8-bit sum of CMD..CHK must be 0; bytes before SOF are
// ignored; an A5 inside a frame is data; a gap longer than TIMEOUT_CYCLES or
// a byte with a framing error drops the frame in progress (abort).
// The testbench records every output event and compares it, frame by frame,
// with the events the spec requires.

module tb_dbg_rx_frame;

  localparam integer CLK_PERIOD = 10;
  localparam integer TIMEOUT    = 50;
  localparam integer N_RANDOM   = 300;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg        rst = 1'b1;
  reg  [7:0] rx_data = 8'd0;
  reg        rx_valid = 1'b0, rx_ferr = 1'b0;
  wire       hdr_valid, pl_valid, frame_end, frame_ok, abort;
  wire [7:0] cmd, pl_byte;
  wire [15:0] len;

  dbg_rx_frame #(.TIMEOUT_CYCLES(TIMEOUT)) dut (
    .clk(clk), .rst(rst), .rx_data(rx_data), .rx_valid(rx_valid), .rx_ferr(rx_ferr),
    .hdr_valid(hdr_valid), .cmd(cmd), .len(len), .pl_valid(pl_valid), .pl_byte(pl_byte),
    .frame_end(frame_end), .frame_ok(frame_ok), .abort(abort)
  );

  // ---------------- event recorder ----------------
  integer n_hdr = 0, n_pl = 0, n_end = 0, n_abort = 0;
  reg [7:0]  last_cmd;
  reg [15:0] last_len;
  reg        last_ok;
  reg [7:0]  pl_seen [0:1023];

  always @(posedge clk) begin
    if (hdr_valid) begin n_hdr = n_hdr + 1; last_cmd = cmd; last_len = len; end
    if (pl_valid)  begin pl_seen[n_pl] = pl_byte; n_pl = n_pl + 1; end
    if (frame_end) begin n_end = n_end + 1; last_ok = frame_ok; end
    if (abort)     n_abort = n_abort + 1;
  end

  task clear_events;
    begin n_hdr = 0; n_pl = 0; n_end = 0; n_abort = 0; end
  endtask

  // ---------------- stimulus ----------------
  integer errors = 0, checks = 0;
  integer i, j, seed;
  reg     corrupt;

  task send;
    input [7:0] b;
    input       ferr;
    input integer gap;      // idle cycles after the byte
    begin
      @(negedge clk);
      rx_data = b; rx_valid = 1'b1; rx_ferr = ferr;
      @(negedge clk);
      rx_valid = 1'b0; rx_ferr = 1'b0;
      repeat (gap) @(negedge clk);
    end
  endtask

  reg [7:0]  fr_cmd;
  reg [15:0] fr_len;
  reg [7:0]  fr_pl [0:1023];
  reg [7:0]  fr_sum;

  task send_frame;
    input integer gap;
    input         corrupt;
    begin
      fr_sum = fr_cmd + fr_len[7:0] + fr_len[15:8];
      for (j = 0; j < fr_len; j = j + 1) fr_sum = fr_sum + fr_pl[j];
      send(8'hA5, 1'b0, gap);
      send(fr_cmd, 1'b0, gap);
      send(fr_len[7:0], 1'b0, gap);
      send(fr_len[15:8], 1'b0, gap);
      for (j = 0; j < fr_len; j = j + 1) send(fr_pl[j], 1'b0, gap);
      send((8'd0 - fr_sum) ^ (corrupt ? 8'h01 : 8'h00), 1'b0, gap);
      repeat (3) @(negedge clk);
    end
  endtask

  task expect_frame;
    input [8*14-1:0] tag;
    input            exp_ok;
    input            verbose;
    reg              good;
    begin
      checks = checks + 1;
      good = (n_hdr == 1 && last_cmd == fr_cmd && last_len == fr_len &&
              n_pl == fr_len && n_end == 1 && last_ok == exp_ok && n_abort == 0);
      for (j = 0; j < fr_len && j < n_pl; j = j + 1)
        if (pl_seen[j] !== fr_pl[j]) good = 1'b0;
      if (good) begin
        if (verbose)
          $display("PASS %0s: cmd=%02h len=%0d payload ok, frame_ok=%b", tag, fr_cmd, fr_len, last_ok);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: cmd=%02h len=%0d expected 1 hdr, %0d payload bytes, 1 end ok=%b, 0 aborts; got hdr=%0d (cmd=%02h len=%0d) pl=%0d end=%0d ok=%b aborts=%0d  TEST FAILED",
                 tag, fr_cmd, fr_len, fr_len, exp_ok, n_hdr, last_cmd, last_len, n_pl, n_end, last_ok, n_abort);
      end
      clear_events;
    end
  endtask

  task expect_counts;
    input [8*14-1:0] tag;
    input integer    e_hdr, e_pl, e_end, e_abort;
    begin
      checks = checks + 1;
      if (n_hdr == e_hdr && n_pl == e_pl && n_end == e_end && n_abort == e_abort) begin
        $display("PASS %0s: hdr=%0d pl=%0d end=%0d abort=%0d", tag, n_hdr, n_pl, n_end, n_abort);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: expected hdr=%0d pl=%0d end=%0d abort=%0d got %0d %0d %0d %0d  TEST FAILED",
                 tag, e_hdr, e_pl, e_end, e_abort, n_hdr, n_pl, n_end, n_abort);
      end
      clear_events;
    end
  endtask

  initial begin
    seed = 2026;
    repeat (3) @(negedge clk);
    rst = 1'b0;
    clear_events;

    // 1. DUMP (protocol.md 7: A5 05 00 00 FB)
    fr_cmd = 8'h05; fr_len = 0;
    send_frame(0, 1'b0); expect_frame("dump", 1'b1, 1'b1);

    // 2. LOAD example (A5 01 08 00 93 00 50 00 73 00 10 00 91)
    fr_cmd = 8'h01; fr_len = 8;
    fr_pl[0] = 8'h93; fr_pl[1] = 8'h00; fr_pl[2] = 8'h50; fr_pl[3] = 8'h00;
    fr_pl[4] = 8'h73; fr_pl[5] = 8'h00; fr_pl[6] = 8'h10; fr_pl[7] = 8'h00;
    send_frame(2, 1'b0); expect_frame("load_example", 1'b1, 1'b1);

    // 3. Bad checksum
    send_frame(0, 1'b1); expect_frame("bad_checksum", 1'b0, 1'b1);

    // 4. Garbage before SOF, and A5 / 5A inside the payload
    send(8'h00, 1'b0, 0); send(8'hFF, 1'b0, 0); send(8'h5A, 1'b0, 0);
    fr_cmd = 8'h03; fr_len = 3; fr_pl[0] = 8'hA5; fr_pl[1] = 8'h5A; fr_pl[2] = 8'hA5;
    send_frame(0, 1'b0); expect_frame("garbage+A5", 1'b1, 1'b1);

    // 5. Timeout in the middle of a frame, then a normal frame
    send(8'hA5, 1'b0, 0); send(8'h05, 1'b0, 0); send(8'h00, 1'b0, TIMEOUT + 5);
    expect_counts("timeout", 0, 0, 0, 1);
    fr_cmd = 8'h05; fr_len = 0;
    send_frame(0, 1'b0); expect_frame("after_timeout", 1'b1, 1'b1);

    // 6. A gap just under the timeout is fine
    fr_cmd = 8'h04; fr_len = 2; fr_pl[0] = 8'h11; fr_pl[1] = 8'h22;
    send_frame(TIMEOUT - 3, 1'b0); expect_frame("slow_ok", 1'b1, 1'b1);

    // 7. Framing error in the middle of a frame; in idle it is ignored
    // (outputs are registered: wait a few cycles before counting events)
    send(8'hA5, 1'b0, 0); send(8'h01, 1'b0, 0); send(8'h04, 1'b1, 3);
    expect_counts("ferr_in_frame", 0, 0, 0, 1);
    send(8'hA5, 1'b1, 3);
    expect_counts("ferr_idle", 0, 0, 0, 0);
    fr_cmd = 8'h02; fr_len = 0;
    send_frame(0, 1'b0); expect_frame("after_ferr", 1'b1, 1'b1);

    // 8. Random frames: random command, length, payload, gaps, corruption
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      fr_cmd = $random(seed);
      fr_len = $unsigned($random(seed)) % 40;
      for (j = 0; j < fr_len; j = j + 1) fr_pl[j] = $random(seed);
      corrupt = ($random(seed) % 4) == 0;
      send_frame($unsigned($random(seed)) % 4, corrupt);
      expect_frame("random", !corrupt, 1'b0);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
