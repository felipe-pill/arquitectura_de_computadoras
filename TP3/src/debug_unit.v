`timescale 1ns/1ps
`default_nettype none

// Debug Unit: UART byte protocol (docs/protocol.md) on top of the TP2 UART.
// dbg_rx_frame parses requests, dbg_ctrl executes them, dbg_tx_frame sends
// the responses with payload bytes from dbg_state_src.
// Ports: docs/modulos.md section 4.

module debug_unit #(
  parameter integer IMEM_ADDR_W       = 10,
  parameter integer DMEM_ADDR_W       = 10,
  parameter integer IMEM_INIT_LEN     = 0,
  parameter integer RX_TIMEOUT_CYCLES = 1000000
)(
  input  wire                   clk,
  input  wire                   rst,
  // UART
  input  wire [7:0]             rx_data,
  input  wire                   rx_valid,
  input  wire                   rx_ferr,
  output wire                   tx_start,
  output wire [7:0]             tx_data,
  input  wire                   tx_busy,
  // core control
  output wire                   core_rst,
  output wire                   core_en,
  output wire [IMEM_ADDR_W:0]   imem_limit,
  // core status
  input  wire                   halted,
  input  wire                   halting,
  input  wire [2:0]             halt_reason,
  input  wire [31:0]            cycle_cnt,
  input  wire [511:0]           dbg_core_vec,
  output wire [4:0]             dbg_reg_addr,
  input  wire [31:0]            dbg_reg_data,
  // imem write port
  output wire                   imem_we,
  output wire [IMEM_ADDR_W-1:0] imem_waddr,
  output wire [31:0]            imem_wdata,
  // dmem
  output wire                   dmem_clr,
  output wire [DMEM_ADDR_W-1:0] dmem_clr_addr,
  input  wire [3:0]             cpu_dmem_we,
  input  wire [DMEM_ADDR_W-1:0] cpu_dmem_addr,
  output wire [DMEM_ADDR_W-1:0] dmem_b_addr,
  input  wire [31:0]            dmem_b_rdata,
  // status for LEDs
  output wire                   running
);

  // rx frame -> ctrl
  wire        hdr_valid, pl_valid, frame_end, frame_ok, abort;
  wire [7:0]  cmd, pl_byte;
  wire [15:0] len;

  // ctrl -> tx frame / byte source
  wire        frame_tx_start, frame_done;
  wire [7:0]  frame_rsp;
  wire [15:0] frame_len;
  wire        src_mode;
  wire [15:0] short_data;

  // tx frame <-> byte source
  wire        src_req, src_valid;
  wire [15:0] src_idx;
  wire [7:0]  src_byte;

  wire                 core_rst_q;
  wire                 prog_valid;
  wire [DMEM_ADDR_W:0] dmem_used;

  // A board reset also resets the core right away
  assign core_rst = rst | core_rst_q;

  dbg_rx_frame #(.TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)) u_rx (
    .clk(clk), .rst(rst),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ferr(rx_ferr),
    .hdr_valid(hdr_valid), .cmd(cmd), .len(len),
    .pl_valid(pl_valid), .pl_byte(pl_byte),
    .frame_end(frame_end), .frame_ok(frame_ok), .abort(abort)
  );

  dbg_ctrl #(
    .IMEM_ADDR_W(IMEM_ADDR_W), .DMEM_ADDR_W(DMEM_ADDR_W), .IMEM_INIT_LEN(IMEM_INIT_LEN)
  ) u_ctrl (
    .clk(clk), .rst(rst),
    .hdr_valid(hdr_valid), .cmd(cmd), .len(len),
    .pl_valid(pl_valid), .pl_byte(pl_byte),
    .frame_end(frame_end), .frame_ok(frame_ok), .abort(abort),
    .tx_start(frame_tx_start), .tx_rsp(frame_rsp), .tx_len(frame_len),
    .tx_done(frame_done), .src_mode(src_mode), .short_data(short_data),
    .core_rst(core_rst_q), .core_en(core_en), .halted(halted),
    .prog_len(imem_limit), .prog_valid(prog_valid), .dmem_used(dmem_used),
    .running(running),
    .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
    .dmem_clr(dmem_clr), .dmem_clr_addr(dmem_clr_addr),
    .cpu_dmem_we(cpu_dmem_we), .cpu_dmem_addr(cpu_dmem_addr)
  );

  // STATE status block (docs/protocol.md 6.1), little-endian bytes 0..11
  wire [95:0] status = {
    16'd0,                                              // 10..11 reserved
    {{(15-DMEM_ADDR_W){1'b0}}, dmem_used},              // 8..9   dmem_used
    cycle_cnt,                                          // 4..7
    {{(15-IMEM_ADDR_W){1'b0}}, imem_limit},             // 2..3   prog_len
    {5'd0, halt_reason},                                // 1
    {5'd0, prog_valid, halting, halted}                 // 0      flags
  };

  dbg_state_src #(.DMEM_ADDR_W(DMEM_ADDR_W)) u_src (
    .clk(clk), .rst(rst),
    .req(src_req), .idx(src_idx), .mode(src_mode), .short_data(short_data),
    .status(status), .core_vec(dbg_core_vec),
    .reg_addr(dbg_reg_addr), .reg_data(dbg_reg_data),
    .dmem_addr(dmem_b_addr), .dmem_data(dmem_b_rdata),
    .valid(src_valid), .data(src_byte)
  );

  dbg_tx_frame u_tx (
    .clk(clk), .rst(rst),
    .start(frame_tx_start), .rsp(frame_rsp), .len(frame_len),
    .src_req(src_req), .src_idx(src_idx),
    .src_valid(src_valid), .src_byte(src_byte),
    .tx_start(tx_start), .tx_data(tx_data), .tx_busy(tx_busy),
    .done(frame_done), .busy()
  );

endmodule

`default_nettype wire
