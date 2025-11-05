`timescale 1ns/1ps
`default_nettype none

module basys3_uart_alu (
  input  wire clk100mhz,
  input  wire btn_reset,   // ACTIVE-HIGH reset
  input  wire uart_rxd,
  output wire uart_txd
);

  // ---------------- Reset sync ----------------
  reg [1:0] rst_sync;
  always @(posedge clk100mhz or posedge btn_reset) begin
    if (btn_reset) rst_sync <= 2'b11;
    else           rst_sync <= {rst_sync[0], 1'b0};
  end
  wire rst = rst_sync[1];

  // ---------------- UART ----------------
  localparam integer CLK_FREQ_HZ = 100_000_000;
  localparam integer BAUD        = 115200;

  reg        tx_start;
  reg  [7:0] tx_data;
  wire       tx_busy;
  wire       txd;

  wire [7:0] rx_data;
  wire       rx_valid;
  wire       rx_ferr;

  uart #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .BAUD(BAUD)
  ) u_uart (
    .clk     (clk100mhz),
    .rst     (rst),
    .tx_start(tx_start),
    .tx_data (tx_data),
    .tx_busy (tx_busy),
    .txd     (txd),
    .rxd     (uart_rxd),
    .rx_data (rx_data),
    .rx_valid(rx_valid),
    .rx_ferr (rx_ferr)
  );

  assign uart_txd = txd;

  // ---------------- ALU ----------------
  reg        e1, e2, e3;
  reg  [7:0] data_bus;

  wire [7:0] alu_result;
  wire       alu_zero, alu_neg, alu_carry, alu_overflow;

  myALU u_alu (
    .clk      (clk100mhz),
    .reset    (rst),
    .e1       (e1),
    .e2       (e2),
    .e3       (e3),
    .data     (data_bus),
    .result   (alu_result),
    .zero     (alu_zero),
    .carry    (alu_carry),
    .overflow (alu_overflow),
    .neg      (alu_neg)
  );

  wire [7:0] flags_byte = {4'b0000, alu_overflow, alu_carry, alu_neg, alu_zero};

  // ---------------- Protocol ----------------
  // RX: 0xAA, OP, A, B
  // TX: 0x55, RESULT, FLAGS
  localparam [7:0] HDR_IN  = 8'hAA;
  localparam [7:0] HDR_OUT = 8'h55;

  reg [7:0] op_reg, a_reg, b_reg;

  // FSM states
  localparam [4:0]
    S_IDLE         = 5'd0,
    S_GET_OP       = 5'd1,
    S_GET_A        = 5'd2,
    S_GET_B        = 5'd3,
    S_LOAD_A       = 5'd4,
    S_LOAD_B       = 5'd5,
    S_LOAD_O       = 5'd6,
    // send header (three sub-states)
    S_SH_LOAD      = 5'd7,
    S_SH_WAITBUSY  = 5'd8,
    S_SH_WAITIDLE  = 5'd9,
    // send result
    S_SR_LOAD      = 5'd10,
    S_SR_WAITBUSY  = 5'd11,
    S_SR_WAITIDLE  = 5'd12,
    // send flags
    S_SF_LOAD      = 5'd13,
    S_SF_WAITBUSY  = 5'd14,
    S_SF_WAITIDLE  = 5'd15;

  reg [4:0] st;

  always @(posedge clk100mhz or posedge rst) begin
    if (rst) begin
      st       <= S_IDLE;
      op_reg   <= 8'h00;
      a_reg    <= 8'h00;
      b_reg    <= 8'h00;
      data_bus <= 8'h00;
      e1       <= 1'b0;
      e2       <= 1'b0;
      e3       <= 1'b0;
      tx_start <= 1'b0;
      tx_data  <= 8'h00;
    end else begin
      // defaults each cycle
      e1 <= 1'b0; e2 <= 1'b0; e3 <= 1'b0;
      tx_start <= 1'b0;

      case (st)
        // --- receive packet ---
        S_IDLE: begin
          if (rx_valid && !rx_ferr && rx_data == HDR_IN) st <= S_GET_OP;
        end

        S_GET_OP: if (rx_valid && !rx_ferr) begin
          if (rx_data == HDR_IN) st <= S_GET_OP;  // resync
          else begin op_reg <= rx_data; st <= S_GET_A; end
        end

        S_GET_A: if (rx_valid && !rx_ferr) begin
          if (rx_data == HDR_IN) st <= S_GET_OP;
          else begin a_reg <= rx_data; st <= S_GET_B; end
        end

        S_GET_B: if (rx_valid && !rx_ferr) begin
          if (rx_data == HDR_IN) st <= S_GET_OP;
          else begin b_reg <= rx_data; st <= S_LOAD_A; end
        end

        // --- load into ALU (one-cycle strobes) ---
        S_LOAD_A: begin data_bus <= a_reg; e1 <= 1'b1; st <= S_LOAD_B; end
        S_LOAD_B: begin data_bus <= b_reg; e2 <= 1'b1; st <= S_LOAD_O; end
        S_LOAD_O: begin data_bus <= op_reg; e3 <= 1'b1; st <= S_SH_LOAD; end

        // --- send header byte 0x55 ---
        S_SH_LOAD:     begin if (!tx_busy) begin tx_data <= HDR_OUT; tx_start <= 1'b1; st <= S_SH_WAITBUSY; end end
        S_SH_WAITBUSY: begin if ( tx_busy) begin               /*drop*/     st <= S_SH_WAITIDLE; end end
        S_SH_WAITIDLE: begin if (!tx_busy) begin                               st <= S_SR_LOAD;    end end

        // --- send result byte ---
        S_SR_LOAD:     begin if (!tx_busy) begin tx_data <= alu_result; tx_start <= 1'b1; st <= S_SR_WAITBUSY; end end
        S_SR_WAITBUSY: begin if ( tx_busy) begin                                   st <= S_SR_WAITIDLE; end end
        S_SR_WAITIDLE: begin if (!tx_busy) begin                                   st <= S_SF_LOAD;     end end

        // --- send flags byte ---
        S_SF_LOAD:     begin if (!tx_busy) begin tx_data <= flags_byte; tx_start <= 1'b1; st <= S_SF_WAITBUSY; end end
        S_SF_WAITBUSY: begin if ( tx_busy) begin                                   st <= S_SF_WAITIDLE; end end
        S_SF_WAITIDLE: begin if (!tx_busy) begin                                   st <= S_IDLE;        end end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule

`default_nettype wire
