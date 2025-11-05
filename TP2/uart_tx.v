`timescale 1ns/1ps
`default_nettype none

module uart_tx #(
  parameter integer DATA_BITS = 8
)(
  input  wire clk,
  input  wire rst,
  input  wire tick16,         // 16x tick from baudgen
  input  wire start,          // strobe: load and start transmission
  input  wire [DATA_BITS-1:0] data,
  output reg  tx,             // serial line (idle high)
  output reg  busy            // 1 while shifting frame
);
  // We step the FSM once per "bit period". Make a /16 sub-counter.
  reg [3:0] sub = 4'd0;       // 0..15
  wire bit_tick = tick16 && (sub == 4'd15);

  localparam [1:0] S_IDLE=0, S_START=1, S_DATA=2, S_STOP=3;
  reg [1:0] state = S_IDLE;

  reg [DATA_BITS-1:0] shreg = {DATA_BITS{1'b0}};
  reg [$clog2(DATA_BITS):0] bitcnt = 0;

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      tx     <= 1'b1;   // idle high
      busy   <= 1'b0;
      state  <= S_IDLE;
      sub    <= 4'd0;
      shreg  <= {DATA_BITS{1'b0}};
      bitcnt <= 0;
    end else begin
      // subcounter for 16x ticks
      if (tick16) sub <= sub + 4'd1;

      case (state)
        S_IDLE: begin
          tx   <= 1'b1;
          busy <= 1'b0;
          sub  <= 4'd0;
          if (start) begin
            busy   <= 1'b1;
            shreg  <= data;
            bitcnt <= 0;
            state  <= S_START;
            tx     <= 1'b0; // start bit immediately
          end
        end

        S_START: begin
          if (bit_tick) begin
            state <= S_DATA;
            tx    <= shreg[0];        // LSB first
          end
        end

        S_DATA: begin
          if (bit_tick) begin
            shreg <= {1'b0, shreg[DATA_BITS-1:1]};
            bitcnt <= bitcnt + 1'b1;
            if (bitcnt == DATA_BITS-1) begin
              state <= S_STOP;
              tx    <= 1'b1;          // stop bit
            end else begin
              tx    <= shreg[1];      // next bit after shift
            end
          end
        end

        S_STOP: begin
          if (bit_tick) begin
            state <= S_IDLE;          // 1 stop bit only
            tx    <= 1'b1;
            busy  <= 1'b0;
          end
        end
      endcase
    end
  end
endmodule

`default_nettype wire
