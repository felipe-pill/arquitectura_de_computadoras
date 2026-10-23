`timescale 1ns/1ps
`default_nettype none

// Response frame builder (docs/protocol.md 3.2, 3.3).
// On start, sends SOF(0x5A) RSP LEN_lo LEN_hi PAYLOAD[LEN] CHK through
// uart_tx, CHK = -(RSP + LEN_lo + LEN_hi + payload) mod 256.
// Payload bytes are pulled from a byte source: src_req pulses with src_idx,
// and the source answers with src_valid + src_byte (any latency).
// uart_tx handshake (TP2): pulse tx_start while !tx_busy, wait for tx_busy
// to rise (one cycle later), then wait for it to fall.
// done pulses after the last byte has been sent.

module dbg_tx_frame (
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  input  wire [7:0]  rsp,
  input  wire [15:0] len,
  output reg         src_req,
  output reg  [15:0] src_idx,
  input  wire        src_valid,
  input  wire [7:0]  src_byte,
  output reg         tx_start,
  output reg  [7:0]  tx_data,
  input  wire        tx_busy,
  output reg         done,
  output wire        busy
);

  localparam [7:0] SOF = 8'h5A;

  // what to send next
  localparam [2:0] P_SOF  = 3'd0;
  localparam [2:0] P_RSP  = 3'd1;
  localparam [2:0] P_LEN0 = 3'd2;
  localparam [2:0] P_LEN1 = 3'd3;
  localparam [2:0] P_PAY  = 3'd4;
  localparam [2:0] P_CHK  = 3'd5;

  localparam [2:0] S_IDLE  = 3'd0;
  localparam [2:0] S_NEXT  = 3'd1;  // pick the next byte
  localparam [2:0] S_FETCH = 3'd2;  // wait for the payload byte
  localparam [2:0] S_SEND  = 3'd3;  // start uart_tx
  localparam [2:0] S_WAITB = 3'd4;  // wait for tx_busy to rise
  localparam [2:0] S_WAITI = 3'd5;  // wait for tx_busy to fall

  reg [2:0]  st;
  reg [2:0]  phase;
  reg [7:0]  rsp_q;
  reg [15:0] len_q;
  reg [7:0]  sum;
  reg [7:0]  byte_q;

  assign busy = (st != S_IDLE);

  always @(posedge clk) begin
    if (rst) begin
      st       <= S_IDLE;
      phase    <= P_SOF;
      rsp_q    <= 8'd0;
      len_q    <= 16'd0;
      sum      <= 8'd0;
      byte_q   <= 8'd0;
      src_req  <= 1'b0;
      src_idx  <= 16'd0;
      tx_start <= 1'b0;
      tx_data  <= 8'd0;
      done     <= 1'b0;
    end else begin
      src_req  <= 1'b0;
      tx_start <= 1'b0;
      done     <= 1'b0;

      case (st)
        S_IDLE: begin
          if (start) begin
            rsp_q   <= rsp;
            len_q   <= len;
            sum     <= 8'd0;
            src_idx <= 16'd0;
            phase   <= P_SOF;
            st      <= S_NEXT;
          end
        end
        S_NEXT: begin
          case (phase)
            P_SOF:  begin byte_q <= SOF;          st <= S_SEND; end
            P_RSP:  begin byte_q <= rsp_q;        sum <= sum + rsp_q;        st <= S_SEND; end
            P_LEN0: begin byte_q <= len_q[7:0];   sum <= sum + len_q[7:0];   st <= S_SEND; end
            P_LEN1: begin byte_q <= len_q[15:8];  sum <= sum + len_q[15:8];  st <= S_SEND; end
            P_PAY: begin
              if (src_idx == len_q) begin
                phase <= P_CHK;            // payload done (or empty)
              end else begin
                src_req <= 1'b1;
                st      <= S_FETCH;
              end
            end
            default: begin byte_q <= 8'd0 - sum; st <= S_SEND; end  // P_CHK
          endcase
        end
        S_FETCH: begin
          if (src_valid) begin
            byte_q  <= src_byte;
            sum     <= sum + src_byte;
            src_idx <= src_idx + 16'd1;
            st      <= S_SEND;
          end
        end
        S_SEND: begin
          if (!tx_busy) begin
            tx_data  <= byte_q;
            tx_start <= 1'b1;
            st       <= S_WAITB;
          end
        end
        S_WAITB: begin
          if (tx_busy)
            st <= S_WAITI;
        end
        S_WAITI: begin
          if (!tx_busy) begin
            if (phase == P_CHK) begin
              done <= 1'b1;
              st   <= S_IDLE;
            end else begin
              if (phase != P_PAY)
                phase <= phase + 3'd1;
              st <= S_NEXT;
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
