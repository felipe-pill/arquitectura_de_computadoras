`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for ex_mem_reg.
// Spec: on the rising edge, rst -> all fields 0 (bubble); else if en ->
// load the inputs. With en = 0 nothing changes (no flush, no hold).
// Random stimulus against a model, after a directed sequence.

module tb_ex_mem_reg;

  localparam integer CLK_PERIOD = 10;
  localparam integer N_RANDOM   = 20000;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg          rst = 1, en = 0;
  reg  [108:0] in_bus = 0;   // {ctrl(13), store_data, result, pc}
  wire [31:0]  pc, result, store_data;
  wire [12:0]  ctrl;

  ex_mem_reg dut (
    .clk(clk), .rst(rst), .en(en),
    .in_pc(in_bus[31:0]), .in_result(in_bus[63:32]), .in_store_data(in_bus[95:64]),
    .in_ctrl(in_bus[108:96]),
    .pc(pc), .result(result), .store_data(store_data), .ctrl(ctrl)
  );

  wire [108:0] out_bus = {ctrl, store_data, result, pc};

  integer errors = 0;
  integer checks = 0;
  integer i, seed;
  reg [108:0] model = 0;

  task step;
    input [8*10-1:0] tag;
    input            verbose;
    begin
      @(posedge clk);
      if (rst)     model = 0;
      else if (en) model = in_bus;
      @(negedge clk);
      checks = checks + 1;
      if (out_bus === model) begin
        if (verbose)
          $display("PASS %0s: rst=%b en=%b -> %028h", tag, rst, en, out_bus);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: rst=%b en=%b expected %028h got %028h  TEST FAILED",
                 tag, rst, en, model, out_bus);
      end
    end
  endtask

  initial begin
    @(negedge clk);
    rst = 1; step("reset", 1'b1);
    rst = 0; en = 1; in_bus = {13'h1FFF, 32'h33333333, 32'h22222222, 32'h11111111};
    step("load", 1'b1);
    en = 0; in_bus = 0; step("en0", 1'b1);
    en = 1; step("load0", 1'b1);

    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      rst = ($random(seed) % 32) == 0;
      en = ($random(seed) % 4) != 0;
      in_bus = {$random(seed), $random(seed), $random(seed), $random(seed)};
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
