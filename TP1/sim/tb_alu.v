`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for myALU.
// Expected values come from a reference model of the ALU spec:
//   ADD/SUB: 8-bit two's complement; carry = carry-out (SUB: 1 = no borrow,
//            i.e. A >= B unsigned); overflow = signed overflow
//   AND/OR/XOR/NOR: bitwise; carry = overflow = 0
//   SRL/SRA: shift A right by B[2:0]; carry = overflow = 0
//   other opcodes: result 0
//   zero = (result == 0), neg = result[MSB]
//   After reset: A = B = 0, Op = ADD.

module tb_alu;

  localparam integer DATA_WIDTH   = 8;
  localparam integer OPCODE_WIDTH = 6;
  localparam integer CLK_PERIOD   = 10;   // 100 MHz
  localparam integer N_RANDOM     = 200;  // random vectors per opcode
  localparam integer SHAMT_WIDTH  = $clog2(DATA_WIDTH);

  localparam [OPCODE_WIDTH-1:0] OP_ADD = 6'b100000;
  localparam [OPCODE_WIDTH-1:0] OP_SUB = 6'b100010;
  localparam [OPCODE_WIDTH-1:0] OP_AND = 6'b100100;
  localparam [OPCODE_WIDTH-1:0] OP_OR  = 6'b100101;
  localparam [OPCODE_WIDTH-1:0] OP_XOR = 6'b100110;
  localparam [OPCODE_WIDTH-1:0] OP_NOR = 6'b100111;
  localparam [OPCODE_WIDTH-1:0] OP_SRL = 6'b000010;
  localparam [OPCODE_WIDTH-1:0] OP_SRA = 6'b000011;
  localparam [OPCODE_WIDTH-1:0] OP_BAD = 6'b111111;  // not a valid opcode

  reg clk   = 1'b0;
  reg reset = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg                   e1 = 1'b0, e2 = 1'b0, e3 = 1'b0;
  reg  [DATA_WIDTH-1:0] data = {DATA_WIDTH{1'b0}};
  wire [DATA_WIDTH-1:0] result;
  wire                  zero, neg, carry, overflow;

  myALU #(
    .DATA_WIDTH(DATA_WIDTH),
    .OPCODE_WIDTH(OPCODE_WIDTH)
  ) dut (
    .clk(clk), .reset(reset),
    .e1(e1), .e2(e2), .e3(e3),
    .data(data),
    .result(result), .zero(zero), .carry(carry), .overflow(overflow), .neg(neg)
  );

  integer errors = 0;
  integer checks = 0;

  // ---------------- Reference model ----------------
  reg [DATA_WIDTH-1:0] exp_result;
  reg                  exp_carry, exp_overflow;
  reg [DATA_WIDTH:0]   wide;

  task model;
    input [OPCODE_WIDTH-1:0] op;
    input [DATA_WIDTH-1:0]   a, b;
    begin
      exp_carry    = 1'b0;
      exp_overflow = 1'b0;
      case (op)
        OP_ADD: begin
          wide         = a + b;
          exp_result   = wide[DATA_WIDTH-1:0];
          exp_carry    = wide[DATA_WIDTH];
          exp_overflow = ($signed(a) + $signed(b) > (2**(DATA_WIDTH-1)) - 1) ||
                         ($signed(a) + $signed(b) < -(2**(DATA_WIDTH-1)));
        end
        OP_SUB: begin
          exp_result   = a - b;
          exp_carry    = (a >= b);
          exp_overflow = ($signed(a) - $signed(b) > (2**(DATA_WIDTH-1)) - 1) ||
                         ($signed(a) - $signed(b) < -(2**(DATA_WIDTH-1)));
        end
        OP_AND: exp_result = a & b;
        OP_OR:  exp_result = a | b;
        OP_XOR: exp_result = a ^ b;
        OP_NOR: exp_result = ~(a | b);
        OP_SRL: exp_result = a >> b[SHAMT_WIDTH-1:0];
        OP_SRA: exp_result = $signed(a) >>> b[SHAMT_WIDTH-1:0];
        default: exp_result = {DATA_WIDTH{1'b0}};
      endcase
    end
  endtask

  // ---------------- Stimulus helpers ----------------
  // One-cycle enable pulse, driven away from the active clock edge
  task load;
    input [1:0]            which;  // 1 = A, 2 = B, 3 = Op
    input [DATA_WIDTH-1:0] v;
    begin
      @(negedge clk);
      data = v;
      e1 = (which == 2'd1);
      e2 = (which == 2'd2);
      e3 = (which == 2'd3);
      @(negedge clk);
      e1 = 1'b0; e2 = 1'b0; e3 = 1'b0;
    end
  endtask

  task check_outputs;
    input [8*8-1:0]          tag;
    input [OPCODE_WIDTH-1:0] op;
    input [DATA_WIDTH-1:0]   a, b;
    input [DATA_WIDTH-1:0]   r_exp;
    input                    c_exp, v_exp;
    reg                      z_exp, n_exp;
    begin
      z_exp  = (r_exp == {DATA_WIDTH{1'b0}});
      n_exp  = r_exp[DATA_WIDTH-1];
      checks = checks + 1;
      if (result === r_exp && zero === z_exp && neg === n_exp &&
          carry === c_exp && overflow === v_exp) begin
        if (tag != "random")
          $display("PASS %0s: op=%06b A=%02h B=%02h  result=%02h ZNCV=%b%b%b%b",
                   tag, op, a, b, result, zero, neg, carry, overflow);
      end else begin
        $display("FAIL %0s: op=%06b A=%02h B=%02h  expected result=%02h ZNCV=%b%b%b%b  actual result=%02h ZNCV=%b%b%b%b  TEST FAILED",
                 tag, op, a, b, r_exp, z_exp, n_exp, c_exp, v_exp,
                 result, zero, neg, carry, overflow);
        errors = errors + 1;
      end
    end
  endtask

  task run_op;
    input [8*8-1:0]          tag;
    input [OPCODE_WIDTH-1:0] op;
    input [DATA_WIDTH-1:0]   a, b;
    begin
      load(2'd1, a);
      load(2'd2, b);
      load(2'd3, {{(DATA_WIDTH-OPCODE_WIDTH){1'b0}}, op});
      #1;
      model(op, a, b);
      check_outputs(tag, op, a, b, exp_result, exp_carry, exp_overflow);
    end
  endtask

  task do_reset;
    begin
      @(negedge clk); reset = 1'b1;
      repeat (2) @(negedge clk);
      reset = 1'b0;
    end
  endtask

  // ---------------- Test sequence ----------------
  integer k, n;
  reg [OPCODE_WIDTH-1:0] ops [0:7];
  reg [DATA_WIDTH-1:0]   ra, rb;
  integer seed = 32'h1234_5678;

  initial begin
    ops[0] = OP_ADD; ops[1] = OP_SUB; ops[2] = OP_AND; ops[3] = OP_OR;
    ops[4] = OP_XOR; ops[5] = OP_NOR; ops[6] = OP_SRL; ops[7] = OP_SRA;

    // Reset state: A = B = 0, Op = ADD -> result 0, zero = 1
    do_reset();
    #1;
    check_outputs("reset", OP_ADD, 8'h00, 8'h00, 8'h00, 1'b0, 1'b0);

    // Directed cases (from the original tests + flag corner cases)
    run_op("add",    OP_ADD, 8'd15, 8'd27);   // 42
    run_op("add_c",  OP_ADD, 8'hFF, 8'h01);   // 0, carry, zero
    run_op("add_v+", OP_ADD, 8'h7F, 8'h01);   // 0x80, signed overflow
    run_op("add_v-", OP_ADD, 8'h80, 8'h80);   // 0, carry + overflow
    run_op("sub",    OP_SUB, 8'd20, 8'd10);   // 10, no borrow
    run_op("sub_b",  OP_SUB, 8'd10, 8'd20);   // -10, borrow
    run_op("sub_z",  OP_SUB, 8'h33, 8'h33);   // 0
    run_op("sub_v",  OP_SUB, 8'h80, 8'h01);   // 0x7F, signed overflow
    run_op("and",    OP_AND, 8'hF0, 8'h3C);
    run_op("or",     OP_OR,  8'hA5, 8'h0F);   // AF
    run_op("xor",    OP_XOR, 8'hFF, 8'hFF);   // 0
    run_op("nor",    OP_NOR, 8'h00, 8'h00);   // FF, neg
    run_op("srl",    OP_SRL, 8'h80, 8'h02);   // 20
    run_op("srl_b",  OP_SRL, 8'h80, 8'hFB);   // only B[2:0]=3 used -> 10
    run_op("sra",    OP_SRA, 8'h80, 8'h02);   // E0
    run_op("sra_7",  OP_SRA, 8'h80, 8'h07);   // FF
    run_op("bad_op", OP_BAD, 8'h12, 8'h34);   // 0

    // Enables gate the registers: data changes without a pulse are ignored
    run_op("hold", OP_ADD, 8'd1, 8'd2);
    @(negedge clk); data = 8'hEE;
    repeat (3) @(negedge clk);
    #1;
    check_outputs("hold", OP_ADD, 8'd1, 8'd2, 8'd3, 1'b0, 1'b0);

    // Reset clears operands and returns Op to ADD
    run_op("pre_rst", OP_XOR, 8'h0F, 8'hF0);
    do_reset();
    #1;
    check_outputs("reset2", OP_ADD, 8'h00, 8'h00, 8'h00, 1'b0, 1'b0);

    // Random vectors for every opcode
    for (k = 0; k < 8; k = k + 1)
      for (n = 0; n < N_RANDOM; n = n + 1) begin
        ra = $random(seed);
        rb = $random(seed);
        run_op("random", ops[k], ra, rb);
      end

    $display("%0d checks, %0d failures", checks, errors);
    if (errors == 0)
      $display("ALL TESTS PASSED");
    else
      $fatal(1, "%0d check(s) failed", errors);
    $finish;
  end

endmodule

`default_nettype wire
