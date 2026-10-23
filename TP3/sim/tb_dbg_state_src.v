`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for dbg_state_src.
// Spec (docs/protocol.md 6): STATE byte idx is
//   0..11 status (little-endian), 12..75 core_vec bytes,
//   76..203 x0..x31 (u32 LE, through reg_addr/reg_data),
//   204..   dmem words (u32 LE, through dmem_addr/dmem_data, synchronous read);
// short mode returns short_data bytes (LE). The answer comes 3 cycles after
// req (valid pulse). The register file and dmem are modeled in the
// testbench (combinational and synchronous read, as in the design).

module tb_dbg_state_src;

  localparam integer CLK_PERIOD  = 10;
  localparam integer DMEM_ADDR_W = 4;
  localparam integer DMEM_DEPTH  = 1 << DMEM_ADDR_W;
  localparam integer LATENCY     = 3;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  reg                    rst = 1'b1, req = 1'b0, mode = 1'b0;
  reg  [15:0]            idx = 16'd0, short_data = 16'd0;
  reg  [95:0]            status;
  reg  [511:0]           core_vec;
  wire [4:0]             reg_addr;
  wire [DMEM_ADDR_W-1:0] dmem_addr;
  reg  [31:0]            dmem_data = 32'd0;
  wire                   valid;
  wire [7:0]             data;

  reg [31:0] regs [0:31];
  reg [31:0] mem  [0:DMEM_DEPTH-1];
  wire [31:0] reg_data = regs[reg_addr];
  always @(posedge clk) dmem_data <= mem[dmem_addr];

  dbg_state_src #(.DMEM_ADDR_W(DMEM_ADDR_W)) dut (
    .clk(clk), .rst(rst), .req(req), .idx(idx), .mode(mode), .short_data(short_data),
    .status(status), .core_vec(core_vec),
    .reg_addr(reg_addr), .reg_data(reg_data),
    .dmem_addr(dmem_addr), .dmem_data(dmem_data),
    .valid(valid), .data(data)
  );

  integer errors = 0, checks = 0;
  integer i, k, seed, waited;
  reg [7:0] expected;

  function [7:0] model;
    input integer n;
    begin
      if (mode)            model = (n % 2) ? short_data[15:8] : short_data[7:0];
      else if (n < 12)     model = status >> (8 * n);
      else if (n < 76)     model = core_vec >> (8 * (n - 12));
      else if (n < 204)    model = regs[(n - 76) / 4] >> (8 * ((n - 76) % 4));
      else                 model = mem[(n - 204) / 4] >> (8 * ((n - 204) % 4));
    end
  endfunction

  task fetch;
    input integer n;
    input         verbose;
    begin
      @(negedge clk);
      idx = n; req = 1'b1;
      expected = model(n);
      @(negedge clk);
      req = 1'b0;
      waited = 1;
      while (!valid && waited < 10) begin @(negedge clk); waited = waited + 1; end
      checks = checks + 1;
      if (valid && waited == LATENCY && data === expected) begin
        if (verbose) $display("PASS idx=%0d mode=%b -> %02h after %0d cycles", n, mode, data, waited);
      end else begin
        errors = errors + 1;
        $display("FAIL idx=%0d mode=%b expected %02h after %0d cycles, got valid=%b data=%02h after %0d  TEST FAILED",
                 n, mode, expected, LATENCY, valid, data, waited);
      end
    end
  endtask

  initial begin
    seed = 2026;
    for (i = 0; i < 32; i = i + 1) regs[i] = $random(seed);
    for (i = 0; i < DMEM_DEPTH; i = i + 1) mem[i] = $random(seed);
    status = {$random(seed), $random(seed), $random(seed)};
    for (i = 0; i < 16; i = i + 1) core_vec[32*i +: 32] = $random(seed);
    short_data = 16'hBEEF;
    repeat (3) @(negedge clk);
    rst = 1'b0;

    // Every STATE byte, in order, as dbg_tx_frame asks for them
    mode = 1'b0;
    for (k = 0; k < 204 + 4 * DMEM_DEPTH; k = k + 1)
      fetch(k, k == 0 || k == 12 || k == 76 || k == 204);
    // Random order
    for (k = 0; k < 500; k = k + 1)
      fetch($unsigned($random(seed)) % (204 + 4 * DMEM_DEPTH), 1'b0);
    // Short payload
    mode = 1'b1;
    fetch(0, 1'b1);
    fetch(1, 1'b1);

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
