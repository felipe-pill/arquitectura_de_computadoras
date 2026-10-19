`timescale 1ns/1ps
`default_nettype none

// 32 x XLEN register file in flip-flops (docs/arquitectura.md 3.1, 7).
// - x0 is hardwired to 0; writes to x0 are ignored.
// - Synchronous active-high reset clears x1..x31.
// - Two asynchronous read ports with internal write bypass: a read of the
//   register being written this cycle returns wdata (WB -> ID forwarding).
// - Debug read port, asynchronous, no bypass (the core is frozen when read).
// Each register lives in its own always block (generate), so no variable is
// assigned from more than one block.

module regfile #(
  parameter integer XLEN = 32
)(
  input  wire            clk,
  input  wire            rst,
  input  wire            we,
  input  wire [4:0]      waddr,
  input  wire [XLEN-1:0] wdata,
  input  wire [4:0]      raddr1,
  input  wire [4:0]      raddr2,
  output wire [XLEN-1:0] rdata1,
  output wire [XLEN-1:0] rdata2,
  input  wire [4:0]      dbg_addr,
  output wire [XLEN-1:0] dbg_data
);

  localparam integer NREGS = 32;

  wire [XLEN-1:0] rf [0:NREGS-1];

  assign rf[0] = {XLEN{1'b0}};

  genvar g;
  generate
    for (g = 1; g < NREGS; g = g + 1) begin : gen_reg
      reg [XLEN-1:0] q;
      always @(posedge clk) begin
        if (rst)
          q <= {XLEN{1'b0}};
        else if (we && waddr == g)
          q <= wdata;
      end
      assign rf[g] = q;
    end
  endgenerate

  wire bypass1 = we && (waddr != 5'd0) && (waddr == raddr1);
  wire bypass2 = we && (waddr != 5'd0) && (waddr == raddr2);

  assign rdata1   = bypass1 ? wdata : rf[raddr1];
  assign rdata2   = bypass2 ? wdata : rf[raddr2];
  assign dbg_data = rf[dbg_addr];

endmodule

`default_nettype wire
