`timescale 1ns/1ps
`default_nettype none

// Request frame parser (docs/protocol.md 3.1, 3.3, 3.4).
// Frame: SOF(0xA5) CMD LEN_lo LEN_hi PAYLOAD[LEN] CHK.
// - hdr_valid pulses once CMD and LEN are known (cmd, len stay valid until
//   the next frame), so LOAD can consume the payload as it arrives.
// - pl_valid pulses with each payload byte (pl_byte).
// - frame_end pulses after CHK; frame_ok = the 8-bit sum of CMD..CHK is 0.
// - abort pulses when a frame in progress is dropped: no byte for
//   TIMEOUT_CYCLES, or a byte with a UART framing error. The parser then
//   goes back to hunting for SOF.

module dbg_rx_frame #(
  parameter integer TIMEOUT_CYCLES = 1000000
)(
  input  wire        clk,
  input  wire        rst,
  input  wire [7:0]  rx_data,
  input  wire        rx_valid,
  input  wire        rx_ferr,
  output reg         hdr_valid,
  output reg  [7:0]  cmd,
  output reg  [15:0] len,
  output reg         pl_valid,
  output reg  [7:0]  pl_byte,
  output reg         frame_end,
  output reg         frame_ok,
  output reg         abort
);

  localparam [7:0] SOF = 8'hA5;

  localparam [2:0] S_SOF  = 3'd0;
  localparam [2:0] S_CMD  = 3'd1;
  localparam [2:0] S_LEN0 = 3'd2;
  localparam [2:0] S_LEN1 = 3'd3;
  localparam [2:0] S_PAY  = 3'd4;
  localparam [2:0] S_CHK  = 3'd5;

  localparam integer IDLE_W = $clog2(TIMEOUT_CYCLES + 1);

  reg [2:0]        st;
  reg [7:0]        sum;
  reg [15:0]       cnt;
  reg [IDLE_W-1:0] idle;

  wire [7:0] sum_next = sum + rx_data;
  wire       timed_out = (st != S_SOF) && (idle >= TIMEOUT_CYCLES);

  always @(posedge clk) begin
    if (rst) begin
      st        <= S_SOF;
      sum       <= 8'd0;
      cnt       <= 16'd0;
      idle      <= {IDLE_W{1'b0}};
      hdr_valid <= 1'b0;
      cmd       <= 8'd0;
      len       <= 16'd0;
      pl_valid  <= 1'b0;
      pl_byte   <= 8'd0;
      frame_end <= 1'b0;
      frame_ok  <= 1'b0;
      abort     <= 1'b0;
    end else begin
      hdr_valid <= 1'b0;
      pl_valid  <= 1'b0;
      frame_end <= 1'b0;
      abort     <= 1'b0;

      if (rx_valid || st == S_SOF)
        idle <= {IDLE_W{1'b0}};
      else
        idle <= idle + 1'b1;

      if (timed_out) begin
        st    <= S_SOF;
        abort <= 1'b1;
      end else if (rx_valid && rx_ferr) begin
        st    <= S_SOF;
        abort <= (st != S_SOF);
      end else if (rx_valid) begin
        case (st)
          S_SOF: begin
            if (rx_data == SOF)
              st <= S_CMD;
          end
          S_CMD: begin
            cmd <= rx_data;
            sum <= rx_data;
            st  <= S_LEN0;
          end
          S_LEN0: begin
            len[7:0] <= rx_data;
            sum      <= sum_next;
            st       <= S_LEN1;
          end
          S_LEN1: begin
            len[15:8] <= rx_data;
            sum       <= sum_next;
            cnt       <= 16'd0;
            hdr_valid <= 1'b1;
            st        <= ({rx_data, len[7:0]} == 16'd0) ? S_CHK : S_PAY;
          end
          S_PAY: begin
            pl_byte  <= rx_data;
            pl_valid <= 1'b1;
            sum      <= sum_next;
            cnt      <= cnt + 16'd1;
            if (cnt == len - 16'd1)
              st <= S_CHK;
          end
          S_CHK: begin
            frame_end <= 1'b1;
            frame_ok  <= (sum_next == 8'd0);
            st        <= S_SOF;
          end
          default: st <= S_SOF;
        endcase
      end
    end
  end

endmodule

`default_nettype wire
