`timescale 1ns/1ps
`default_nettype none

module uart_rx #(
  parameter integer DATA_BITS = 8
)(
  input  wire clk,
  input  wire rst,
  input  wire tick16,         // 16x sampling tick
  input  wire rx,             // serial line (idle high)
  output reg  [DATA_BITS-1:0] data,
  output reg  data_valid,     // 1 for 1 clk when a byte is ready
  output reg  framing_error   // 1 if stop bit was not high
);
  localparam [1:0] S_IDLE=0, S_START=1, S_DATA=2, S_STOP=3;
  reg [1:0] state = S_IDLE;

  reg [3:0] sub = 4'd0; // 0..15 for mid-bit timing
  reg [$clog2(DATA_BITS):0] bitcnt = 0;
  reg [DATA_BITS-1:0] shreg = {DATA_BITS{1'b0}};

  // Simple 2FF synchronizer to clk domain (and mild glitch filter)
  reg rx_q1=1'b1, rx_q2=1'b1;
  always @(posedge clk) begin
    rx_q1 <= rx;
    rx_q2 <= rx_q1;
  end

  always @(posedge clk or posedge rst) begin
    if (rst) begin
      state         <= S_IDLE;
      sub           <= 4'd0;
      bitcnt        <= 0;
      shreg         <= {DATA_BITS{1'b0}};
      data          <= {DATA_BITS{1'b0}};
      data_valid    <= 1'b0;
      framing_error <= 1'b0;
    end else begin
      data_valid    <= 1'b0; // default
      if (tick16) begin
        case (state)
          S_IDLE: begin
            framing_error <= 1'b0;
            if (rx_q2 == 1'b0) begin      // look for falling edge to start bit
              state <= S_START;
              sub   <= 4'd0;
            end
          end

          S_START: begin
            sub <= sub + 4'd1;
            if (sub == 4'd7) begin        // ~half a bit later (center of start)
              if (rx_q2 == 1'b0) begin
                sub    <= 4'd0;
                bitcnt <= 0;
                state  <= S_DATA;         // confirmed start bit
              end else begin
                state <= S_IDLE;          // false start, go idle
              end
            end
          end

          S_DATA: begin
            sub <= sub + 4'd1;
            if (sub == 4'd15) begin       // sample in the middle of each bit
              sub         <= 4'd0;
              shreg       <= {rx_q2, shreg[DATA_BITS-1:1]}; // LSB first
              bitcnt      <= bitcnt + 1'b1;
              if (bitcnt == DATA_BITS-1) begin
                state <= S_STOP;
              end
            end
          end

          S_STOP: begin
            sub <= sub + 4'd1;
            if (sub == 4'd15) begin       // sample stop bit
              sub <= 4'd0;
              data <= shreg;
              data_valid <= 1'b1;
              framing_error <= (rx_q2 != 1'b1);
              state <= S_IDLE;
            end
          end
        endcase
      end
    end
  end
endmodule

`default_nettype wire
