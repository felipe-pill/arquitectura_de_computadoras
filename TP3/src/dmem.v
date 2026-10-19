`timescale 1ns/1ps
`default_nettype none

// Data memory: inferred true dual-port block RAM, 2**ADDR_W x 32, with byte
// write enables on port A (docs/arquitectura.md 4.2, 4.3).
// - Port A: core loads/stores (or the Debug Unit clearing memory while the
//   core is in reset). a_en gates both the write and the read: with
//   a_en = 0 nothing is written and a_rdata holds its value. Read-first:
//   a read and a write to the same word in one cycle return the old data.
// - Port B: read-only, for the Debug Unit state dump. It never disturbs
//   a_rdata, which is pipeline state.
// The array is written only in the port A block. Addresses are word indexes.

module dmem #(
  parameter integer ADDR_W = 10
)(
  input  wire              clk,
  input  wire              a_en,
  input  wire [3:0]        a_we,
  input  wire [ADDR_W-1:0] a_addr,
  input  wire [31:0]       a_wdata,
  output reg  [31:0]       a_rdata,
  input  wire [ADDR_W-1:0] b_addr,
  output reg  [31:0]       b_rdata
);

  localparam integer DEPTH = 1 << ADDR_W;

  reg [31:0] mem [0:DEPTH-1];

  // Initial memory contents (bitstream init value)
  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1)
      mem[i] = 32'd0;
  end

  always @(posedge clk) begin
    if (a_en) begin
      if (a_we[0]) mem[a_addr][7:0]   <= a_wdata[7:0];
      if (a_we[1]) mem[a_addr][15:8]  <= a_wdata[15:8];
      if (a_we[2]) mem[a_addr][23:16] <= a_wdata[23:16];
      if (a_we[3]) mem[a_addr][31:24] <= a_wdata[31:24];
      a_rdata <= mem[a_addr];
    end
  end

  always @(posedge clk) begin
    b_rdata <= mem[b_addr];
  end

endmodule

`default_nettype wire
