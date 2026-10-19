`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for id_ex_reg.
// Spec: on the rising edge, rst -> all fields 0 (bubble); else if en:
// flush -> all fields 0, else load the inputs. With en = 0 nothing changes.
// Random stimulus against a model, after a directed sequence.

module tb_id_ex_reg;

  localparam integer CLK_PERIOD = 10;
  localparam integer N_RANDOM   = 20000;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg          rst = 1, en = 0, flush = 0;
  reg  [159:0] in_bus = 0;   // {ctrl(31, padded to 32), imm, rs2, rs1, pc}
  wire [31:0]  pc, rs1_data, rs2_data, imm;
  wire [30:0]  ctrl;

  id_ex_reg dut (
    .clk(clk), .rst(rst), .en(en), .flush(flush),
    .in_pc(in_bus[31:0]), .in_rs1_data(in_bus[63:32]), .in_rs2_data(in_bus[95:64]),
    .in_imm(in_bus[127:96]), .in_ctrl(in_bus[158:128]),
    .pc(pc), .rs1_data(rs1_data), .rs2_data(rs2_data), .imm(imm), .ctrl(ctrl)
  );

  wire [158:0] out_bus = {ctrl, imm, rs2_data, rs1_data, pc};

  integer errors = 0;
  integer checks = 0;
  integer i, seed;
  reg [158:0] model = 0;

  task step;
    input [8*10-1:0] tag;
    input            verbose;
    begin
      @(posedge clk);
      if (rst || (en && flush)) model = 0;
      else if (en)              model = in_bus[158:0];
      @(negedge clk);
      checks = checks + 1;
      if (out_bus === model) begin
        if (verbose)
          $display("PASS %0s: rst=%b en=%b flush=%b -> %040h", tag, rst, en, flush, out_bus);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: rst=%b en=%b flush=%b expected %040h got %040h  TEST FAILED",
                 tag, rst, en, flush, model, out_bus);
      end
    end
  endtask

  initial begin
    @(negedge clk);
    rst = 1; step("reset", 1'b1);
    rst = 0; en = 1; in_bus = {32'h7FFFFFFF, 32'h44444444, 32'h33333333, 32'h22222222, 32'h11111111};
    step("load", 1'b1);
    en = 0; in_bus = 0; step("en0", 1'b1);
    en = 1; flush = 1; step("flush", 1'b1);

    seed = 2026;
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      rst = ($random(seed) % 32) == 0;
      en = ($random(seed) % 4) != 0;
      flush = ($random(seed) % 4) == 0;
      in_bus = {$random(seed), $random(seed), $random(seed), $random(seed), $random(seed)};
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
