`timescale 1ns/1ps
`default_nettype none

// Byte source for response payloads (feeds dbg_tx_frame).
// mode = 0: STATE dump, byte idx of docs/protocol.md 6:
//     0..11    status block (status input, little-endian bytes)
//     12..75   dbg_core_vec (PC + pipeline registers)
//     76..203  x0..x31, read through the regfile debug port
//     204..    dmem words, read through dmem port B
// mode = 1: short payload (LOAD word count, error code): byte idx of
//     short_data, little-endian.
// Fixed latency: req at cycle t -> valid + data at t + 3 (one cycle to
// latch idx and drive the read addresses, one for the dmem BRAM read, one to
// register the selected byte). The core is frozen while a dump is sent.

module dbg_state_src #(
  parameter integer DMEM_ADDR_W = 10
)(
  input  wire                   clk,
  input  wire                   rst,
  input  wire                   req,
  input  wire [15:0]            idx,
  input  wire                   mode,
  input  wire [15:0]            short_data,
  input  wire [95:0]            status,
  input  wire [511:0]           core_vec,
  output wire [4:0]             reg_addr,
  input  wire [31:0]            reg_data,
  output wire [DMEM_ADDR_W-1:0] dmem_addr,
  input  wire [31:0]            dmem_data,
  output reg                    valid,
  output reg  [7:0]             data
);

  localparam integer OFF_CORE = 12;
  localparam integer OFF_REGS = 76;
  localparam integer OFF_DMEM = 204;

  reg [15:0] idx_q;
  reg [1:0]  wait_cnt;

  wire [15:0] reg_off  = idx_q - OFF_REGS;
  wire [15:0] dmem_off = idx_q - OFF_DMEM;
  wire [15:0] core_off = idx_q - OFF_CORE;

  assign reg_addr  = reg_off[6:2];
  assign dmem_addr = dmem_off[DMEM_ADDR_W+1:2];

  wire [31:0] reg_shifted  = reg_data >> {reg_off[1:0], 3'b000};
  wire [31:0] dmem_shifted = dmem_data >> {dmem_off[1:0], 3'b000};

  reg [7:0] sel;

  always @(*) begin
    sel = 8'd0;
    if (mode)
      sel = idx_q[0] ? short_data[15:8] : short_data[7:0];
    else if (idx_q < OFF_CORE)
      sel = status[idx_q[3:0]*8 +: 8];
    else if (idx_q < OFF_REGS)
      sel = core_vec[core_off[5:0]*8 +: 8];
    else if (idx_q < OFF_DMEM)
      sel = reg_shifted[7:0];
    else
      sel = dmem_shifted[7:0];
  end

  always @(posedge clk) begin
    if (rst) begin
      idx_q    <= 16'd0;
      wait_cnt <= 2'd0;
      valid    <= 1'b0;
      data     <= 8'd0;
    end else begin
      valid <= 1'b0;
      if (req) begin
        idx_q    <= idx;
        wait_cnt <= 2'd2;
      end else if (wait_cnt != 2'd0) begin
        wait_cnt <= wait_cnt - 2'd1;
        if (wait_cnt == 2'd1) begin
          valid <= 1'b1;
          data  <= sel;
        end
      end
    end
  end

endmodule

`default_nettype wire
