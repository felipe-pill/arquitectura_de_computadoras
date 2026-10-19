`timescale 1ns/1ps
`default_nettype none

// Instruction memory: inferred simple dual-port block RAM, 2**ADDR_W x 32.
// - Write port: Debug Unit only (program loading, core held in reset).
// - Read port: core fetch. Synchronous read; the core drives raddr from
//   next_pc so rdata is aligned with PC during IF (docs/arquitectura.md 4.2).
// Contents start at 0, optionally loaded from INIT_FILE ($readmemh, one
// 32-bit hex word per line). Addresses are word indexes.

module imem #(
  parameter integer ADDR_W    = 10,
  parameter         INIT_FILE = ""
)(
  input  wire              clk,
  input  wire              we,
  input  wire [ADDR_W-1:0] waddr,
  input  wire [31:0]       wdata,
  input  wire [ADDR_W-1:0] raddr,
  output reg  [31:0]       rdata
);

  localparam integer DEPTH = 1 << ADDR_W;

  reg [31:0] mem [0:DEPTH-1];

  // Initial memory contents (bitstream init value)
  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1)
      mem[i] = 32'd0;
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem);
  end

  always @(posedge clk) begin
    if (we)
      mem[waddr] <= wdata;
  end

  always @(posedge clk) begin
    rdata <= mem[raddr];
  end

endmodule

`default_nettype wire
