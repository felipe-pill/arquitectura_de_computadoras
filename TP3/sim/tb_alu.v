`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for alu.
// Spec (RV32I, docs/arquitectura.md 2.4): op = {alt, funct3};
// add/sub wrap modulo 2^32; slt signed, sltu unsigned compare (result 0/1);
// sll/srl/sra shift by b[4:0], sra fills with a[31]; xor/or/and bitwise;
// any other op gives 0.
// Directed vectors have hand-computed expected values; random vectors are
// checked against a reference model written from the spec.

module tb_alu;

  localparam integer N_RANDOM = 2000;  // random vectors per op

  localparam [3:0] ALU_ADD  = 4'b0000;
  localparam [3:0] ALU_SUB  = 4'b1000;
  localparam [3:0] ALU_SLL  = 4'b0001;
  localparam [3:0] ALU_SLT  = 4'b0010;
  localparam [3:0] ALU_SLTU = 4'b0011;
  localparam [3:0] ALU_XOR  = 4'b0100;
  localparam [3:0] ALU_SRL  = 4'b0101;
  localparam [3:0] ALU_SRA  = 4'b1101;
  localparam [3:0] ALU_OR   = 4'b0110;
  localparam [3:0] ALU_AND  = 4'b0111;

  reg  [31:0] a = 32'd0, b = 32'd0;
  reg  [3:0]  op = ALU_ADD;
  wire [31:0] y;

  alu dut (.a(a), .b(b), .op(op), .y(y));

  integer errors = 0;
  integer checks = 0;

  // ---------------- Reference model ----------------
  function [31:0] model;
    input [3:0]  f_op;
    input [31:0] x, z;
    reg   [4:0]  sh;
    begin
      sh = z[4:0];
      case (f_op)
        ALU_ADD:  model = x + z;
        ALU_SUB:  model = x + ~z + 32'd1;
        ALU_SLL:  model = x * (33'd1 << sh);
        ALU_SLT:  model = (x[31] != z[31]) ? {31'd0, x[31]} : {31'd0, x < z};
        ALU_SLTU: model = {31'd0, x < z};
        ALU_XOR:  model = x ^ z;
        ALU_SRL:  model = x / (33'd1 << sh);
        ALU_SRA:  model = (x / (33'd1 << sh)) | (x[31] ? ~(32'hFFFFFFFF >> sh) : 32'd0);
        ALU_OR:   model = x | z;
        ALU_AND:  model = x & z;
        default:  model = 32'd0;
      endcase
    end
  endfunction

  task check;
    input [8*8-1:0] tag;
    input [3:0]     t_op;
    input [31:0]    t_a, t_b, expected;
    begin
      op = t_op; a = t_a; b = t_b;
      #1;
      checks = checks + 1;
      if (y === expected) begin
        if (tag != "random")
          $display("PASS %0s: op=%b a=%08h b=%08h -> y=%08h", tag, t_op, t_a, t_b, y);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: op=%b a=%08h b=%08h expected=%08h got=%08h  TEST FAILED",
                 tag, t_op, t_a, t_b, expected, y);
      end
    end
  endtask

  integer i, k, seed;
  reg [3:0] ops [0:9];

  initial begin
    // Directed vectors (expected values computed by hand)
    check("add",    ALU_ADD,  32'h00000007, 32'hFFFFFFFD, 32'h00000004);
    check("addwrap",ALU_ADD,  32'h7FFFFFFF, 32'h00000001, 32'h80000000);
    check("addcarr",ALU_ADD,  32'hFFFFFFFF, 32'h00000001, 32'h00000000);
    check("sub",    ALU_SUB,  32'h00000007, 32'hFFFFFFFD, 32'h0000000A);
    check("subneg", ALU_SUB,  32'h00000000, 32'h00000001, 32'hFFFFFFFF);
    check("sll",    ALU_SLL,  32'h00000007, 32'h00000004, 32'h00000070);
    check("sll31",  ALU_SLL,  32'h00000003, 32'h0000001F, 32'h80000000);
    check("sll_b5", ALU_SLL,  32'h00000001, 32'h00000021, 32'h00000002); // b[4:0] = 1
    check("slt",    ALU_SLT,  32'hFFFFFFFD, 32'h00000007, 32'h00000001);
    check("slt_min",ALU_SLT,  32'h80000000, 32'h7FFFFFFF, 32'h00000001);
    check("slt_eq", ALU_SLT,  32'h00000005, 32'h00000005, 32'h00000000);
    check("sltu",   ALU_SLTU, 32'hFFFFFFFD, 32'h00000007, 32'h00000000);
    check("sltu2",  ALU_SLTU, 32'h00000007, 32'hFFFFFFFF, 32'h00000001);
    check("xor",    ALU_XOR,  32'h00000007, 32'hFFFFFFFD, 32'hFFFFFFFA);
    check("srl",    ALU_SRL,  32'hFFFFFFFD, 32'h00000004, 32'h0FFFFFFF);
    check("srl0",   ALU_SRL,  32'h80000000, 32'h00000000, 32'h80000000);
    check("srl31",  ALU_SRL,  32'h80000000, 32'h0000001F, 32'h00000001);
    check("sra",    ALU_SRA,  32'hFFFFFFFD, 32'h00000004, 32'hFFFFFFFF);
    check("sra31",  ALU_SRA,  32'h80000000, 32'h0000001F, 32'hFFFFFFFF);
    check("sra_pos",ALU_SRA,  32'h7FFFFFF0, 32'h00000004, 32'h07FFFFFF);
    check("srai",   ALU_SRA,  32'h80000000, 32'h00000401, 32'hC0000000); // srai imm = 0x400|1
    check("or",     ALU_OR,   32'h00000007, 32'hFFFFFFF0, 32'hFFFFFFF7);
    check("and",    ALU_AND,  32'h00000007, 32'hFFFFFFFD, 32'h00000005);
    check("badop",  4'b1001,  32'h12345678, 32'h11111111, 32'h00000000);
    check("badop2", 4'b1111,  32'h12345678, 32'h11111111, 32'h00000000);

    // Random vectors against the reference model
    ops[0] = ALU_ADD; ops[1] = ALU_SUB; ops[2] = ALU_SLL; ops[3] = ALU_SLT;
    ops[4] = ALU_SLTU; ops[5] = ALU_XOR; ops[6] = ALU_SRL; ops[7] = ALU_SRA;
    ops[8] = ALU_OR; ops[9] = ALU_AND;
    seed = 2026;
    for (k = 0; k < 10; k = k + 1) begin
      for (i = 0; i < N_RANDOM; i = i + 1) begin
        a = $random(seed);
        b = $random(seed);
        check("random", ops[k], a, b, model(ops[k], a, b));
      end
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
