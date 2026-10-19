`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for halt_ctrl.
// Spec (docs/arquitectura.md 5, 6.1):
// - rst clears halting, halted, halt_reason and cycle_cnt;
// - each enabled edge increments cycle_cnt; with en = 0 nothing changes;
// - halt_accept sets halting and latches halt_reason_in;
// - wb_halt sets halted and clears halting;
// - timeout = cycle_cnt >= MAX_CYCLES (combinational).
// Directed sequence, then random inputs against a model. MAX_CYCLES = 20.

module tb_halt_ctrl;

  localparam integer CLK_PERIOD = 10;
  localparam integer MAX_CYCLES = 20;
  localparam integer N_RANDOM   = 20000;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg        rst = 1, en = 0, halt_accept = 0, wb_halt = 0;
  reg  [2:0] reason_in = 0;
  wire       halting, halted, timeout;
  wire [2:0] halt_reason;
  wire [31:0] cycle_cnt;

  halt_ctrl #(.MAX_CYCLES(MAX_CYCLES)) dut (
    .clk(clk), .rst(rst), .en(en), .halt_accept(halt_accept),
    .halt_reason_in(reason_in), .wb_halt(wb_halt),
    .halting(halting), .halted(halted), .halt_reason(halt_reason),
    .cycle_cnt(cycle_cnt), .timeout(timeout)
  );

  integer errors = 0;
  integer checks = 0;
  integer i, seed;
  reg        m_halting = 0, m_halted = 0;
  reg [2:0]  m_reason = 0;
  reg [31:0] m_cnt = 0;

  task compare;
    input [8*10-1:0] tag;
    input            verbose;
    begin
      checks = checks + 1;
      if (halting === m_halting && halted === m_halted && halt_reason === m_reason &&
          cycle_cnt === m_cnt && timeout === (m_cnt >= MAX_CYCLES)) begin
        if (verbose)
          $display("PASS %0s: halting=%b halted=%b reason=%0d cycles=%0d timeout=%b",
                   tag, halting, halted, halt_reason, cycle_cnt, timeout);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: expected halting=%b halted=%b reason=%0d cycles=%0d timeout=%b got %b %b %0d %0d %b  TEST FAILED",
                 tag, m_halting, m_halted, m_reason, m_cnt, m_cnt >= MAX_CYCLES,
                 halting, halted, halt_reason, cycle_cnt, timeout);
      end
    end
  endtask

  // Apply the current inputs for one edge, update the model, compare
  task step;
    input [8*10-1:0] tag;
    input            verbose;
    begin
      @(posedge clk);
      if (rst) begin
        m_halting = 0; m_halted = 0; m_reason = 0; m_cnt = 0;
      end else if (en) begin
        m_cnt = m_cnt + 1;
        if (halt_accept) begin m_halting = 1; m_reason = reason_in; end
        if (wb_halt)     begin m_halting = 0; m_halted = 1; end
      end
      @(negedge clk);
      compare(tag, verbose);
    end
  endtask

  initial begin
    // Directed
    @(negedge clk);
    rst = 1; step("reset", 1'b1);
    rst = 0; en = 1;
    step("count1", 1'b1);
    en = 0; step("en0", 1'b1);
    en = 1; halt_accept = 1; reason_in = 3'd2; step("accept", 1'b1);
    halt_accept = 0; reason_in = 3'd5; step("draining", 1'b1);  // reason stays 2
    wb_halt = 1; step("halted", 1'b1);
    wb_halt = 0;
    for (i = 0; i < 20; i = i + 1) step("to_limit", i == 19);    // timeout at 20

    // Random
    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      rst         = ($random(seed) % 40) == 0;
      en          = ($random(seed) % 4) != 0;
      halt_accept = ($random(seed) % 10) == 0;
      wb_halt     = ($random(seed) % 10) == 0;
      reason_in   = $random(seed);
      step("random", 1'b0);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
