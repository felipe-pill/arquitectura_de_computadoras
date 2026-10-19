`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for branch_unit.
// Spec (RV32I, docs/arquitectura.md 3.3):
//   beq taken if rs1 == rs2, bne taken if rs1 != rs2; target = pc + imm
//   jalr always redirects;                              target = alu_y & ~1
//   no redirect for a bubble (valid = 0) or a non-branch.
// target only matters when redirect = 1.

module tb_branch_unit;

  localparam integer N_RANDOM = 20000;

  reg         valid = 0, branch = 0, jalr = 0, is_bne = 0;
  reg  [31:0] rs1 = 0, rs2 = 0, pc = 0, imm = 0, alu_y = 0;
  wire        redirect;
  wire [31:0] target;

  branch_unit dut (
    .valid(valid), .branch(branch), .jalr(jalr), .is_bne(is_bne),
    .rs1_val(rs1), .rs2_val(rs2), .pc(pc), .imm(imm), .alu_y(alu_y),
    .redirect(redirect), .target(target)
  );

  integer errors = 0;
  integer checks = 0;
  integer i, seed;
  reg exp_r;
  reg [31:0] exp_t;

  task check;
    input [8*10-1:0] tag;
    input            e_redirect;
    input [31:0]     e_target;
    input            verbose;
    begin
      #1;
      checks = checks + 1;
      if (redirect === e_redirect && (!e_redirect || target === e_target)) begin
        if (verbose)
          $display("PASS %0s: br=%b jalr=%b bne=%b rs1=%08h rs2=%08h pc=%08h imm=%08h alu=%08h -> redirect=%b target=%08h",
                   tag, branch, jalr, is_bne, rs1, rs2, pc, imm, alu_y, redirect, target);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: br=%b jalr=%b bne=%b rs1=%08h rs2=%08h pc=%08h imm=%08h alu=%08h expected %b/%08h got %b/%08h  TEST FAILED",
                 tag, branch, jalr, is_bne, rs1, rs2, pc, imm, alu_y, e_redirect, e_target, redirect, target);
      end
    end
  endtask

  initial begin
    // Directed
    valid = 1; pc = 32'h100; imm = 32'hFFFFFFF8; alu_y = 32'h0000002D;
    branch = 1; is_bne = 0; rs1 = 5; rs2 = 5;  check("beq_t",  1'b1, 32'h000000F8, 1'b1);
    rs2 = 6;                                    check("beq_nt", 1'b0, 32'h0, 1'b1);
    is_bne = 1;                                 check("bne_t",  1'b1, 32'h000000F8, 1'b1);
    rs2 = 5;                                    check("bne_nt", 1'b0, 32'h0, 1'b1);
    branch = 0; jalr = 1;                       check("jalr",   1'b1, 32'h0000002C, 1'b1);
    valid = 0;                                  check("bubble", 1'b0, 32'h0, 1'b1);
    valid = 1; jalr = 0;                        check("none",   1'b0, 32'h0, 1'b1);

    // Random
    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      valid  = ($random(seed) % 8) != 0;
      branch = $random(seed);
      jalr   = branch ? 1'b0 : $random(seed);
      is_bne = $random(seed);
      rs1    = $random(seed);
      rs2    = ($random(seed) % 2) ? rs1 : $random(seed);
      pc     = $random(seed);
      imm    = $random(seed);
      alu_y  = $random(seed);
      exp_r  = valid && (jalr || (branch && ((rs1 == rs2) != is_bne)));
      exp_t  = jalr ? (alu_y & 32'hFFFFFFFE) : (pc + imm);
      check("random", exp_r, exp_t, 1'b0);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
