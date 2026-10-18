`timescale 1ns/1ps
`default_nettype none

// Self-checking testbench for basys3_uart_alu (packet level, real 100 MHz clock).
// The testbench plays the PC: it drives uart_rxd and decodes uart_txd with its
// own bit-timed UART model at exactly BAUD, so a wrong baud divider shows up.
//
// Protocol spec:
//   PC -> FPGA : 0xAA, OP, A, B          (A and B may take any value, 0xAA too)
//   FPGA -> PC : 0x55, RESULT, FLAGS     FLAGS = {0000, overflow, carry, neg, zero}
//   A 0xAA in the OP slot restarts the packet; bytes outside a packet are ignored.
// ALU spec: see TP1 (ADD/SUB carry = carry-out, SUB carry 1 = no borrow).

module tb_basys3_uart_alu;

  localparam integer CLK_PERIOD   = 10;            // 100 MHz
  localparam integer BAUD         = 115200;
  localparam real    BIT_NS       = 1.0e9 / BAUD;
  localparam real    BAUD_TOL     = 0.02;          // max bit-period error accepted
  localparam integer FRAME_BITS   = 10;            // start + 8 data + stop
  localparam integer REPLY_BYTES  = 3;
  localparam integer TIMEOUT_NS   = 2_000_000;     // ~20 byte times
  localparam integer FIFO_DEPTH   = 64;
  localparam integer N_RANDOM     = 16;

  localparam integer DATA_WIDTH   = 8;
  localparam integer OPCODE_WIDTH = 6;
  localparam integer SHAMT_WIDTH  = $clog2(DATA_WIDTH);

  localparam [7:0] HDR_IN  = 8'hAA;
  localparam [7:0] HDR_OUT = 8'h55;

  localparam [OPCODE_WIDTH-1:0] OP_ADD = 6'b100000;
  localparam [OPCODE_WIDTH-1:0] OP_SUB = 6'b100010;
  localparam [OPCODE_WIDTH-1:0] OP_AND = 6'b100100;
  localparam [OPCODE_WIDTH-1:0] OP_OR  = 6'b100101;
  localparam [OPCODE_WIDTH-1:0] OP_XOR = 6'b100110;
  localparam [OPCODE_WIDTH-1:0] OP_NOR = 6'b100111;
  localparam [OPCODE_WIDTH-1:0] OP_SRL = 6'b000010;
  localparam [OPCODE_WIDTH-1:0] OP_SRA = 6'b000011;

  reg  clk       = 1'b0;
  reg  btn_reset = 1'b1;
  reg  uart_rxd  = 1'b1;   // idle high
  wire uart_txd;

  always #(CLK_PERIOD/2) clk = ~clk;

  basys3_uart_alu dut (
    .clk100mhz(clk),
    .btn_reset(btn_reset),
    .uart_rxd (uart_rxd),
    .uart_txd (uart_txd)
  );

  integer errors = 0;
  integer checks = 0;

  // ---------------- PC -> FPGA: bit-timed UART transmitter ----------------
  task send_byte;
    input [7:0] b;
    integer j;
    begin
      uart_rxd = 1'b0;                       // start bit
      #(BIT_NS);
      for (j = 0; j < 8; j = j + 1) begin    // LSB first
        uart_rxd = b[j];
        #(BIT_NS);
      end
      uart_rxd = 1'b1;                       // stop bit
      #(BIT_NS);
    end
  endtask

  // ---------------- FPGA -> PC: bit-timed UART receiver ----------------
  reg [7:0] rx_fifo [0:FIFO_DEPTH-1];
  integer   rx_count = 0;

  always begin : host_rx
    reg [7:0] b;
    integer   j;
    @(negedge uart_txd);
    #(BIT_NS/2);                             // middle of start bit
    if (uart_txd === 1'b0) begin
      for (j = 0; j < 8; j = j + 1) begin
        #(BIT_NS);
        b[j] = uart_txd;
      end
      #(BIT_NS);
      if (uart_txd !== 1'b1) begin
        $display("[%0t] FAIL: framing error on uart_txd, byte=0x%02h  TEST FAILED", $time, b);
        errors = errors + 1;
      end
      rx_fifo[rx_count % FIFO_DEPTH] = b;
      rx_count = rx_count + 1;
    end
  end

  // Baud check: in 0x55 every low pulse (start bit included) is one bit long
  realtime t_fall = 0, low_width = 0, hdr_low_width = 0;
  always @(negedge uart_txd) t_fall = $realtime;
  always @(posedge uart_txd) low_width = $realtime - t_fall;
  always @(rx_count) if (rx_fifo[(rx_count-1) % FIFO_DEPTH] == HDR_OUT) hdr_low_width = low_width;

  // ---------------- ALU reference model ----------------
  reg [DATA_WIDTH-1:0] exp_result;
  reg                  exp_carry, exp_overflow;
  reg [DATA_WIDTH:0]   wide;

  task model;
    input [OPCODE_WIDTH-1:0] op;
    input [DATA_WIDTH-1:0]   a, b;
    begin
      exp_carry    = 1'b0;
      exp_overflow = 1'b0;
      case (op)
        OP_ADD: begin
          wide         = a + b;
          exp_result   = wide[DATA_WIDTH-1:0];
          exp_carry    = wide[DATA_WIDTH];
          exp_overflow = ($signed(a) + $signed(b) > (2**(DATA_WIDTH-1)) - 1) ||
                         ($signed(a) + $signed(b) < -(2**(DATA_WIDTH-1)));
        end
        OP_SUB: begin
          exp_result   = a - b;
          exp_carry    = (a >= b);
          exp_overflow = ($signed(a) - $signed(b) > (2**(DATA_WIDTH-1)) - 1) ||
                         ($signed(a) - $signed(b) < -(2**(DATA_WIDTH-1)));
        end
        OP_AND: exp_result = a & b;
        OP_OR:  exp_result = a | b;
        OP_XOR: exp_result = a ^ b;
        OP_NOR: exp_result = ~(a | b);
        OP_SRL: exp_result = a >> b[SHAMT_WIDTH-1:0];
        OP_SRA: exp_result = $signed(a) >>> b[SHAMT_WIDTH-1:0];
        default: exp_result = {DATA_WIDTH{1'b0}};
      endcase
    end
  endtask

  // ---------------- Helpers ----------------
  task wait_bytes;   // wait until rx_count reaches n (or timeout), then one more frame
    input integer n;
    integer waited;
    begin
      waited = 0;
      while (rx_count < n && waited < TIMEOUT_NS) begin
        #(BIT_NS);
        waited = waited + BIT_NS;
      end
      #(FRAME_BITS * BIT_NS);                // catch any unexpected extra byte
    end
  endtask

  // Send one packet and check the reply. pre_hdr adds a leading 0xAA (resync test).
  task xfer;
    input [8*8-1:0]          tag;
    input                    pre_hdr;
    input [OPCODE_WIDTH-1:0] op;
    input [7:0]              a, b;
    integer base;
    reg [7:0] exp_flags, got_hdr, got_res, got_flags;
    begin
      base = rx_count;
      if (pre_hdr) send_byte(HDR_IN);
      send_byte(HDR_IN);
      send_byte({{(8-OPCODE_WIDTH){1'b0}}, op});
      send_byte(a);
      send_byte(b);
      wait_bytes(base + REPLY_BYTES);

      model(op, a, b);
      exp_flags = {4'b0000, exp_overflow, exp_carry,
                   exp_result[DATA_WIDTH-1], exp_result == {DATA_WIDTH{1'b0}}};
      checks = checks + 1;

      if (rx_count != base + REPLY_BYTES) begin
        $display("FAIL %0s: op=%06b A=%02h B=%02h  expected %0d reply bytes, got %0d  TEST FAILED",
                 tag, op, a, b, REPLY_BYTES, rx_count - base);
        errors = errors + 1;
      end else begin
        got_hdr   = rx_fifo[(base)     % FIFO_DEPTH];
        got_res   = rx_fifo[(base + 1) % FIFO_DEPTH];
        got_flags = rx_fifo[(base + 2) % FIFO_DEPTH];
        if (got_hdr === HDR_OUT && got_res === exp_result && got_flags === exp_flags)
          $display("PASS %0s: op=%06b A=%02h B=%02h  reply=%02h %02h %02h",
                   tag, op, a, b, got_hdr, got_res, got_flags);
        else begin
          $display("FAIL %0s: op=%06b A=%02h B=%02h  expected=%02h %02h %02h  actual=%02h %02h %02h  TEST FAILED",
                   tag, op, a, b, HDR_OUT, exp_result, exp_flags, got_hdr, got_res, got_flags);
          errors = errors + 1;
        end
      end
    end
  endtask

  // ---------------- Test sequence ----------------
  integer k, base;
  reg [OPCODE_WIDTH-1:0] ops [0:7];
  integer seed = 32'h0BAD_5EED;

  initial begin
    $timeformat(-9, 0, " ns", 0);
    ops[0] = OP_ADD; ops[1] = OP_SUB; ops[2] = OP_AND; ops[3] = OP_OR;
    ops[4] = OP_XOR; ops[5] = OP_NOR; ops[6] = OP_SRL; ops[7] = OP_SRA;

    repeat (10) @(posedge clk);
    btn_reset = 1'b0;
    #(FRAME_BITS * BIT_NS);

    // Same cases as py/uart_alu_pc.py
    xfer("add",    0, OP_ADD, 8'd15, 8'd27);
    xfer("or",     0, OP_OR,  8'hA5, 8'h0F);
    xfer("sub",    0, OP_SUB, 8'd10, 8'd20);
    xfer("sra",    0, OP_SRA, 8'h80, 8'd2);

    // Remaining opcodes and flag corners
    xfer("add_cv", 0, OP_ADD, 8'h80, 8'h80);
    xfer("and",    0, OP_AND, 8'hF0, 8'h3C);
    xfer("xor",    0, OP_XOR, 8'h0F, 8'h0F);
    xfer("nor",    0, OP_NOR, 8'h00, 8'h00);
    xfer("srl",    0, OP_SRL, 8'h80, 8'd7);

    // Operands equal to the header byte must be treated as data
    xfer("A=AA",   0, OP_ADD, 8'hAA, 8'h01);
    xfer("B=AA",   0, OP_SUB, 8'h01, 8'hAA);
    xfer("A=B=AA", 0, OP_XOR, 8'hAA, 8'hAA);

    // Repeated header restarts the packet: AA AA OP A B -> one reply
    xfer("resync", 1, OP_OR,  8'h12, 8'h34);

    // Bytes outside a packet are ignored
    base = rx_count;
    send_byte(8'h12);
    send_byte(8'h55);
    wait_bytes(base + 1);
    checks = checks + 1;
    if (rx_count == base)
      $display("PASS junk: bytes 12 55 sent outside a packet, expected 0 reply bytes, got 0");
    else begin
      $display("FAIL junk: bytes 12 55 sent outside a packet, expected 0 reply bytes, got %0d  TEST FAILED",
               rx_count - base);
      errors = errors + 1;
    end
    xfer("after_j", 0, OP_ADD, 8'd1, 8'd1);

    // Random packets
    for (k = 0; k < N_RANDOM; k = k + 1)
      xfer("random", 0, ops[$unsigned($random(seed)) % 8], $random(seed), $random(seed));

    // TX bit period measured on the 0x55 header vs. the PC's nominal BAUD
    checks = checks + 1;
    if (hdr_low_width > BIT_NS * (1.0 - BAUD_TOL) && hdr_low_width < BIT_NS * (1.0 + BAUD_TOL))
      $display("PASS baud: expected bit=%0.1f ns (+/-%0.0f%%), measured=%0.1f ns",
               BIT_NS, BAUD_TOL * 100, hdr_low_width);
    else begin
      $display("FAIL baud: expected bit=%0.1f ns (+/-%0.0f%%), measured=%0.1f ns  TEST FAILED",
               BIT_NS, BAUD_TOL * 100, hdr_low_width);
      errors = errors + 1;
    end

    $display("%0d checks, %0d failures", checks, errors);
    if (errors == 0)
      $display("ALL TESTS PASSED");
    else
      $fatal(1, "%0d check(s) failed", errors);
    $finish;
  end

endmodule

`default_nettype wire
