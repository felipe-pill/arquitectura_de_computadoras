`timescale 1ns/1ps
`default_nettype none

// Store data alignment and byte enables (combinational, EX stage).
// funct3[1:0]: 00 sb, 01 sh, 10 sw; addr_lo = address[1:0].
// The data is replicated on every lane; be selects the lanes written.
//   sb: be = 0001 << addr_lo
//   sh: be = 0011 or 1100 by addr_lo[1] (addr_lo[0] ignored)
//   sw: be = 1111 (addr_lo ignored)
// be is 0 for funct3[1:0] = 11. The caller gates be with mem_write and en.

module store_align (
  input  wire [1:0]  funct3,
  input  wire [1:0]  addr_lo,
  input  wire [31:0] data,
  output reg  [31:0] wdata,
  output reg  [3:0]  be
);

  localparam [1:0] SZ_B = 2'b00;
  localparam [1:0] SZ_H = 2'b01;
  localparam [1:0] SZ_W = 2'b10;

  always @(*) begin
    wdata = data;
    be    = 4'b0000;
    case (funct3)
      SZ_B: begin
        wdata = {4{data[7:0]}};
        be    = 4'b0001 << addr_lo;
      end
      SZ_H: begin
        wdata = {2{data[15:0]}};
        be    = addr_lo[1] ? 4'b1100 : 4'b0011;
      end
      SZ_W: begin
        wdata = data;
        be    = 4'b1111;
      end
      default: begin
        wdata = data;
        be    = 4'b0000;
      end
    endcase
  end

endmodule

`default_nettype wire
