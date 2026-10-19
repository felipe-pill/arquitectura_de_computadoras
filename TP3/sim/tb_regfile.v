`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for regfile.
// Spec (docs/arquitectura.md 3.1, 7):
// - x0 reads 0 and ignores writes; reset clears x1..x31;
// - writes on the rising edge when we = 1;
// - read ports are combinational and bypass a same-cycle write
//   (we && waddr == raddr && waddr != 0 -> rdata = wdata);
// - the debug port is combinational and has no bypass.
// Inputs change on the falling edge; checks happen just before the next
// rising edge. A reference array models the expected contents.

module tb_regfile;

  localparam integer CLK_PERIOD = 10;
  localparam integer N_RANDOM   = 3000;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg         rst = 1'b0, we = 1'b0;
  reg  [4:0]  waddr = 5'd0, raddr1 = 5'd0, raddr2 = 5'd0, dbg_addr = 5'd0;
  reg  [31:0] wdata = 32'd0;
  wire [31:0] rdata1, rdata2, dbg_data;

  regfile dut (
    .clk(clk), .rst(rst), .we(we), .waddr(waddr), .wdata(wdata),
    .raddr1(raddr1), .raddr2(raddr2), .rdata1(rdata1), .rdata2(rdata2),
    .dbg_addr(dbg_addr), .dbg_data(dbg_data)
  );

  reg [31:0] model [0:31];
  integer errors = 0;
  integer checks = 0;
  integer i, j, seed;

  task expect32;
    input [8*12-1:0] tag;
    input [31:0]     got, expected;
    input            verbose;
    begin
      checks = checks + 1;
      if (got === expected) begin
        if (verbose)
          $display("PASS %0s: w(we=%b x%0d=%08h) r1=x%0d r2=x%0d dbg=x%0d -> %08h",
                   tag, we, waddr, wdata, raddr1, raddr2, dbg_addr, got);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: w(we=%b x%0d=%08h) r1=x%0d r2=x%0d dbg=x%0d expected=%08h got=%08h  TEST FAILED",
                 tag, we, waddr, wdata, raddr1, raddr2, dbg_addr, expected, got);
      end
    end
  endtask

  // Expected value of a read port (with bypass) and of the debug port
  function [31:0] exp_read;
    input [4:0] addr;
    begin
      if (addr == 5'd0)
        exp_read = 32'd0;
      else if (we && waddr == addr)
        exp_read = wdata;
      else
        exp_read = model[addr];
    end
  endfunction

  function [31:0] exp_dbg;
    input [4:0] addr;
    begin
      exp_dbg = (addr == 5'd0) ? 32'd0 : model[addr];
    end
  endfunction

  // Check all three ports with the current inputs, then clock once
  task check_and_clock;
    input [8*12-1:0] tag;
    input            verbose;
    begin
      #1;
      expect32(tag, rdata1,   exp_read(raddr1), verbose);
      expect32(tag, rdata2,   exp_read(raddr2), verbose);
      expect32(tag, dbg_data, exp_dbg(dbg_addr), verbose);
      @(posedge clk);
      if (rst) begin
        for (j = 0; j < 32; j = j + 1) model[j] = 32'd0;
      end else if (we && waddr != 5'd0) begin
        model[waddr] = wdata;
      end
      @(negedge clk);
    end
  endtask

  initial begin
    for (i = 0; i < 32; i = i + 1) model[i] = 32'd0;
    seed = 2026;

    // 1. Power-up reset (contents are undefined before it, as in the real
    //    design, which always resets at power-up). Then fill every register
    //    (including an attempt on x0), read them back, and reset again.
    @(negedge clk);
    rst = 1'b1;
    @(negedge clk);
    rst = 1'b0;
    for (i = 0; i < 32; i = i + 1) begin
      we = 1'b1; waddr = i; wdata = 32'hA5A50000 | i;
      raddr1 = i; raddr2 = (i + 1) % 32; dbg_addr = i;
      check_and_clock("fill", i < 3);
    end
    we = 1'b0;
    for (i = 0; i < 32; i = i + 1) begin
      raddr1 = i; raddr2 = 31 - i; dbg_addr = i;
      check_and_clock("readback", i < 3);
    end
    we = 1'b1; waddr = 5'd7; wdata = 32'h0BADF00D;  // write ignored: reset wins
    rst = 1'b1;
    check_and_clock("reset", 1'b0);
    rst = 1'b0; we = 1'b0;
    for (i = 0; i < 32; i = i + 1) begin
      raddr1 = i; raddr2 = i; dbg_addr = i;
      #1;
      expect32("after_reset", rdata1, 32'd0, i == 31);
      expect32("after_reset", dbg_data, 32'd0, 1'b0);
    end

    // 2. Bypass: same-cycle write is visible on read ports, not on debug
    we = 1'b1; waddr = 5'd5; wdata = 32'hDEADBEEF;
    raddr1 = 5'd5; raddr2 = 5'd6; dbg_addr = 5'd5;
    #1;
    expect32("bypass_r1", rdata1, 32'hDEADBEEF, 1'b1);
    expect32("bypass_r2", rdata2, 32'd0, 1'b1);       // other register
    expect32("no_bp_dbg", dbg_data, 32'd0, 1'b1);     // old value
    check_and_clock("bypass", 1'b0);

    // 3. Bypass on x0 never happens; x0 stays 0
    we = 1'b1; waddr = 5'd0; wdata = 32'hFFFFFFFF;
    raddr1 = 5'd0; raddr2 = 5'd0; dbg_addr = 5'd0;
    #1;
    expect32("x0_bypass", rdata1, 32'd0, 1'b1);
    check_and_clock("x0_write", 1'b0);
    we = 1'b0;
    #1;
    expect32("x0_after", rdata1, 32'd0, 1'b1);

    // 4. we = 0: no write and no bypass
    we = 1'b0; waddr = 5'd5; wdata = 32'h12345678;
    raddr1 = 5'd5; raddr2 = 5'd5; dbg_addr = 5'd5;
    #1;
    expect32("we0_nobp", rdata1, 32'hDEADBEEF, 1'b1);
    check_and_clock("we0", 1'b0);
    #1;
    expect32("we0_kept", rdata1, 32'hDEADBEEF, 1'b1);

    // 5. Random operations against the model (with occasional resets)
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      rst      = ($random(seed) % 200) == 0;
      we       = rst ? 1'b0 : $random(seed);
      waddr    = $random(seed);
      wdata    = $random(seed);
      raddr1   = ($random(seed) % 4 == 0) ? waddr : $random(seed);
      raddr2   = ($random(seed) % 4 == 0) ? waddr : $random(seed);
      dbg_addr = $random(seed);
      check_and_clock("random", 1'b0);
    end
    rst = 1'b0;

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
