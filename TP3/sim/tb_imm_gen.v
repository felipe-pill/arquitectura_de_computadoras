`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for imm_gen.
// Spec: RV32I immediate formats I, S, B, U, J (imm_sel 0..4); other
// imm_sel values give 0.
// 1. Directed vectors: known instructions with hand-computed immediates.
// 2. isa_vectors.hex (TP3/py/gen_vectors.py): each instruction word with the
//    imm_sel the decoder should pick and the immediate computed in Python
//    from the spec bit layout (layout described in tb_decoder.v).
// 3. Every vector word again with all five formats, checked against a
//    model of the spec bit layouts.

module tb_imm_gen;

  localparam integer MAX_VEC = 4096;
  localparam integer MIN_VEC = 1000;

  localparam [2:0] IMM_I = 3'd0;
  localparam [2:0] IMM_S = 3'd1;
  localparam [2:0] IMM_B = 3'd2;
  localparam [2:0] IMM_U = 3'd3;
  localparam [2:0] IMM_J = 3'd4;

  reg [127:0] vec [0:MAX_VEC-1];

  reg  [31:0] instr = 32'd0;
  reg  [2:0]  imm_sel = IMM_I;
  wire [31:0] imm;

  imm_gen dut (.instr(instr), .imm_sel(imm_sel), .imm(imm));

  integer errors = 0;
  integer checks = 0;
  integer n, i, s;

  // Spec bit layouts
  function [31:0] model;
    input [31:0] w;
    input [2:0]  sel;
    begin
      case (sel)
        IMM_I:   model = {{20{w[31]}}, w[31:20]};
        IMM_S:   model = {{20{w[31]}}, w[31:25], w[11:7]};
        IMM_B:   model = {{20{w[31]}}, w[7], w[30:25], w[11:8], 1'b0};
        IMM_U:   model = {w[31:12], 12'd0};
        IMM_J:   model = {{12{w[31]}}, w[19:12], w[20], w[30:21], 1'b0};
        default: model = 32'd0;
      endcase
    end
  endfunction

  task check;
    input [8*10-1:0] tag;
    input [31:0]     t_instr;
    input [2:0]      t_sel;
    input [31:0]     expected;
    input            verbose;
    begin
      instr = t_instr; imm_sel = t_sel;
      #1;
      checks = checks + 1;
      if (imm === expected) begin
        if (verbose)
          $display("PASS %0s: instr=%08h sel=%0d -> imm=%08h", tag, t_instr, t_sel, imm);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: instr=%08h sel=%0d expected=%08h got=%08h  TEST FAILED",
                 tag, t_instr, t_sel, expected, imm);
      end
    end
  endtask

  initial begin
    // 1. Directed (encodings from the RV32I tables, immediates by hand)
    check("addi",   32'hFF010113, IMM_I, 32'hFFFFFFF0, 1'b1);  // addi sp, sp, -16
    check("lw",     32'h00C12083, IMM_I, 32'h0000000C, 1'b1);  // lw ra, 12(sp)
    check("srai",   32'h4010D093, IMM_I, 32'h00000401, 1'b1);  // srai x1, x1, 1
    check("sw",     32'h00112623, IMM_S, 32'h0000000C, 1'b1);  // sw ra, 12(sp)
    check("sw-1",   32'hFE20AFA3, IMM_S, 32'hFFFFFFFF, 1'b1);  // sw x2, -1(x1)
    check("beq8",   32'h00208463, IMM_B, 32'h00000008, 1'b1);  // beq x1, x2, 8
    check("bne-4",  32'hFE209EE3, IMM_B, 32'hFFFFFFFC, 1'b1);  // bne x1, x2, -4
    check("beqmax", 32'h7E000FE3, IMM_B, 32'h00000FFE, 1'b1);  // beq x0, x0, 4094
    check("lui",    32'h12345537, IMM_U, 32'h12345000, 1'b1);  // lui a0, 0x12345
    check("jal-4",  32'hFFDFF06F, IMM_J, 32'hFFFFFFFC, 1'b1);  // jal x0, -4
    check("jalmax", 32'h7FFFF06F, IMM_J, 32'h000FFFFE, 1'b1);  // jal x0, 1048574
    check("sel5",   32'hFFFFFFFF, 3'd5,  32'h00000000, 1'b1);
    check("sel6",   32'hFFFFFFFF, 3'd6,  32'h00000000, 1'b1);
    check("sel7",   32'hFFFFFFFF, 3'd7,  32'h00000000, 1'b1);

    // 2. Python-generated vectors
    $readmemh("isa_vectors.hex", vec);
    n = 0;
    while (n < MAX_VEC && ^vec[n] !== 1'bx)
      n = n + 1;
    if (n < MIN_VEC) begin
      $display("FAIL: only %0d vectors loaded from isa_vectors.hex  TEST FAILED", n);
      errors = errors + 1;
    end
    for (i = 0; i < n; i = i + 1)
      check("vector", vec[i][63:32], vec[i][96:94], vec[i][31:0], 1'b0);  // imm_sel = ctrl[32:30]

    // 3. Every format on every vector word
    for (i = 0; i < n; i = i + 1)
      for (s = 0; s < 8; s = s + 1)
        check("allfmt", vec[i][63:32], s[2:0], model(vec[i][63:32], s[2:0]), 1'b0);

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
