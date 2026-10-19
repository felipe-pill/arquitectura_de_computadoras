`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for dmem.
// Spec (docs/arquitectura.md 4.2, 4.3):
// - contents start at 0;
// - port A, on the rising edge when a_en = 1: writes the bytes selected by
//   a_we and registers a_rdata = mem[a_addr] read-first (the old word when
//   the same word is written in that cycle);
// - a_en = 0: nothing is written (even with a_we != 0) and a_rdata holds;
// - port B: read-only, b_rdata = mem[b_addr] one edge later, independent of
//   port A (it never changes a_rdata).
// Uses ADDR_W = 4 so every address is exercised. A reference array models
// the expected contents.

module tb_dmem;

  localparam integer CLK_PERIOD = 10;
  localparam integer ADDR_W     = 4;
  localparam integer DEPTH      = 1 << ADDR_W;
  localparam integer N_RANDOM   = 3000;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg              a_en = 1'b0;
  reg [3:0]        a_we = 4'b0000;
  reg [ADDR_W-1:0] a_addr = 0, b_addr = 0;
  reg [31:0]       a_wdata = 32'd0;
  wire [31:0]      a_rdata, b_rdata;

  dmem #(.ADDR_W(ADDR_W)) dut (
    .clk(clk), .a_en(a_en), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
    .a_rdata(a_rdata), .b_addr(b_addr), .b_rdata(b_rdata)
  );

  reg [31:0] model [0:DEPTH-1];
  reg [31:0] exp_a, exp_b;
  integer errors = 0;
  integer checks = 0;
  integer i, seed;

  task expect32;
    input [8*10-1:0] tag;
    input [31:0]     got, exp;
    input            verbose;
    begin
      checks = checks + 1;
      if (got === exp) begin
        if (verbose)
          $display("PASS %0s: a(en=%b we=%b addr=%0d wdata=%08h) b_addr=%0d -> %08h",
                   tag, a_en, a_we, a_addr, a_wdata, b_addr, got);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: a(en=%b we=%b addr=%0d wdata=%08h) b_addr=%0d expected=%08h got=%08h  TEST FAILED",
                 tag, a_en, a_we, a_addr, a_wdata, b_addr, exp, got);
      end
    end
  endtask

  // Merge the enabled bytes of wdata into word
  function [31:0] merge;
    input [31:0] word, wdata;
    input [3:0]  we;
    begin
      merge = word;
      if (we[0]) merge[7:0]   = wdata[7:0];
      if (we[1]) merge[15:8]  = wdata[15:8];
      if (we[2]) merge[23:16] = wdata[23:16];
      if (we[3]) merge[31:24] = wdata[31:24];
    end
  endfunction

  // Apply the current inputs for one edge: compute the expected outputs
  // from the model, update the model, check after the edge.
  task cycle;
    input [8*10-1:0] tag;
    input            verbose;
    begin
      if (a_en) exp_a = model[a_addr];
      exp_b = model[b_addr];
      @(posedge clk);
      if (a_en) model[a_addr] = merge(model[a_addr], a_wdata, a_we);
      @(negedge clk);
      expect32({tag, "_a"}, a_rdata, exp_a, verbose);
      expect32({tag, "_b"}, b_rdata, exp_b, verbose);
    end
  endtask

  initial begin
    for (i = 0; i < DEPTH; i = i + 1) model[i] = 32'd0;
    exp_a = 32'd0;
    seed = 2026;
    @(negedge clk);

    // 1. Contents start at 0 (port A and port B)
    a_en = 1'b1; a_we = 4'b0000;
    for (i = 0; i < DEPTH; i = i + 1) begin
      a_addr = i; b_addr = DEPTH - 1 - i;
      cycle("zero", i == 0);
    end

    // 2. Full-word writes, read back on both ports
    for (i = 0; i < DEPTH; i = i + 1) begin
      a_we = 4'b1111; a_addr = i; a_wdata = 32'h89ABCDEF ^ (i * 32'h01010101);
      b_addr = (i + 1) % DEPTH;
      cycle("write", i == 0);
    end
    a_we = 4'b0000;
    for (i = 0; i < DEPTH; i = i + 1) begin
      a_addr = i; b_addr = i;
      cycle("readback", i == 0);
    end

    // 3. Byte enables: each lane alone, then two lanes
    a_addr = 2; a_we = 4'b1111; a_wdata = 32'h00000000; cycle("clear", 1'b0);
    a_we = 4'b0001; a_wdata = 32'h111111AA; cycle("lane0", 1'b0);
    a_we = 4'b0010; a_wdata = 32'h2222BB22; cycle("lane1", 1'b0);
    a_we = 4'b0100; a_wdata = 32'h33CC3333; cycle("lane2", 1'b0);
    a_we = 4'b1000; a_wdata = 32'hDD444444; cycle("lane3", 1'b0);
    a_we = 4'b0000; b_addr = 2; cycle("lanes", 1'b1);
    expect32("lanes_val", a_rdata, 32'hDDCCBBAA, 1'b1);
    a_we = 4'b1100; a_wdata = 32'h12345678; cycle("half_hi", 1'b0);
    a_we = 4'b0000; cycle("half_rd", 1'b0);
    expect32("half_val", a_rdata, 32'h1234BBAA, 1'b1);

    // 4. Read-first: write and read the same word in one edge
    a_addr = 7; a_we = 4'b1111; a_wdata = 32'h00000007; cycle("rf_prep", 1'b0);
    a_wdata = 32'h77777777; cycle("rf_write", 1'b0);
    expect32("read_first", a_rdata, 32'h00000007, 1'b1);  // old word
    a_we = 4'b0000; cycle("rf_after", 1'b0);
    expect32("rf_new", a_rdata, 32'h77777777, 1'b1);

    // 5. a_en = 0: no write and a_rdata holds, even if a_addr changes
    a_en = 1'b0; a_addr = 9; a_we = 4'b1111; a_wdata = 32'hFFFFFFFF; b_addr = 9;
    cycle("en0", 1'b0);
    expect32("en0_hold", a_rdata, 32'h77777777, 1'b1);
    a_en = 1'b1; a_we = 4'b0000; cycle("en0_chk", 1'b0);
    expect32("en0_nowr", a_rdata, model[9], 1'b1);

    // 6. Port B does not disturb a_rdata
    a_en = 1'b0;
    for (i = 0; i < 4; i = i + 1) begin
      b_addr = i; cycle("b_only", 1'b0);
      expect32("a_steady", a_rdata, model[9], i == 3);
    end

    // 7. Random traffic (port B never reads the word port A writes in the
    //    same edge: a cross-port collision is undefined in a real BRAM and
    //    the design never does it)
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      a_en    = ($random(seed) % 8) != 0;
      a_we    = $random(seed);
      a_addr  = $random(seed);
      a_wdata = $random(seed);
      b_addr  = $random(seed);
      if (a_en && a_we != 4'b0000 && b_addr == a_addr) b_addr = b_addr + 1;
      cycle("random", 1'b0);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
