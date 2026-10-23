`timescale 1ns/1ps
`default_nettype none

// System: UART + Debug Unit + core + memories, in one clock domain.
// Everything except the board-level clock (MMCM) and reset synchronizer,
// which live in basys3_top, so testbenches simulate this module with a
// plain clock (docs/arquitectura.md 1.1, SPEC section 4).
// dmem port A belongs to the core, except while the Debug Unit clears it
// (the core is held in reset then).

module system_top #(
  parameter integer CLK_FREQ_HZ       = 100000000,
  parameter integer BAUD              = 115200,
  parameter integer IMEM_ADDR_W       = 10,
  parameter integer DMEM_ADDR_W       = 10,
  parameter         IMEM_INIT_FILE    = "",
  parameter integer IMEM_INIT_LEN     = 0,
  parameter integer MAX_CYCLES        = 1000000,
  parameter integer RX_TIMEOUT_CYCLES = CLK_FREQ_HZ / 100    // 10 ms
)(
  input  wire       clk,
  input  wire       rst,
  input  wire       uart_rxd,
  output wire       uart_txd,
  output wire       running,
  output wire       halting,
  output wire       halted,
  output wire [2:0] halt_reason
);

  // ---------------- UART ----------------
  wire       tx_start, tx_busy, rx_valid, rx_ferr;
  wire [7:0] tx_data, rx_data;

  uart #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) u_uart (
    .clk(clk), .rst(rst),
    .tx_start(tx_start), .tx_data(tx_data), .tx_busy(tx_busy), .txd(uart_txd),
    .rxd(uart_rxd), .rx_data(rx_data), .rx_valid(rx_valid), .rx_ferr(rx_ferr)
  );

  // ---------------- Debug Unit ----------------
  wire                   core_rst, core_en;
  wire [IMEM_ADDR_W:0]   imem_limit;
  wire [31:0]            cycle_cnt;
  wire [511:0]           dbg_core_vec;
  wire [4:0]             dbg_reg_addr;
  wire [31:0]            dbg_reg_data;
  wire                   imem_we;
  wire [IMEM_ADDR_W-1:0] imem_waddr;
  wire [31:0]            imem_wdata;
  wire                   dmem_clr;
  wire [DMEM_ADDR_W-1:0] dmem_clr_addr;
  wire [DMEM_ADDR_W-1:0] dmem_b_addr;
  wire [31:0]            dmem_b_rdata;

  wire                   core_dmem_en;
  wire [3:0]             core_dmem_we;
  wire [DMEM_ADDR_W-1:0] core_dmem_addr;
  wire [31:0]            core_dmem_wdata;
  wire [31:0]            dmem_a_rdata;
  wire [IMEM_ADDR_W-1:0] imem_raddr;
  wire [31:0]            imem_rdata;

  debug_unit #(
    .IMEM_ADDR_W(IMEM_ADDR_W), .DMEM_ADDR_W(DMEM_ADDR_W),
    .IMEM_INIT_LEN(IMEM_INIT_LEN), .RX_TIMEOUT_CYCLES(RX_TIMEOUT_CYCLES)
  ) u_dbg (
    .clk(clk), .rst(rst),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ferr(rx_ferr),
    .tx_start(tx_start), .tx_data(tx_data), .tx_busy(tx_busy),
    .core_rst(core_rst), .core_en(core_en), .imem_limit(imem_limit),
    .halted(halted), .halting(halting), .halt_reason(halt_reason),
    .cycle_cnt(cycle_cnt), .dbg_core_vec(dbg_core_vec),
    .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
    .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
    .dmem_clr(dmem_clr), .dmem_clr_addr(dmem_clr_addr),
    .cpu_dmem_we(core_dmem_we), .cpu_dmem_addr(core_dmem_addr),
    .dmem_b_addr(dmem_b_addr), .dmem_b_rdata(dmem_b_rdata),
    .running(running)
  );

  // ---------------- Core ----------------
  cpu_core #(
    .IMEM_ADDR_W(IMEM_ADDR_W), .DMEM_ADDR_W(DMEM_ADDR_W), .MAX_CYCLES(MAX_CYCLES)
  ) u_core (
    .clk(clk), .rst(core_rst), .en(core_en), .imem_limit(imem_limit),
    .imem_addr(imem_raddr), .imem_rdata(imem_rdata),
    .dmem_en(core_dmem_en), .dmem_we(core_dmem_we), .dmem_addr(core_dmem_addr),
    .dmem_wdata(core_dmem_wdata), .dmem_rdata(dmem_a_rdata),
    .halting(halting), .halted(halted), .halt_reason(halt_reason),
    .cycle_cnt(cycle_cnt),
    .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data),
    .dbg_core_vec(dbg_core_vec)
  );

  // ---------------- Memories ----------------
  imem #(.ADDR_W(IMEM_ADDR_W), .INIT_FILE(IMEM_INIT_FILE)) u_imem (
    .clk(clk), .we(imem_we), .waddr(imem_waddr), .wdata(imem_wdata),
    .raddr(imem_raddr), .rdata(imem_rdata)
  );

  dmem #(.ADDR_W(DMEM_ADDR_W)) u_dmem (
    .clk(clk),
    .a_en(dmem_clr ? 1'b1 : core_dmem_en),
    .a_we(dmem_clr ? 4'b1111 : core_dmem_we),
    .a_addr(dmem_clr ? dmem_clr_addr : core_dmem_addr),
    .a_wdata(dmem_clr ? 32'd0 : core_dmem_wdata),
    .a_rdata(dmem_a_rdata),
    .b_addr(dmem_b_addr), .b_rdata(dmem_b_rdata)
  );

endmodule

`default_nettype wire
