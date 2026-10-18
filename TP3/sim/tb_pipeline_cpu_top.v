`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for pipeline_cpu_top.
// Runs the program preloaded in IMEM and checks the final architectural
// state against the values the RV32I program must produce:
//   addi x1, x0, 5      -> x1 = 5
//   addi x2, x0, 7      -> x2 = 7
//   add  x3, x1, x2     -> x3 = 12   (EX/WB forwarding)
//   sw   x3, 0(x0)      -> mem[0] = 12
//   lw   x4, 0(x0)      -> x4 = 12
//   add  x5, x4, x3     -> x5 = 24   (load-use stall)

module tb_pipeline_cpu_top;

  localparam integer CLK_PERIOD = 10;   // 100 MHz
  localparam integer RST_CYCLES = 2;
  localparam integer RUN_CYCLES = 200;  // program is 6 instr; ample margin
  localparam integer XLEN       = 32;

  reg clk = 1'b0;
  reg rst = 1'b1;

  wire uart_tx;

  pipeline_cpu_top dut (
      .clk    (clk),
      .rst    (rst),
      .uart_rx(1'b1),
      .uart_tx(uart_tx)
  );

  always #(CLK_PERIOD/2) clk = ~clk;

  integer errors = 0;

  task check;
    input [8*8-1:0]  name;
    input [XLEN-1:0] actual;
    input [XLEN-1:0] expected;
    begin
      if (actual === expected)
        $display("PASS: %0s expected=%0d actual=%0d", name, expected, actual);
      else begin
        $display("FAIL: %0s expected=%0d actual=%0d  TEST FAILED", name, expected, actual);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    $dumpfile("cpu.vcd");
    $dumpvars(0, tb_pipeline_cpu_top);

    rst = 1'b1;
    repeat (RST_CYCLES) @(posedge clk);
    @(negedge clk) rst = 1'b0;

    repeat (RUN_CYCLES) @(posedge clk);
    #1;

    check("x1",     dut.u_core.u_regfile.regs[1], 32'd5);
    check("x2",     dut.u_core.u_regfile.regs[2], 32'd7);
    check("x3",     dut.u_core.u_regfile.regs[3], 32'd12);
    check("x4",     dut.u_core.u_regfile.regs[4], 32'd12);
    check("x5",     dut.u_core.u_regfile.regs[5], 32'd24);
    check("mem[0]", dut.dmem[0],                  32'd12);
    check("uart_tx", {{(XLEN-1){1'b0}}, uart_tx}, 32'd1);  // idle-high

    if (errors == 0)
      $display("ALL TESTS PASSED");
    else
      $fatal(1, "%0d check(s) failed", errors);

    $finish;
  end

endmodule

`default_nettype wire
