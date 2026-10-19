`timescale 1ns/1ps
`default_nettype none

// Load data alignment and extension (combinational, MEM stage).
// rdata is the whole memory word; addr_lo = address[1:0].
//   lb/lbu (000/100): byte addr_lo, sign/zero extended
//   lh/lhu (001/101): half addr_lo[1] (addr_lo[0] ignored), sign/zero extended
//   lw     (010):     whole word (addr_lo ignored)
// Misaligned behavior per docs/arquitectura.md 2.3.

module load_align (
  input  wire [2:0]  funct3,
  input  wire [1:0]  addr_lo,
  input  wire [31:0] rdata,
  output reg  [31:0] data
);

  localparam [2:0] F3_LB  = 3'b000;
  localparam [2:0] F3_LH  = 3'b001;
  localparam [2:0] F3_LW  = 3'b010;
  localparam [2:0] F3_LBU = 3'b100;
  localparam [2:0] F3_LHU = 3'b101;

  wire [31:0] shifted  = rdata >> {addr_lo, 3'b000};
  wire [7:0]  byte_sel = shifted[7:0];
  wire [15:0] half_sel = addr_lo[1] ? rdata[31:16] : rdata[15:0];

  always @(*) begin
    data = rdata;
    case (funct3)
      F3_LB:   data = {{24{byte_sel[7]}}, byte_sel};
      F3_LH:   data = {{16{half_sel[15]}}, half_sel};
      F3_LW:   data = rdata;
      F3_LBU:  data = {24'd0, byte_sel};
      F3_LHU:  data = {16'd0, half_sel};
      default: data = rdata;
    endcase
  end

endmodule

`default_nettype wire
