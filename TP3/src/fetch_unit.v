`timescale 1ns/1ps
`default_nettype none

// Fetch unit: PC register, next-PC mux and fetch stop code (IF stage).
// docs/arquitectura.md 3.4 (priorities), 4.2 (imem addressed with next_pc),
// 5.1 (stop codes).
// next_pc priority: rst > !en > ex_redirect > halt_accept > halting/load_use
// (hold) > id_jal > pc + 4. imem_addr = next_pc word index, so imem's
// registered output holds the instruction at pc during IF.
// fetch_stop_code marks the instruction being fetched as a stop slot:
// TIMEOUT if the cycle limit was reached, else OOR if pc is past the loaded
// program (pc >= 4 * imem_limit), else 0.

module fetch_unit #(
  parameter integer IMEM_ADDR_W = 10
)(
  input  wire                   clk,
  input  wire                   rst,
  input  wire                   en,
  input  wire                   ex_redirect,
  input  wire [31:0]            ex_target,
  input  wire                   halt_accept,
  input  wire [31:0]            halt_pc,
  input  wire                   halting,
  input  wire                   load_use,
  input  wire                   id_jal,
  input  wire [31:0]            id_jal_target,
  input  wire                   timeout,
  input  wire [IMEM_ADDR_W:0]   imem_limit,
  output reg  [31:0]            pc,
  output wire [IMEM_ADDR_W-1:0] imem_addr,
  output wire [2:0]             fetch_stop_code
);

  localparam [2:0] STOP_NONE    = 3'd0;
  localparam [2:0] STOP_OOR     = 3'd3;
  localparam [2:0] STOP_TIMEOUT = 3'd4;

  reg [31:0] next_pc;

  always @(*) begin
    next_pc = pc + 32'd4;
    if (rst)
      next_pc = 32'd0;
    else if (!en)
      next_pc = pc;
    else if (ex_redirect)
      next_pc = ex_target;
    else if (halt_accept)
      next_pc = halt_pc;
    else if (halting || load_use)
      next_pc = pc;
    else if (id_jal)
      next_pc = id_jal_target;
  end

  always @(posedge clk) begin
    if (rst)
      pc <= 32'd0;
    else if (en)
      pc <= next_pc;
  end

  assign imem_addr = next_pc[IMEM_ADDR_W+1:2];

  wire past_end = (pc >= {{(31-IMEM_ADDR_W-2){1'b0}}, imem_limit, 2'b00});

  assign fetch_stop_code = timeout  ? STOP_TIMEOUT :
                           past_end ? STOP_OOR     : STOP_NONE;

endmodule

`default_nettype wire
