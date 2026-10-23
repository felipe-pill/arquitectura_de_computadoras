`timescale 1ns/1ps
`default_nettype none

// Debug Unit command FSM (docs/protocol.md 4, 5; docs/arquitectura.md 6).
// Commands: 0x01 LOAD, 0x02 RESET, 0x03 RUN, 0x04 STEP, 0x05 DUMP.
// - Only frames whose header arrives in S_IDLE are served; anything that
//   arrives while busy (including during RUN) is dropped.
// - Checks, in this order: checksum, known command, LEN, state. LOAD checks
//   LEN on its header, because it writes imem while the payload arrives.
// - LOAD and RESET end with the reset sequence (S_CLR_*): core held in
//   reset, dmem cleared word by word through port A, dmem_used = 0, core
//   released two cycles later. The response is sent after it.
// - RUN: core_en = 1 until halted, then a STATE response.
// - STEP: one-cycle core_en pulse, then a STATE response.
// - The board reset (rst) also runs the reset sequence.
// - dmem_used tracks the highest word the core writes (high-water mark).

module dbg_ctrl #(
  parameter integer IMEM_ADDR_W   = 10,
  parameter integer DMEM_ADDR_W   = 10,
  parameter integer IMEM_INIT_LEN = 0
)(
  input  wire                   clk,
  input  wire                   rst,
  // from dbg_rx_frame
  input  wire                   hdr_valid,
  input  wire [7:0]             cmd,
  input  wire [15:0]            len,
  input  wire                   pl_valid,
  input  wire [7:0]             pl_byte,
  input  wire                   frame_end,
  input  wire                   frame_ok,
  input  wire                   abort,
  // to dbg_tx_frame / dbg_state_src
  output reg                    tx_start,
  output reg  [7:0]             tx_rsp,
  output reg  [15:0]            tx_len,
  input  wire                   tx_done,
  output reg                    src_mode,
  output reg  [15:0]            short_data,
  // core control and status
  output reg                    core_rst,
  output wire                   core_en,
  input  wire                   halted,
  output reg  [IMEM_ADDR_W:0]   prog_len,
  output reg                    prog_valid,
  output reg  [DMEM_ADDR_W:0]   dmem_used,
  output reg                    running,
  // imem write port (LOAD)
  output reg                    imem_we,
  output reg  [IMEM_ADDR_W-1:0] imem_waddr,
  output reg  [31:0]            imem_wdata,
  // dmem clear (port A, core in reset) and snoop of the core's writes
  output reg                    dmem_clr,
  output reg  [DMEM_ADDR_W-1:0] dmem_clr_addr,
  input  wire [3:0]             cpu_dmem_we,
  input  wire [DMEM_ADDR_W-1:0] cpu_dmem_addr
);

  localparam integer IMEM_DEPTH = 1 << IMEM_ADDR_W;
  localparam integer DMEM_DEPTH = 1 << DMEM_ADDR_W;
  localparam integer STATE_BASE = 204;    // STATE length without dmem words

  localparam [7:0] CMD_LOAD  = 8'h01;
  localparam [7:0] CMD_RESET = 8'h02;
  localparam [7:0] CMD_RUN   = 8'h03;
  localparam [7:0] CMD_STEP  = 8'h04;
  localparam [7:0] CMD_DUMP  = 8'h05;
  localparam [7:0] RSP_OK    = 8'h80;    // RSP = CMD | 0x80

  localparam [7:0] ERR_CHECKSUM    = 8'hE1;
  localparam [7:0] ERR_UNKNOWN_CMD = 8'hE2;
  localparam [7:0] ERR_LENGTH      = 8'hE3;
  localparam [7:0] ERR_HALTED      = 8'hE4;
  localparam [7:0] ERR_NO_PROGRAM  = 8'hE5;

  localparam MODE_STATE = 1'b0;
  localparam MODE_SHORT = 1'b1;

  localparam [3:0] S_CLR_START = 4'd0;
  localparam [3:0] S_CLR       = 4'd1;
  localparam [3:0] S_CLR_HOLD  = 4'd2;
  localparam [3:0] S_IDLE      = 4'd3;
  localparam [3:0] S_WAIT_END  = 4'd4;
  localparam [3:0] S_LOAD      = 4'd5;
  localparam [3:0] S_RUN       = 4'd6;
  localparam [3:0] S_STEP      = 4'd7;
  localparam [3:0] S_STEP_LEN  = 4'd8;
  localparam [3:0] S_SEND      = 4'd9;
  localparam [3:0] S_SEND_WAIT = 4'd10;

  reg [3:0]             st;
  reg [7:0]             cur_cmd;
  reg                   pend;        // a response is waiting for the reset sequence
  reg                   step_pulse;
  reg [1:0]             hold_cnt;
  reg [IMEM_ADDR_W:0]   widx;        // words received by LOAD
  reg [1:0]             bcnt;        // bytes of the current word
  reg [23:0]            wbuf;        // first three bytes of the current word

  assign core_en = running | step_pulse;

  wire load_len_ok = (len != 16'd0) && (len[1:0] == 2'b00) && (len <= 4 * IMEM_DEPTH);
  wire [15:0] state_len = STATE_BASE + {dmem_used, 2'b00};

  wire                 cpu_writes = (cpu_dmem_we != 4'b0000);
  wire [DMEM_ADDR_W:0] cpu_word_p1 = {1'b0, cpu_dmem_addr} + 1'b1;

  always @(posedge clk) begin
    if (rst) begin
      st            <= S_CLR_START;
      cur_cmd       <= 8'd0;
      pend          <= 1'b0;
      step_pulse    <= 1'b0;
      hold_cnt      <= 2'd0;
      widx          <= 0;
      bcnt          <= 2'd0;
      wbuf          <= 24'd0;
      tx_start      <= 1'b0;
      tx_rsp        <= 8'd0;
      tx_len        <= 16'd0;
      src_mode      <= MODE_STATE;
      short_data    <= 16'd0;
      core_rst      <= 1'b1;
      prog_len      <= IMEM_INIT_LEN;
      prog_valid    <= (IMEM_INIT_LEN != 0);
      dmem_used     <= 0;
      running       <= 1'b0;
      imem_we       <= 1'b0;
      imem_waddr    <= 0;
      imem_wdata    <= 32'd0;
      dmem_clr      <= 1'b0;
      dmem_clr_addr <= 0;
    end else begin
      tx_start   <= 1'b0;
      step_pulse <= 1'b0;
      imem_we    <= 1'b0;

      // dmem high-water mark (cleared below by the reset sequence)
      if (cpu_writes && cpu_word_p1 > dmem_used)
        dmem_used <= cpu_word_p1;

      case (st)
        // ---------------- reset sequence ----------------
        S_CLR_START: begin
          core_rst      <= 1'b1;
          running       <= 1'b0;
          dmem_clr      <= 1'b1;
          dmem_clr_addr <= 0;
          dmem_used     <= 0;
          st            <= S_CLR;
        end
        S_CLR: begin
          dmem_clr_addr <= dmem_clr_addr + 1'b1;
          if (dmem_clr_addr == DMEM_DEPTH - 1) begin
            dmem_clr <= 1'b0;
            hold_cnt <= 2'd0;
            st       <= S_CLR_HOLD;
          end
        end
        S_CLR_HOLD: begin
          hold_cnt <= hold_cnt + 2'd1;
          if (hold_cnt == 2'd1) begin
            core_rst <= 1'b0;
            pend     <= 1'b0;
            st       <= pend ? S_SEND : S_IDLE;
          end
        end

        // ---------------- command decode ----------------
        S_IDLE: begin
          if (hdr_valid) begin
            cur_cmd <= cmd;
            if (cmd == CMD_LOAD && load_len_ok) begin
              core_rst   <= 1'b1;
              prog_valid <= 1'b0;
              prog_len   <= 0;
              widx       <= 0;
              bcnt       <= 2'd0;
              st         <= S_LOAD;
            end else begin
              st <= S_WAIT_END;
            end
          end
        end
        S_WAIT_END: begin
          if (abort) begin
            st <= S_IDLE;
          end else if (frame_end) begin
            // defaults: short error response with the command code
            src_mode   <= MODE_SHORT;
            short_data <= {8'd0, cur_cmd};
            tx_len     <= 16'd1;
            st         <= S_SEND;
            if (!frame_ok) begin
              tx_rsp <= ERR_CHECKSUM;
            end else if (cur_cmd == CMD_LOAD) begin
              tx_rsp <= ERR_LENGTH;           // valid LOADs never get here
            end else if (cur_cmd != CMD_RESET && cur_cmd != CMD_RUN &&
                         cur_cmd != CMD_STEP && cur_cmd != CMD_DUMP) begin
              tx_rsp <= ERR_UNKNOWN_CMD;
            end else if (len != 16'd0) begin
              tx_rsp <= ERR_LENGTH;
            end else if ((cur_cmd == CMD_RUN || cur_cmd == CMD_STEP) && !prog_valid) begin
              tx_rsp <= ERR_NO_PROGRAM;
            end else if ((cur_cmd == CMD_RUN || cur_cmd == CMD_STEP) && halted) begin
              tx_rsp <= ERR_HALTED;
            end else begin
              // accepted: the OK response carries no payload or a STATE
              tx_rsp   <= cur_cmd | RSP_OK;
              src_mode <= MODE_STATE;
              tx_len   <= 16'd0;
              case (cur_cmd)
                CMD_RESET: begin
                  pend <= 1'b1;
                  st   <= S_CLR_START;
                end
                CMD_RUN: begin
                  running <= 1'b1;
                  st      <= S_RUN;
                end
                CMD_STEP: begin
                  step_pulse <= 1'b1;
                  st         <= S_STEP;
                end
                default: begin                // DUMP
                  tx_len <= state_len;
                end
              endcase
            end
          end
        end

        // ---------------- LOAD payload ----------------
        S_LOAD: begin
          if (abort) begin
            pend <= 1'b0;                     // incomplete frame: no response
            st   <= S_CLR_START;
          end else if (pl_valid) begin
            bcnt <= bcnt + 2'd1;
            if (bcnt == 2'd3) begin
              imem_we    <= 1'b1;
              imem_waddr <= widx[IMEM_ADDR_W-1:0];
              imem_wdata <= {pl_byte, wbuf};  // little-endian word
              widx       <= widx + 1'b1;
            end else begin
              wbuf <= {pl_byte, wbuf[23:8]};
            end
          end else if (frame_end) begin
            pend <= 1'b1;
            if (frame_ok) begin
              prog_len   <= widx;
              prog_valid <= 1'b1;
              tx_rsp     <= CMD_LOAD | RSP_OK;
              src_mode   <= MODE_SHORT;
              short_data <= {{(15-IMEM_ADDR_W){1'b0}}, widx};
              tx_len     <= 16'd2;
            end else begin
              tx_rsp     <= ERR_CHECKSUM;
              src_mode   <= MODE_SHORT;
              short_data <= {8'd0, CMD_LOAD};
              tx_len     <= 16'd1;
            end
            st <= S_CLR_START;
          end
        end

        // ---------------- execution ----------------
        S_RUN: begin
          if (halted) begin
            running <= 1'b0;
            tx_len  <= state_len;
            st      <= S_SEND;
          end
        end
        S_STEP: begin
          // core_en = 1 during this cycle: the core takes its single
          // enabled edge at the end of it, and dmem_used follows a store
          // made by that edge at the same time
          st <= S_STEP_LEN;
        end
        S_STEP_LEN: begin
          tx_len <= state_len;
          st     <= S_SEND;
        end

        // ---------------- response ----------------
        S_SEND: begin
          tx_start <= 1'b1;
          st       <= S_SEND_WAIT;
        end
        S_SEND_WAIT: begin
          if (tx_done)
            st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
