`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for hazard_unit.
// Spec (docs/arquitectura.md 3.2): load_use = 1 when IF/ID holds a valid
// instruction, ID/EX holds a load with rd != 0, and that rd equals the
// instruction's effective rs1 or rs2.

module tb_hazard_unit;

  localparam integer N_RANDOM = 20000;

  reg  valid = 0, ld = 0;
  reg  [4:0] rs1 = 0, rs2 = 0, rd = 0;
  wire load_use;

  hazard_unit dut (
    .if_id_valid(valid), .id_rs1(rs1), .id_rs2(rs2),
    .id_ex_mem_read(ld), .id_ex_rd(rd), .load_use(load_use)
  );

  integer errors = 0;
  integer checks = 0;
  integer i, seed;

  task check;
    input [8*12-1:0] tag;
    input            expected;
    input            verbose;
    begin
      #1;
      checks = checks + 1;
      if (load_use === expected) begin
        if (verbose)
          $display("PASS %0s: valid=%b rs1=%0d rs2=%0d load=%b rd=%0d -> %b",
                   tag, valid, rs1, rs2, ld, rd, load_use);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: valid=%b rs1=%0d rs2=%0d load=%b rd=%0d expected=%b got=%b  TEST FAILED",
                 tag, valid, rs1, rs2, ld, rd, expected, load_use);
      end
    end
  endtask

  initial begin
    // Directed
    valid = 1; ld = 1; rd = 5; rs1 = 5; rs2 = 0;  check("rs1", 1'b1, 1'b1);
    rs1 = 0; rs2 = 5;                              check("rs2", 1'b1, 1'b1);
    rs2 = 6;                                       check("no_match", 1'b0, 1'b1);
    rs1 = 5; ld = 0;                               check("not_load", 1'b0, 1'b1);
    ld = 1; rd = 0; rs1 = 0; rs2 = 0;              check("rd_x0", 1'b0, 1'b1);
    rd = 5; rs1 = 5; valid = 0;                    check("bubble", 1'b0, 1'b1);

    // Random (small register set so matches are frequent)
    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      valid = $random(seed);
      ld    = $random(seed);
      rd    = $random(seed) % 4;
      rs1   = $random(seed) % 4;
      rs2   = $random(seed) % 4;
      check("random", valid && ld && rd != 0 && (rd == rs1 || rd == rs2), 1'b0);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
