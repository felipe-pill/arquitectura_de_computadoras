`timescale 1ns/1ps
`default_nettype none

// ============================================================
// Baud generator: produces tick16 (16x baud) and baud_tick (1x)
// ============================================================
module uart_baudgen #(
  parameter integer CLK_FREQ_HZ = 100_000_000, // e.g., Basys-3 = 100 MHz
  parameter integer BAUD        = 115200
)(
  input  wire clk,
  input  wire rst,
  output reg  tick16,     // 16x baud tick
  output reg  baud_tick   // 1x baud tick (one per bit)
);
  localparam real    DIV16_R = CLK_FREQ_HZ / (BAUD * 16.0);
  localparam integer DIV16   = (DIV16_R < 1.0) ? 1 : integer'(DIV16_R);

  reg [$clog2(DIV16)-1:0] cnt16 = 0;
  reg [3:0]               sub    = 0;

  always @(posedge clk) begin
    if (rst) begin
      cnt16    <= 0;
      sub      <= 0;
      tick16   <= 1'b0;
      baud_tick<= 1'b0;
    end else begin
      tick16    <= 1'b0;
      baud_tick <= 1'b0;
      if (cnt16 == DIV16-1) begin
        cnt16 <= 0;
        tick16 <= 1'b1;
        if (sub == 4'd15) begin
          sub <= 0;
          baud_tick <= 1'b1;
        end else begin
          sub <= sub + 1'b1;
        end
      end else begin
        cnt16 <= cnt16 + 1'b1;
      end
    end
  end
endmodule

// ============================================================
// UART TX: 8N1
// Interface: tx_valid + tx_data -> tx_ready; line idles high
// ============================================================
module uart_tx #(
  parameter integer CLKS_PER_BIT_X16_UNUSED = 0 // not used here but kept for symmetry
)(
  input  wire clk,
  input  wire rst,
  // byte stream interface
  input  wire       tx_valid,
  input  wire [7:0] tx_data,
  output reg        tx_ready,
  // timing
  input  wire       baud_tick, // 1x tick
  // line
  output reg        txd
);
  localparam [2:0] S_IDLE=0, S_START=1, S_DATA=2, S_STOP=3;

  reg [2:0] state = S_IDLE;
  reg [2:0] bit_idx = 0;
  reg [7:0] shreg   = 8'h00;

  always @(posedge clk) begin
    if (rst) begin
      state   <= S_IDLE;
      txd     <= 1'b1; // idle high
      tx_ready<= 1'b1;
      bit_idx <= 0;
      shreg   <= 8'h00;
    end else begin
      case (state)
        S_IDLE: begin
          txd      <= 1'b1;
          tx_ready <= 1'b1;
          if (tx_valid) begin
            shreg   <= tx_data;
            bit_idx <= 0;
            tx_ready<= 1'b0;
            state   <= S_START;
          end
        end
        S_START: if (baud_tick) begin
          txd   <= 1'b0; // start bit
          state <= S_DATA;
        end
        S_DATA: if (baud_tick) begin
          txd <= shreg[0];
          shreg <= {1'b0, shreg[7:1]};
          if (bit_idx == 3'd7) begin
            state <= S_STOP;
          end
          bit_idx <= bit_idx + 1'b1;
        end
        S_STOP: if (baud_tick) begin
          txd      <= 1'b1; // stop bit
          tx_ready <= 1'b1;
          state    <= S_IDLE;
        end
      endcase
    end
  end
endmodule

// ============================================================
// UART RX: 8N1, 16x oversampling
// Interface: rx_ready consumes a valid byte; rx_valid flags availability
// ============================================================
module uart_rx #(
  parameter integer CLK_FREQ_HZ = 100_000_000,
  parameter integer BAUD        = 115200
)(
  input  wire clk,
  input  wire rst,
  // timing
  input  wire tick16, // 16x tick
  // line
  input  wire rxd,
  // byte stream interface
  output reg        rx_valid,
  output reg [7:0]  rx_data,
  input  wire       rx_ready,   // consumer handshake
  // status
  output reg        frame_err   // stop bit not high
);
  localparam [2:0] R_IDLE=0, R_START=1, R_DATA=2, R_STOP=3;

  reg [2:0] state   = R_IDLE;
  reg [3:0] sub     = 0;       // 0..15 sub-bit counter
  reg [2:0] bit_idx = 0;
  reg [7:0] shreg   = 8'h00;
  reg       rxd_sync1=1'b1, rxd_sync2=1'b1;

  // Synchronize RXD to clk
  always @(posedge clk) begin
    rxd_sync1 <= rxd;
    rxd_sync2 <= rxd_sync1;
  end

  // Clear rx_valid when consumed
  wire consume = rx_valid && rx_ready;

  always @(posedge clk) begin
    if (rst) begin
      state    <= R_IDLE;
      sub      <= 0;
      bit_idx  <= 0;
      shreg    <= 8'h00;
      rx_valid <= 1'b0;
      rx_data  <= 8'h00;
      frame_err<= 1'b0;
    end else begin
      if (consume) rx_valid <= 1'b0;

      case (state)
        R_IDLE: begin
          frame_err <= 1'b0;
          sub <= 0;
          bit_idx <= 0;
          if (tick16 && (rxd_sync2 == 1'b0)) begin
            // detect start edge -> wait half a bit to sample center of start
            state <= R_START;
            sub   <= 4'd8; // next sample in the middle
          end
        end

        R_START: if (tick16) begin
          if (sub != 0) begin
            sub <= sub - 1'b1;
          end else begin
            // sample center of start bit
            if (rxd_sync2 == 1'b0) begin
              state   <= R_DATA;
              sub     <= 4'd15; // next data sample after 16 ticks
              bit_idx <= 0;
            end else begin
              // false start
              state <= R_IDLE;
            end
          end
        end

        R_DATA: if (tick16) begin
          if (sub != 0) begin
            sub <= sub - 1'b1;
          end else begin
            // sample data bit center
            shreg <= {rxd_sync2, shreg[7:1]}; // LSB first
            sub   <= 4'd15;
            if (bit_idx == 3'd7) begin
              state <= R_STOP;
            end
            bit_idx <= bit_idx + 1'b1;
          end
        end

        R_STOP: if (tick16) begin
          if (sub != 0) begin
            sub <= sub - 1'b1;
          end else begin
            // sample stop bit center
            rx_data   <= shreg;
            rx_valid  <= 1'b1;
            frame_err <= (rxd_sync2 != 1'b1); // stop should be high
            state     <= R_IDLE;
          end
        end
      endcase
    end
  end
endmodule

// ============================================================
// Simple UART top: connects TX/RX + baudgen with valid/ready I/F
// ============================================================
module uart #(
  parameter integer CLK_FREQ_HZ = 100_000_000,
  parameter integer BAUD        = 115200
)(
  input  wire clk,
  input  wire rst,
  // serial lines
  input  wire rxd,
  output wire txd,
  // TX stream
  input  wire       tx_valid,
  input  wire [7:0] tx_data,
  output wire       tx_ready,
  // RX stream
  output wire       rx_valid,
  output wire [7:0] rx_data,
  input  wire       rx_ready,
  output wire       frame_err
);
  wire tick16, baud_tick;

  uart_baudgen #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .BAUD(BAUD)
  ) u_baud (
    .clk(clk), .rst(rst),
    .tick16(tick16),
    .baud_tick(baud_tick)
  );

  uart_tx u_tx (
    .clk(clk), .rst(rst),
    .tx_valid(tx_valid),
    .tx_data(tx_data),
    .tx_ready(tx_ready),
    .baud_tick(baud_tick),
    .txd(txd)
  );

  uart_rx #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .BAUD(BAUD)
  ) u_rx (
    .clk(clk), .rst(rst),
    .tick16(tick16),
    .rxd(rxd),
    .rx_valid(rx_valid),
    .rx_data(rx_data),
    .rx_ready(rx_ready),
    .frame_err(frame_err)
  );
endmodule

`default_nettype wire
