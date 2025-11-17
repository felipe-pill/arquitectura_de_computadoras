`timescale 1ns/1ps
`default_nettype none

module tb_pipeline_cpu_top;

  reg clk = 1'b0;
  reg rst = 1'b1;

  wire uart_tx;

  pipeline_cpu_top dut (
      .clk    (clk),
      .rst    (rst),
      .uart_rx(1'b1),
      .uart_tx(uart_tx)
  );

  always #5 clk = ~clk; // 100 MHz

  initial begin
    $dumpfile("cpu.vcd");
    $dumpvars(0, tb_pipeline_cpu_top);

    // reset
    #20;
    rst = 1'b0;

    // run for some cycles
    #2000;

    // check some regs by hierarchical reference (for now)
$display("x1 = %0d", dut.u_core.u_regfile.regs[1]);
$display("x2 = %0d", dut.u_core.u_regfile.regs[2]);
$display("x3 = %0d", dut.u_core.u_regfile.regs[3]);
$display("x4 = %0d", dut.u_core.u_regfile.regs[4]);
$display("x5 = %0d", dut.u_core.u_regfile.regs[5]);
$display("mem[0] = %0d", dut.dmem[0]);


    $finish;
  end

endmodule

`default_nettype wire
