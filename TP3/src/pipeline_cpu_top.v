`timescale 1ns/1ps
`default_nettype none

module pipeline_cpu_top (
    input  wire clk,
    input  wire rst,
    input  wire uart_rx,   // unused for now
    output wire uart_tx    // idle for now
);

  localparam IMEM_DEPTH = 1024;
  localparam DMEM_DEPTH = 1024;

  reg [31:0] imem [0:IMEM_DEPTH-1];
  reg [31:0] dmem [0:DMEM_DEPTH-1];

  // Wires core <-> memories
  wire [31:0] imem_addr;
  wire [31:0] imem_rdata;

  wire [31:0] dmem_addr;
  wire [31:0] dmem_wdata;
  wire [31:0] dmem_rdata;
  wire        dmem_we;
  wire  [3:0] dmem_be;

  wire [31:0] dbg_if_id_pc;
  wire [31:0] dbg_if_id_instr;

  cpu_core u_core (
      .clk             (clk),
      .rst             (rst),
      .imem_addr       (imem_addr),
      .imem_rdata      (imem_rdata),
      .dmem_addr       (dmem_addr),
      .dmem_wdata      (dmem_wdata),
      .dmem_rdata      (dmem_rdata),
      .dmem_we         (dmem_we),
      .dmem_be         (dmem_be),
      .dbg_if_id_pc    (dbg_if_id_pc),
      .dbg_if_id_instr (dbg_if_id_instr)
  );

  // IMEM: word-addressed
  assign imem_rdata = imem[imem_addr[11:2]];

  // DMEM: simple word read/write
  assign dmem_rdata = dmem[dmem_addr[11:2]];

  always @(posedge clk) begin
    if (dmem_we) begin
      dmem[dmem_addr[11:2]] <= dmem_wdata;
    end
  end

  // Initialize memories (same program as antes)
  integer i;
  initial begin
    for (i = 0; i < IMEM_DEPTH; i = i + 1)
      imem[i] = 32'h00000013;
    for (i = 0; i < DMEM_DEPTH; i = i + 1)
      dmem[i] = 32'h0;

// 0: addi x1, x0, 5
imem[0]  = 32'h00500093;

// 1: addi x2, x0, 7
imem[1]  = 32'h00700113;

// 2: add  x3, x1, x2   ; EX and WB forwarding needed
imem[2]  = 32'h002081B3;

// 3: sw   x3, 0(x0)
imem[3]  = 32'h00302023;

// 4: lw   x4, 0(x0)
imem[4]  = 32'h00002203;

// 5: add  x5, x4, x3   ; load-use hazard → stall needed
imem[5]  = 32'h004182B3;

    
  end

  assign uart_tx = 1'b1;

endmodule

`default_nettype wire
