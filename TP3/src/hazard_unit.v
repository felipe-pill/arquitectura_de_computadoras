`timescale 1ns/1ps
`default_nettype none

// Load-use hazard detection (combinational, ID stage). docs/arquitectura.md 3.2.
// Stall one cycle when the instruction in ID reads the register that a load
// in EX is about to produce. id_rs1/id_rs2 are the decoder's effective
// registers (0 when unused), and loads to x0 never stall.

module hazard_unit (
  input  wire       if_id_valid,
  input  wire [4:0] id_rs1,
  input  wire [4:0] id_rs2,
  input  wire       id_ex_mem_read,
  input  wire [4:0] id_ex_rd,
  output wire       load_use
);

  assign load_use = if_id_valid && id_ex_mem_read && (id_ex_rd != 5'd0) &&
                    (id_ex_rd == id_rs1 || id_ex_rd == id_rs2);

endmodule

`default_nettype wire
