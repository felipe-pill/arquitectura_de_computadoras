`timescale 1ns/1ps
`default_nettype none

// Board top for the Basys 3: MMCM (clock generation), reset synchronizer,
// pins and LEDs around system_top. It is the only module that uses Xilinx
// primitives, so no testbench instantiates it (SPEC section 4).
// clk_sys = BOARD_CLK_HZ * MMCM_MULT / (MMCM_DIVCLK * MMCM_OUT_DIV), with the
// VCO (BOARD_CLK_HZ * MMCM_MULT / MMCM_DIVCLK) in 600-1200 MHz (-1 grade).
// Default: 100 * 17 / (2 * 9) = 94.444 MHz (VCO 850 MHz), the highest
// frequency that met timing in the phase 7 sweep (docs/timing.md).

module basys3_top #(
  parameter integer BOARD_CLK_HZ = 100000000,
  parameter integer MMCM_MULT    = 17,       // CLKFBOUT_MULT_F, 2-64
  parameter integer MMCM_DIVCLK  = 2,        // DIVCLK_DIVIDE, 1-106
  parameter integer MMCM_OUT_DIV = 9,        // CLKOUT0_DIVIDE_F, 1-128
  parameter integer BAUD         = 115200,
  parameter integer LED_W        = 16
)(
  input  wire             clk100mhz,
  input  wire             btn_reset,
  input  wire             uart_rxd,
  output wire             uart_txd,
  output wire [LED_W-1:0] led
);

  localparam integer CLK_FREQ_HZ =
    BOARD_CLK_HZ * 1.0 * MMCM_MULT / (MMCM_DIVCLK * MMCM_OUT_DIV);
  localparam real    CLKIN_PERIOD_NS = 1.0e9 / BOARD_CLK_HZ;
  localparam integer HALT_REASON_W   = 3;

  // ---------------- Clock ----------------
  // CLKFBOUT goes back through a BUFG so the MMCM compensates the global
  // clock buffer delay (clk_sys edges line up with the input clock).
  wire clk_mmcm, clk_fb_mmcm, clk_fb, clk_sys, mmcm_locked;

  MMCME2_BASE #(
    .CLKIN1_PERIOD   (CLKIN_PERIOD_NS),
    .CLKFBOUT_MULT_F (MMCM_MULT),
    .DIVCLK_DIVIDE   (MMCM_DIVCLK),
    .CLKOUT0_DIVIDE_F(MMCM_OUT_DIV)
  ) u_mmcm (
    .CLKIN1   (clk100mhz),
    .CLKFBIN  (clk_fb),
    .CLKFBOUT (clk_fb_mmcm),
    .CLKFBOUTB(),
    .CLKOUT0  (clk_mmcm),
    .CLKOUT0B (),
    .CLKOUT1  (), .CLKOUT1B(),
    .CLKOUT2  (), .CLKOUT2B(),
    .CLKOUT3  (), .CLKOUT3B(),
    .CLKOUT4  (), .CLKOUT5 (), .CLKOUT6(),
    .LOCKED   (mmcm_locked),
    .PWRDWN   (1'b0),
    .RST      (1'b0)
  );

  BUFG u_bufg_fb  (.I(clk_fb_mmcm), .O(clk_fb));
  BUFG u_bufg_sys (.I(clk_mmcm),    .O(clk_sys));

  // ---------------- Reset sync ----------------
  // 2-FF synchronizer for the async button and the MMCM lock; starts
  // asserted so the design also resets at power-up. Everything below uses
  // rst as a synchronous reset.
  (* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync = 2'b11;
  always @(posedge clk_sys) begin
    rst_sync <= {rst_sync[0], btn_reset | ~mmcm_locked};
  end
  wire rst = rst_sync[1];

  // ---------------- System ----------------
  wire                     running, halting, halted;
  wire [HALT_REASON_W-1:0] halt_reason;

  system_top #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD)) u_sys (
    .clk(clk_sys), .rst(rst),
    .uart_rxd(uart_rxd), .uart_txd(uart_txd),
    .running(running), .halting(halting), .halted(halted),
    .halt_reason(halt_reason)
  );

  assign led = {{(LED_W-HALT_REASON_W-3){1'b0}}, halt_reason, halted, halting, running};

endmodule

`default_nettype wire
