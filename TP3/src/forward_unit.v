`timescale 1ns/1ps
`default_nettype none

// Forwarding unit (combinational, EX stage). docs/arquitectura.md 3.1.
// For each EX operand, picks the newest producer of that register:
//   10 = EX/MEM result (not for loads: their data is not ready in MEM)
//   01 = MEM/WB wb_data
//   00 = value read from the register file in ID
// x0 is never forwarded. rs1/rs2 are the decoder's effective registers
// (0 when unused), so unused fields never trigger forwarding.

module forward_unit (
  input  wire [4:0] id_ex_rs1,
  input  wire [4:0] id_ex_rs2,
  input  wire [4:0] ex_mem_rd,
  input  wire       ex_mem_reg_write,
  input  wire       ex_mem_mem_read,
  input  wire [4:0] mem_wb_rd,
  input  wire       mem_wb_reg_write,
  output reg  [1:0] fwd_a,
  output reg  [1:0] fwd_b
);

  localparam [1:0] FWD_RF  = 2'b00;
  localparam [1:0] FWD_WB  = 2'b01;
  localparam [1:0] FWD_MEM = 2'b10;

  wire mem_ok = ex_mem_reg_write && !ex_mem_mem_read && (ex_mem_rd != 5'd0);
  wire wb_ok  = mem_wb_reg_write && (mem_wb_rd != 5'd0);

  always @(*) begin
    fwd_a = FWD_RF;
    fwd_b = FWD_RF;
    if (mem_ok && ex_mem_rd == id_ex_rs1)
      fwd_a = FWD_MEM;
    else if (wb_ok && mem_wb_rd == id_ex_rs1)
      fwd_a = FWD_WB;
    if (mem_ok && ex_mem_rd == id_ex_rs2)
      fwd_b = FWD_MEM;
    else if (wb_ok && mem_wb_rd == id_ex_rs2)
      fwd_b = FWD_WB;
  end

endmodule

`default_nettype wire
