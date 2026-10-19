`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for fetch_unit.
// Spec (docs/arquitectura.md 3.4, 4.2, 5.1):
//   next_pc = 0 on rst; else pc if !en; else ex_target if ex_redirect;
//   else halt_pc if halt_accept; else pc if halting or load_use;
//   else id_jal_target if id_jal; else pc + 4.
//   pc <= next_pc on the edge (0 on rst, unchanged if !en).
//   imem_addr = next_pc word index (next_pc[IMEM_ADDR_W+1:2]).
//   fetch_stop_code = 4 (TIMEOUT) if timeout, else 3 (OOR) if
//   pc >= 4 * imem_limit, else 0.
// Directed sequence first, then random inputs every cycle against a model.
// IMEM_ADDR_W = 4 so imem_limit spans 0..16 words.

module tb_fetch_unit;

  localparam integer CLK_PERIOD  = 10;
  localparam integer IMEM_ADDR_W = 4;
  localparam integer N_RANDOM    = 20000;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg                    rst = 1, en = 0, ex_redirect = 0, halt_accept = 0;
  reg                    halting = 0, load_use = 0, id_jal = 0, timeout = 0;
  reg  [31:0]            ex_target = 0, halt_pc = 0, id_jal_target = 0;
  reg  [IMEM_ADDR_W:0]   imem_limit = 0;
  wire [31:0]            pc;
  wire [IMEM_ADDR_W-1:0] imem_addr;
  wire [2:0]             stop_code;

  fetch_unit #(.IMEM_ADDR_W(IMEM_ADDR_W)) dut (
    .clk(clk), .rst(rst), .en(en), .ex_redirect(ex_redirect), .ex_target(ex_target),
    .halt_accept(halt_accept), .halt_pc(halt_pc), .halting(halting),
    .load_use(load_use), .id_jal(id_jal), .id_jal_target(id_jal_target),
    .timeout(timeout), .imem_limit(imem_limit),
    .pc(pc), .imem_addr(imem_addr), .fetch_stop_code(stop_code)
  );

  integer errors = 0;
  integer checks = 0;
  integer i, seed;
  reg [31:0] pc_model = 32'd0;
  reg [31:0] exp_next;
  reg [2:0]  exp_stop;

  function [31:0] model_next;
    input dummy;
    begin
      if (rst)                       model_next = 32'd0;
      else if (!en)                  model_next = pc_model;
      else if (ex_redirect)          model_next = ex_target;
      else if (halt_accept)          model_next = halt_pc;
      else if (halting || load_use)  model_next = pc_model;
      else if (id_jal)               model_next = id_jal_target;
      else                           model_next = pc_model + 32'd4;
    end
  endfunction

  // Check the combinational outputs, clock once, check the new pc
  task step;
    input [8*10-1:0] tag;
    input            verbose;
    begin
      #1;
      exp_next = model_next(1'b0);
      exp_stop = timeout ? 3'd4 : (pc_model >= 4 * imem_limit) ? 3'd3 : 3'd0;
      checks = checks + 1;
      if (pc === pc_model && imem_addr === exp_next[IMEM_ADDR_W+1:2] && stop_code === exp_stop) begin
        if (verbose)
          $display("PASS %0s: pc=%08h next=%08h imem_addr=%0d stop=%0d", tag, pc, exp_next, imem_addr, stop_code);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: rst=%b en=%b redir=%b hacc=%b halting=%b lu=%b jal=%b to=%b limit=%0d | expected pc=%08h addr=%0d stop=%0d got pc=%08h addr=%0d stop=%0d  TEST FAILED",
                 tag, rst, en, ex_redirect, halt_accept, halting, load_use, id_jal, timeout, imem_limit,
                 pc_model, exp_next[IMEM_ADDR_W+1:2], exp_stop, pc, imem_addr, stop_code);
      end
      @(posedge clk);
      pc_model = exp_next;   // rst gives 0 and !en gives pc via model_next
      @(negedge clk);
    end
  endtask

  task clear_inputs;
    begin
      rst = 0; en = 1; ex_redirect = 0; halt_accept = 0; halting = 0;
      load_use = 0; id_jal = 0; timeout = 0;
    end
  endtask

  initial begin
    // Directed (one reset edge first: pc is undefined before it)
    @(posedge clk);
    @(negedge clk);
    rst = 1; step("reset", 1'b1);
    clear_inputs; imem_limit = 3;
    step("seq0", 1'b1);                                 // pc 0 -> 4
    step("seq4", 1'b1);                                 // pc 4 -> 8
    step("seq8", 1'b1);                                 // pc 8 -> 12 (12 = 4*limit: OOR next)
    step("oor", 1'b1);
    timeout = 1; step("timeout", 1'b1);                 // TIMEOUT beats OOR
    timeout = 0; en = 0; step("hold_en", 1'b1);
    en = 1; ex_redirect = 1; ex_target = 32'h20; halt_accept = 1; halt_pc = 32'h8;
    id_jal = 1; id_jal_target = 32'h40; load_use = 1; step("redirect", 1'b1);
    ex_redirect = 0; step("halt_acc", 1'b1);            // halt_pc beats hold and jal
    halt_accept = 0; halting = 1; step("halting", 1'b1);
    halting = 0; step("load_use", 1'b1);                // load_use beats jal
    load_use = 0; step("jal", 1'b1);
    id_jal = 0; step("plus4", 1'b1);

    // Random
    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      rst           = ($random(seed) % 64) == 0;
      en            = ($random(seed) % 8) != 0;
      ex_redirect   = ($random(seed) % 6) == 0;
      ex_target     = ($random(seed) & 32'h7C) | (($random(seed) % 4 == 0) ? 32'h2 : 32'h0);
      halt_accept   = ($random(seed) % 10) == 0;
      halt_pc       = $random(seed) & 32'h7C;
      halting       = ($random(seed) % 8) == 0;
      load_use      = ($random(seed) % 6) == 0;
      id_jal        = ($random(seed) % 6) == 0;
      id_jal_target = $random(seed) & 32'h7C;
      timeout       = ($random(seed) % 16) == 0;
      imem_limit    = $unsigned($random(seed)) % 17;
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
