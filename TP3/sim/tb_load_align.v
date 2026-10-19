`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for load_align.
// Spec (RV32I + docs/arquitectura.md 2.3), rdata = whole memory word:
//   lb  (000): byte addr[1:0], sign-extended     lbu (100): zero-extended
//   lh  (001): half addr[1] (addr[0] ignored), sign-extended
//   lhu (101): same half, zero-extended          lw  (010): whole word
// Only these five funct3 values are defined (the decoder never sends others).

module tb_load_align;

  localparam integer N_RANDOM = 500;

  reg  [2:0]  funct3 = 3'b010;
  reg  [1:0]  addr_lo = 2'd0;
  reg  [31:0] rdata = 32'd0;
  wire [31:0] data;

  load_align dut (.funct3(funct3), .addr_lo(addr_lo), .rdata(rdata), .data(data));

  integer errors = 0;
  integer checks = 0;
  integer i, f, a, seed;
  reg [2:0] f3s [0:4];

  // Reference model: pick bytes by position
  function [31:0] model;
    input [2:0]  f3;
    input [1:0]  lo;
    input [31:0] w;
    reg   [7:0]  bt;
    reg   [15:0] hf;
    begin
      case (lo)
        2'd0: bt = w[7:0];
        2'd1: bt = w[15:8];
        2'd2: bt = w[23:16];
        default: bt = w[31:24];
      endcase
      hf = lo[1] ? w[31:16] : w[15:0];
      case (f3)
        3'b000:  model = bt[7]  ? {24'hFFFFFF, bt} : {24'h000000, bt};
        3'b100:  model = {24'h000000, bt};
        3'b001:  model = hf[15] ? {16'hFFFF, hf} : {16'h0000, hf};
        3'b101:  model = {16'h0000, hf};
        default: model = w;
      endcase
    end
  endfunction

  task check;
    input [8*8-1:0] tag;
    input [2:0]     t_f3;
    input [1:0]     t_lo;
    input [31:0]    t_rdata, expected;
    input           verbose;
    begin
      funct3 = t_f3; addr_lo = t_lo; rdata = t_rdata;
      #1;
      checks = checks + 1;
      if (data === expected) begin
        if (verbose)
          $display("PASS %0s: funct3=%b addr_lo=%0d rdata=%08h -> %08h",
                   tag, t_f3, t_lo, t_rdata, data);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: funct3=%b addr_lo=%0d rdata=%08h expected=%08h got=%08h  TEST FAILED",
                 tag, t_f3, t_lo, t_rdata, expected, data);
      end
    end
  endtask

  initial begin
    // Directed, word 0x89ABCDEF (same values as asm/loadstore.s)
    check("lb0",  3'b000, 2'd0, 32'h89ABCDEF, 32'hFFFFFFEF, 1'b1);
    check("lbu1", 3'b100, 2'd1, 32'h89ABCDEF, 32'h000000CD, 1'b1);
    check("lb2",  3'b000, 2'd2, 32'h89ABCDEF, 32'hFFFFFFAB, 1'b1);
    check("lb3",  3'b000, 2'd3, 32'h89ABCDEF, 32'hFFFFFF89, 1'b1);
    check("lb_p", 3'b000, 2'd0, 32'h0000007F, 32'h0000007F, 1'b1);
    check("lh0",  3'b001, 2'd0, 32'h89ABCDEF, 32'hFFFFCDEF, 1'b1);
    check("lh2",  3'b001, 2'd2, 32'h89ABCDEF, 32'hFFFF89AB, 1'b1);
    check("lh3",  3'b001, 2'd3, 32'h89ABCDEF, 32'hFFFF89AB, 1'b1);  // addr[0] ignored
    check("lh_p", 3'b001, 2'd0, 32'h00007FFF, 32'h00007FFF, 1'b1);
    check("lhu0", 3'b101, 2'd0, 32'h89ABCDEF, 32'h0000CDEF, 1'b1);
    check("lhu2", 3'b101, 2'd2, 32'h89ABCDEF, 32'h000089AB, 1'b1);
    check("lw0",  3'b010, 2'd0, 32'h89ABCDEF, 32'h89ABCDEF, 1'b1);
    check("lw3",  3'b010, 2'd3, 32'h89ABCDEF, 32'h89ABCDEF, 1'b1);  // addr[1:0] ignored

    // Exhaustive over the defined funct3 and every addr_lo, random words
    f3s[0] = 3'b000; f3s[1] = 3'b001; f3s[2] = 3'b010; f3s[3] = 3'b100; f3s[4] = 3'b101;
    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      rdata = $random(seed);
      for (f = 0; f < 5; f = f + 1)
        for (a = 0; a < 4; a = a + 1)
          check("random", f3s[f], a[1:0], rdata, model(f3s[f], a[1:0], rdata), 1'b0);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
