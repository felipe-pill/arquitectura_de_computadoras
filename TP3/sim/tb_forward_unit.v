`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for forward_unit.
// Spec (docs/arquitectura.md 3.1), per operand rsX:
//   10 if EX/MEM writes rsX (reg_write, rd != 0, not a load)
//   else 01 if MEM/WB writes rsX (reg_write, rd != 0)
//   else 00.
// Directed cases with hand-written expected values, then random inputs
// (registers drawn from a small set so matches are frequent) against a model.

module tb_forward_unit;

  localparam integer N_RANDOM = 20000;

  reg  [4:0] rs1 = 0, rs2 = 0, mem_rd = 0, wb_rd = 0;
  reg        mem_rw = 0, mem_ld = 0, wb_rw = 0;
  wire [1:0] fwd_a, fwd_b;

  forward_unit dut (
    .id_ex_rs1(rs1), .id_ex_rs2(rs2),
    .ex_mem_rd(mem_rd), .ex_mem_reg_write(mem_rw), .ex_mem_mem_read(mem_ld),
    .mem_wb_rd(wb_rd), .mem_wb_reg_write(wb_rw),
    .fwd_a(fwd_a), .fwd_b(fwd_b)
  );

  integer errors = 0;
  integer checks = 0;
  integer i, seed;

  function [1:0] model;
    input [4:0] rs;
    begin
      if (mem_rw && !mem_ld && mem_rd != 0 && mem_rd == rs)
        model = 2'b10;
      else if (wb_rw && wb_rd != 0 && wb_rd == rs)
        model = 2'b01;
      else
        model = 2'b00;
    end
  endfunction

  task check;
    input [8*12-1:0] tag;
    input [1:0]      exp_a, exp_b;
    input            verbose;
    begin
      #1;
      checks = checks + 1;
      if (fwd_a === exp_a && fwd_b === exp_b) begin
        if (verbose)
          $display("PASS %0s: rs1=%0d rs2=%0d mem(rd=%0d rw=%b ld=%b) wb(rd=%0d rw=%b) -> a=%b b=%b",
                   tag, rs1, rs2, mem_rd, mem_rw, mem_ld, wb_rd, wb_rw, fwd_a, fwd_b);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: rs1=%0d rs2=%0d mem(rd=%0d rw=%b ld=%b) wb(rd=%0d rw=%b) expected a=%b b=%b got a=%b b=%b  TEST FAILED",
                 tag, rs1, rs2, mem_rd, mem_rw, mem_ld, wb_rd, wb_rw, exp_a, exp_b, fwd_a, fwd_b);
      end
    end
  endtask

  initial begin
    // Directed
    rs1 = 3; rs2 = 4; mem_rd = 3; mem_rw = 1; mem_ld = 0; wb_rd = 4; wb_rw = 1;
    check("mem_a_wb_b", 2'b10, 2'b01, 1'b1);
    wb_rd = 3;
    check("newest_wins", 2'b10, 2'b00, 1'b1);       // both write x3: EX/MEM
    mem_ld = 1;
    check("load_no_fwd", 2'b01, 2'b00, 1'b1);       // load in MEM: use MEM/WB
    mem_ld = 0; mem_rw = 0;
    check("mem_no_write", 2'b01, 2'b00, 1'b1);
    rs1 = 0; rs2 = 0; mem_rd = 0; mem_rw = 1; wb_rd = 0; wb_rw = 1;
    check("x0_never", 2'b00, 2'b00, 1'b1);
    rs1 = 7; rs2 = 7; mem_rd = 7; mem_rw = 1; mem_ld = 0; wb_rd = 1; wb_rw = 0;
    check("both_ops", 2'b10, 2'b10, 1'b1);
    mem_rw = 0; wb_rd = 7; wb_rw = 0;
    check("none", 2'b00, 2'b00, 1'b1);

    // Random
    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      rs1    = $random(seed) % 4;
      rs2    = $random(seed) % 4;
      mem_rd = $random(seed) % 4;
      wb_rd  = $random(seed) % 4;
      if ($random(seed) % 8 == 0) rs1 = $random(seed);
      mem_rw = $random(seed);
      mem_ld = $random(seed);
      wb_rw  = $random(seed);
      check("random", model(rs1), model(rs2), 1'b0);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
