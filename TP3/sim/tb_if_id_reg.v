`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for if_id_reg.
// Spec: on the rising edge, rst -> bubble (pc 0, instr NOP, stop 0,
// valid 0); else if en: flush -> bubble, else if !hold -> load inputs with
// valid = 1, else keep. With en = 0 nothing changes. Random stimulus against
// a model, after a directed sequence.

module tb_if_id_reg;

  localparam integer CLK_PERIOD = 10;
  localparam integer N_RANDOM   = 20000;
  localparam [31:0]  NOP        = 32'h00000013;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg         rst = 1, en = 0, flush = 0, hold = 0;
  reg  [31:0] in_pc = 0, in_instr = 0;
  reg  [2:0]  in_stop = 0;
  wire [31:0] pc, instr;
  wire [2:0]  stop_code;
  wire        valid;

  if_id_reg dut (
    .clk(clk), .rst(rst), .en(en), .flush(flush), .hold(hold),
    .in_pc(in_pc), .in_instr(in_instr), .in_stop_code(in_stop),
    .pc(pc), .instr(instr), .stop_code(stop_code), .valid(valid)
  );

  integer errors = 0;
  integer checks = 0;
  integer i, seed;
  reg [31:0] m_pc = 0, m_instr = NOP;
  reg [2:0]  m_stop = 0;
  reg        m_valid = 0;

  task step;
    input [8*10-1:0] tag;
    input            verbose;
    begin
      @(posedge clk);
      if (rst || (en && flush)) begin
        m_pc = 0; m_instr = NOP; m_stop = 0; m_valid = 0;
      end else if (en && !hold) begin
        m_pc = in_pc; m_instr = in_instr; m_stop = in_stop; m_valid = 1;
      end
      @(negedge clk);
      checks = checks + 1;
      if (pc === m_pc && instr === m_instr && stop_code === m_stop && valid === m_valid) begin
        if (verbose)
          $display("PASS %0s: rst=%b en=%b flush=%b hold=%b -> pc=%08h instr=%08h stop=%0d valid=%b",
                   tag, rst, en, flush, hold, pc, instr, stop_code, valid);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: rst=%b en=%b flush=%b hold=%b expected %08h %08h %0d %b got %08h %08h %0d %b  TEST FAILED",
                 tag, rst, en, flush, hold, m_pc, m_instr, m_stop, m_valid, pc, instr, stop_code, valid);
      end
    end
  endtask

  initial begin
    @(negedge clk);
    rst = 1; step("reset", 1'b1);
    rst = 0; en = 1; in_pc = 32'h10; in_instr = 32'h00500093; in_stop = 3; step("load", 1'b1);
    in_pc = 32'h14; hold = 1; step("hold", 1'b1);
    flush = 1; step("flush", 1'b1);                 // flush beats hold
    flush = 0; hold = 0; en = 0; step("en0", 1'b1);
    en = 1; step("load2", 1'b1);

    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      rst = ($random(seed) % 32) == 0;
      en = ($random(seed) % 4) != 0;
      flush = ($random(seed) % 4) == 0;
      hold = ($random(seed) % 4) == 0;
      in_pc = $random(seed); in_instr = $random(seed); in_stop = $random(seed);
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
