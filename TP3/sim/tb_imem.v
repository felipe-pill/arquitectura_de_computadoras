`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for imem.
// Spec (docs/arquitectura.md 4.2-4.5):
// - write port: mem[waddr] <= wdata on the rising edge when we = 1;
// - read port: synchronous, rdata = mem[raddr] one edge after raddr is
//   presented, and stable between edges;
// - contents start at 0, or come from INIT_FILE ($readmemh).
// Uses ADDR_W = 4 so every address is exercised. The INIT_FILE instance
// reads imem_init.hex (TP3/sim/data, copied by sim/prebuild.bat):
// 00500093, 00100073, cafef00d.

module tb_imem;

  localparam integer CLK_PERIOD = 10;
  localparam integer ADDR_W     = 4;
  localparam integer DEPTH      = 1 << ADDR_W;
  localparam integer N_RANDOM   = 1000;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg              we = 1'b0;
  reg [ADDR_W-1:0] waddr = 0, raddr = 0;
  reg [31:0]       wdata = 32'd0;
  wire [31:0]      rdata, rdata_init;

  imem #(.ADDR_W(ADDR_W)) dut (
    .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
    .raddr(raddr), .rdata(rdata)
  );

  // Second instance: initialized from a file, never written
  reg [ADDR_W-1:0] raddr_init = 0;
  imem #(.ADDR_W(ADDR_W), .INIT_FILE("imem_init.hex")) dut_init (
    .clk(clk), .we(1'b0), .waddr({ADDR_W{1'b0}}), .wdata(32'd0),
    .raddr(raddr_init), .rdata(rdata_init)
  );

  reg [31:0] model [0:DEPTH-1];
  integer errors = 0;
  integer checks = 0;
  integer i, seed;
  reg [31:0] expected;

  task expect32;
    input [8*10-1:0] tag;
    input [31:0]     got, exp;
    input            verbose;
    begin
      checks = checks + 1;
      if (got === exp) begin
        if (verbose)
          $display("PASS %0s: raddr=%0d raddr_init=%0d -> %08h", tag, raddr, raddr_init, got);
      end else begin
        errors = errors + 1;
        $display("FAIL %0s: raddr=%0d raddr_init=%0d we=%b waddr=%0d expected=%08h got=%08h  TEST FAILED",
                 tag, raddr, raddr_init, we, waddr, exp, got);
      end
    end
  endtask

  // Present a read address, clock once, check the registered data
  task read_check;
    input [8*10-1:0]   tag;
    input [ADDR_W-1:0] addr;
    input              verbose;
    begin
      @(negedge clk);
      raddr = addr;
      expected = model[addr];
      @(negedge clk);
      expect32(tag, rdata, expected, verbose);
    end
  endtask

  initial begin
    for (i = 0; i < DEPTH; i = i + 1) model[i] = 32'd0;
    seed = 2026;

    // 1. Contents start at 0
    for (i = 0; i < DEPTH; i = i + 1)
      read_check("zero", i, i == 0);

    // 2. Write every address, read back
    for (i = 0; i < DEPTH; i = i + 1) begin
      @(negedge clk);
      we = 1'b1; waddr = i; wdata = 32'h10000000 * i + 32'h00ABCD00 + i;
      @(posedge clk);
      model[i] = wdata;
    end
    @(negedge clk);
    we = 1'b0;
    for (i = 0; i < DEPTH; i = i + 1)
      read_check("readback", i, i < 2);

    // 3. Read is synchronous: rdata does not follow raddr until the edge
    @(negedge clk);
    raddr = 3;
    @(negedge clk);
    expect32("sync_a", rdata, model[3], 1'b1);
    raddr = 9;
    #2;
    expect32("sync_hold", rdata, model[3], 1'b1);  // still the old word
    @(negedge clk);
    expect32("sync_b", rdata, model[9], 1'b1);

    // 4. we = 0 does not write
    @(negedge clk);
    we = 1'b0; waddr = 5; wdata = 32'hFFFFFFFF;
    @(negedge clk);
    read_check("we0", 5, 1'b1);

    // 5. Random writes and reads (different addresses in the same cycle;
    //    a same-address collision between the ports is never used by the
    //    design, which holds the core in reset while loading)
    for (i = 0; i < N_RANDOM; i = i + 1) begin
      @(negedge clk);
      we    = $random(seed);
      waddr = $random(seed);
      wdata = $random(seed);
      raddr = $random(seed);
      if (we && raddr == waddr) raddr = raddr + 1;
      expected = model[raddr];
      @(posedge clk);
      if (we) model[waddr] = wdata;
      @(negedge clk);
      expect32("random", rdata, expected, 1'b0);
    end
    we = 1'b0;

    // 6. INIT_FILE instance
    @(negedge clk); raddr_init = 0;
    @(negedge clk); expect32("init0", rdata_init, 32'h00500093, 1'b1);
    raddr_init = 1;
    @(negedge clk); expect32("init1", rdata_init, 32'h00100073, 1'b1);
    raddr_init = 2;
    @(negedge clk); expect32("init2", rdata_init, 32'hCAFEF00D, 1'b1);
    raddr_init = 3;
    @(negedge clk); expect32("init3", rdata_init, 32'h00000000, 1'b1);  // past the file
    raddr_init = DEPTH - 1;
    @(negedge clk); expect32("init_end", rdata_init, 32'h00000000, 1'b1);

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
