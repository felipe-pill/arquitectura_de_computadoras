`timescale 1ns/1ps
`default_nettype none

// System testbench: real serial frames into system_top (UART + Debug Unit +
// core + memories), checked byte by byte against docs/protocol.md.
//
// - The testbench drives uart_rxd bit by bit (8N1) and decodes uart_txd.
//   For simulation speed the UART runs at CLK_FREQ/32 baud (DIV = 2, 32
//   cycles per bit); the bit-level logic is the same as at 115200, which
//   TP2 and tb_uart_loopback cover.
// - Expected STATE payloads come from a reference core (a second cpu_core +
//   imem + dmem driven directly: one en pulse per STEP, en until halted for
//   RUN, reset + clear for RESET/LOAD). Every STATE response must match the
//   dump built from the reference core exactly. Final results of RUN are
//   also checked against the Python ISS (cpu_tests.hex).
// - Covered: every error code and the check order, LOAD (good, bad length,
//   bad checksum), RESET, RUN, STEP (whole programs step by step), DUMP,
//   a frame sent during RUN (dropped), inter-byte timeout and framing error
//   (frame dropped, parser recovers), TIMEOUT halt.

module tb_system_top;

  localparam integer CLK_PERIOD  = 10;
  localparam integer CLK_FREQ_HZ = 100000000;
  localparam integer BAUD        = 3125000;           // DIV = 2 -> 32 cycles/bit
  localparam integer BIT_NS      = 320;
  localparam integer IMEM_ADDR_W = 10;
  localparam integer DMEM_ADDR_W = 10;
  localparam integer DMEM_DEPTH  = 1 << DMEM_ADDR_W;
  localparam integer MAX_CYCLES  = 3000;              // = CPU_MAX_CYCLES in gen_vectors.py
  localparam integer RX_TIMEOUT  = 2000;              // cycles (a byte is 320)
  localparam integer MAX_WORDS   = 1 << 17;
  localparam integer MAX_TESTS   = 256;
  localparam integer MAX_PL      = 4400;
  localparam integer RSP_TIMEOUT = 400000;            // cycles to wait for a response
  localparam [31:0]  MAGIC       = 32'hC0DE0001;

  localparam [7:0] CMD_LOAD = 8'h01, CMD_RESET = 8'h02, CMD_RUN = 8'h03,
                   CMD_STEP = 8'h04, CMD_DUMP = 8'h05;
  localparam [7:0] ERR_CHECKSUM = 8'hE1, ERR_UNKNOWN_CMD = 8'hE2, ERR_LENGTH = 8'hE3,
                   ERR_HALTED = 8'hE4, ERR_NO_PROGRAM = 8'hE5;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // =====================================================================
  // DUT
  // =====================================================================
  reg  rst = 1'b1;
  reg  rxd = 1'b1;
  wire txd, running, halting, halted;
  wire [2:0] halt_reason;

  system_top #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD(BAUD),
    .IMEM_ADDR_W(IMEM_ADDR_W), .DMEM_ADDR_W(DMEM_ADDR_W),
    .MAX_CYCLES(MAX_CYCLES), .RX_TIMEOUT_CYCLES(RX_TIMEOUT)
  ) dut (
    .clk(clk), .rst(rst), .uart_rxd(rxd), .uart_txd(txd),
    .running(running), .halting(halting), .halted(halted), .halt_reason(halt_reason)
  );

  // =====================================================================
  // Reference core (same wiring as tb_cpu_core)
  // =====================================================================
  reg                    r_rst = 1'b1, r_en = 1'b0;
  reg  [IMEM_ADDR_W:0]   r_limit = 0;
  wire [IMEM_ADDR_W-1:0] r_imem_raddr;
  wire [31:0]            r_imem_rdata;
  reg                    r_imem_we = 1'b0;
  reg  [IMEM_ADDR_W-1:0] r_imem_waddr = 0;
  reg  [31:0]            r_imem_wdata = 32'd0;
  wire                   r_dmem_en;
  wire [3:0]             r_dmem_we;
  wire [DMEM_ADDR_W-1:0] r_dmem_addr;
  wire [31:0]            r_dmem_wdata, r_dmem_a_rdata, r_dmem_b_rdata;
  reg                    r_clr = 1'b0;
  reg  [DMEM_ADDR_W-1:0] r_clr_addr = 0, r_b_addr = 0;
  wire                   r_halting, r_halted;
  wire [2:0]             r_reason;
  wire [31:0]            r_cycles;
  reg  [4:0]             r_reg_addr = 5'd0;
  wire [31:0]            r_reg_data;
  wire [511:0]           r_vec;

  imem #(.ADDR_W(IMEM_ADDR_W)) r_imem (
    .clk(clk), .we(r_imem_we), .waddr(r_imem_waddr), .wdata(r_imem_wdata),
    .raddr(r_imem_raddr), .rdata(r_imem_rdata)
  );
  dmem #(.ADDR_W(DMEM_ADDR_W)) r_dmem (
    .clk(clk),
    .a_en(r_clr ? 1'b1 : r_dmem_en), .a_we(r_clr ? 4'b1111 : r_dmem_we),
    .a_addr(r_clr ? r_clr_addr : r_dmem_addr), .a_wdata(r_clr ? 32'd0 : r_dmem_wdata),
    .a_rdata(r_dmem_a_rdata), .b_addr(r_b_addr), .b_rdata(r_dmem_b_rdata)
  );
  cpu_core #(
    .IMEM_ADDR_W(IMEM_ADDR_W), .DMEM_ADDR_W(DMEM_ADDR_W), .MAX_CYCLES(MAX_CYCLES)
  ) r_core (
    .clk(clk), .rst(r_rst), .en(r_en), .imem_limit(r_limit),
    .imem_addr(r_imem_raddr), .imem_rdata(r_imem_rdata),
    .dmem_en(r_dmem_en), .dmem_we(r_dmem_we), .dmem_addr(r_dmem_addr),
    .dmem_wdata(r_dmem_wdata), .dmem_rdata(r_dmem_a_rdata),
    .halting(r_halting), .halted(r_halted), .halt_reason(r_reason),
    .cycle_cnt(r_cycles),
    .dbg_reg_addr(r_reg_addr), .dbg_reg_data(r_reg_data), .dbg_core_vec(r_vec)
  );

  integer r_hwm = 0;   // reference dmem high-water mark
  always @(posedge clk)
    if (!r_clr && r_dmem_we != 4'b0000 && r_dmem_addr + 1 > r_hwm)
      r_hwm = r_dmem_addr + 1;

  reg        tb_prog_valid = 1'b0;
  reg [15:0] tb_prog_len = 16'd0;

  // =====================================================================
  // Test stream (cpu_tests.hex) and the loaded program
  // =====================================================================
  reg [31:0] stream [0:MAX_WORDS-1];
  integer    test_off [0:MAX_TESTS-1];
  integer    n_tests, p, i, j, k, t;
  reg [31:0] w0, w1, w2, w3;
  reg [127:0] name;
  integer    prog_len;
  reg [31:0] prog [0:1023];
  reg [31:0] exp_pc, exp_cycles, exp_reason, exp_used;
  reg [31:0] exp_regs [0:31];
  reg [31:0] exp_dmem [0:DMEM_DEPTH-1];

  task get;
    output [31:0] w;
    begin w = stream[p]; p = p + 1; end
  endtask

  task index_tests;
    begin
      p = 0;
      get(w0);
      if (w0 !== MAGIC) $fatal(1, "cpu_tests.hex missing or bad magic");
      get(w0); n_tests = w0;
      get(w0);
      if (w0 != MAX_CYCLES) $fatal(1, "cpu_tests.hex was generated for another MAX_CYCLES");
      for (t = 0; t < n_tests; t = t + 1) begin
        test_off[t] = p;
        p = p + 4;                    // name
        get(w0); p = p + w0;          // program
        p = p + 3;                    // pc, cycles, reason
        get(w0); p = p + 32 + w0;     // dmem_used, regs, dmem words
      end
    end
  endtask

  // Load test `wanted` (name padded to 16 characters) into prog/exp_*
  task load_test;
    input [127:0] wanted;
    integer found;
    begin
      found = -1;
      for (t = 0; t < n_tests; t = t + 1) begin
        p = test_off[t];
        get(w0); get(w1); get(w2); get(w3);
        if ({w0, w1, w2, w3} == wanted) found = t;
      end
      if (found < 0) $fatal(1, "test %0s not found in cpu_tests.hex", wanted);
      p = test_off[found];
      get(w0); get(w1); get(w2); get(w3);
      name = {w0, w1, w2, w3};
      get(w0); prog_len = w0;
      for (i = 0; i < prog_len; i = i + 1) get(prog[i]);
      get(exp_pc); get(exp_cycles); get(exp_reason); get(exp_used);
      for (i = 0; i < 32; i = i + 1) get(exp_regs[i]);
      for (i = 0; i < DMEM_DEPTH; i = i + 1) exp_dmem[i] = 32'd0;
      for (i = 0; i < exp_used; i = i + 1) get(exp_dmem[i]);
    end
  endtask

  // =====================================================================
  // Serial transmitter (host -> FPGA) and receiver (FPGA -> host)
  // =====================================================================
  task send_byte;
    input [7:0] b;
    input       bad_stop;
    integer     n;
    begin
      rxd = 1'b0; #(BIT_NS);
      for (n = 0; n < 8; n = n + 1) begin rxd = b[n]; #(BIT_NS); end
      rxd = bad_stop ? 1'b0 : 1'b1; #(BIT_NS);
      rxd = 1'b1; #(BIT_NS);
    end
  endtask

  reg [7:0] tx_pl [0:MAX_PL-1];   // request payload

  task send_frame;
    input [7:0]  cmd;
    input [15:0] len;
    input        corrupt;
    reg   [7:0]  sum;
    integer      n;
    begin
      sum = cmd + len[7:0] + len[15:8];
      for (n = 0; n < len; n = n + 1) sum = sum + tx_pl[n];
      send_byte(8'hA5, 1'b0);
      send_byte(cmd, 1'b0);
      send_byte(len[7:0], 1'b0);
      send_byte(len[15:8], 1'b0);
      for (n = 0; n < len; n = n + 1) send_byte(tx_pl[n], 1'b0);
      send_byte((8'd0 - sum) ^ (corrupt ? 8'h5A : 8'h00), 1'b0);
    end
  endtask

  // Receiver: decodes uart_txd into a byte queue
  reg [7:0] rxq [0:65535];
  integer   rxq_w = 0, rxq_r = 0;
  integer   rx_framing_errors = 0;
  reg [7:0] rbyte;
  integer   rb;

  always begin
    @(negedge txd);
    #(BIT_NS / 2);
    if (txd == 1'b0) begin
      for (rb = 0; rb < 8; rb = rb + 1) begin #(BIT_NS); rbyte[rb] = txd; end
      #(BIT_NS);
      if (txd !== 1'b1) rx_framing_errors = rx_framing_errors + 1;
      rxq[rxq_w % 65536] = rbyte;
      rxq_w = rxq_w + 1;
    end
  end

  integer errors = 0, checks = 0;
  reg [8*24-1:0] tag;

  task fail_msg;
    input [8*64-1:0] msg;
    begin
      errors = errors + 1;
      $display("FAIL %0s: %0s  TEST FAILED", tag, msg);
    end
  endtask

  task next_rx;
    output [7:0] b;
    output       ok;
    integer      waited;
    begin
      waited = 0;
      while (rxq_r == rxq_w && waited < RSP_TIMEOUT) begin @(negedge clk); waited = waited + 1; end
      ok = (rxq_r != rxq_w);
      b = ok ? rxq[rxq_r % 65536] : 8'h00;
      if (ok) rxq_r = rxq_r + 1;
    end
  endtask

  // Response frame
  reg [7:0]  r_rsp;
  reg [15:0] r_len;
  reg [7:0]  r_pl [0:MAX_PL-1];
  reg        r_got;

  task recv_frame;
    reg [7:0] b, sum;
    reg       ok;
    integer   n;
    begin
      r_got = 1'b0;
      next_rx(b, ok);
      if (!ok)              fail_msg("no response");
      else if (b !== 8'h5A) fail_msg("response does not start with 5A");
      else begin
        next_rx(r_rsp, ok); sum = r_rsp;
        next_rx(b, ok); r_len[7:0] = b; sum = sum + b;
        next_rx(b, ok); r_len[15:8] = b; sum = sum + b;
        for (n = 0; n < r_len && n < MAX_PL; n = n + 1) begin
          next_rx(r_pl[n], ok); sum = sum + r_pl[n];
        end
        next_rx(b, ok); sum = sum + b;
        if (!ok)              fail_msg("response truncated");
        else if (sum != 8'd0) fail_msg("bad response checksum");
        else                  r_got = 1'b1;
      end
    end
  endtask

  // Expect a short response: rsp code with LEN = n bytes of `value` (LE)
  task expect_short;
    input [7:0]  rsp;
    input [15:0] n;
    input [15:0] value;
    begin
      recv_frame;
      checks = checks + 1;
      if (r_got) begin
        if (r_rsp !== rsp || r_len !== n ||
            (n >= 1 && r_pl[0] !== value[7:0]) || (n >= 2 && r_pl[1] !== value[15:8])) begin
          errors = errors + 1;
          $display("FAIL %0s: expected rsp=%02h len=%0d value=%04h, got rsp=%02h len=%0d pl0=%02h pl1=%02h  TEST FAILED",
                   tag, rsp, n, value, r_rsp, r_len, r_pl[0], r_pl[1]);
        end else begin
          $display("PASS %0s: rsp=%02h len=%0d", tag, r_rsp, r_len);
        end
      end
    end
  endtask

  // =====================================================================
  // Reference core control and expected STATE
  // =====================================================================
  task ref_reset;
    input load_imem;
    begin
      @(negedge clk);
      r_rst = 1'b1; r_en = 1'b0; r_clr = 1'b1;
      for (i = 0; i < DMEM_DEPTH; i = i + 1) begin
        r_clr_addr = i;
        r_imem_we = load_imem && (i < prog_len);
        r_imem_waddr = i;
        r_imem_wdata = (i < prog_len) ? prog[i] : 32'd0;
        @(negedge clk);
      end
      r_clr = 1'b0; r_imem_we = 1'b0;
      r_limit = tb_prog_len;
      @(negedge clk); @(negedge clk);
      r_rst = 1'b0;
      r_hwm = 0;
    end
  endtask

  task ref_step;
    begin
      @(negedge clk); r_en = 1'b1;
      @(negedge clk); r_en = 1'b0;
    end
  endtask

  task ref_run;
    begin
      @(negedge clk); r_en = 1'b1;
      while (!r_halted) @(negedge clk);
      r_en = 1'b0;
    end
  endtask

  reg [7:0]  e_pl [0:MAX_PL-1];
  integer    e_len;
  reg [95:0] e_status;

  task build_expected;
    begin
      e_status = {16'd0, r_hwm[15:0], r_cycles, tb_prog_len,
                  {5'd0, r_reason}, {5'd0, tb_prog_valid, r_halting, r_halted}};
      for (k = 0; k < 12; k = k + 1) e_pl[k] = e_status >> (8 * k);
      for (k = 0; k < 64; k = k + 1) e_pl[12 + k] = r_vec >> (8 * k);
      for (k = 0; k < 32; k = k + 1) begin
        r_reg_addr = k; #1;
        e_pl[76 + 4*k]     = r_reg_data[7:0];
        e_pl[76 + 4*k + 1] = r_reg_data[15:8];
        e_pl[76 + 4*k + 2] = r_reg_data[23:16];
        e_pl[76 + 4*k + 3] = r_reg_data[31:24];
      end
      for (k = 0; k < r_hwm; k = k + 1) begin
        r_b_addr = k;
        @(negedge clk);
        e_pl[204 + 4*k]     = r_dmem_b_rdata[7:0];
        e_pl[204 + 4*k + 1] = r_dmem_b_rdata[15:8];
        e_pl[204 + 4*k + 2] = r_dmem_b_rdata[23:16];
        e_pl[204 + 4*k + 3] = r_dmem_b_rdata[31:24];
      end
      e_len = 204 + 4 * r_hwm;
    end
  endtask

  // Receive a STATE response and compare it with the reference core
  task expect_state;
    input [7:0] rsp;
    integer     bad;
    begin
      recv_frame;
      build_expected;
      checks = checks + 1;
      if (r_got) begin
        bad = -1;
        for (k = 0; k < e_len && bad < 0; k = k + 1)
          if (r_pl[k] !== e_pl[k]) bad = k;
        if (r_rsp !== rsp || r_len != e_len || bad >= 0) begin
          errors = errors + 1;
          $display("FAIL %0s: expected rsp=%02h len=%0d, got rsp=%02h len=%0d; first differing byte %0d: expected %02h got %02h  TEST FAILED",
                   tag, rsp, e_len, r_rsp, r_len, bad, (bad >= 0) ? e_pl[bad] : 8'h00,
                   (bad >= 0) ? r_pl[bad] : 8'h00);
        end else begin
          $display("PASS %0s: rsp=%02h len=%0d cycles=%0d halted=%b, STATE matches the reference core",
                   tag, r_rsp, r_len, r_cycles, r_halted);
        end
      end
    end
  endtask

  // Check the last STATE payload against the ISS final state
  function [31:0] pl32;
    input integer off;
    begin
      pl32 = {r_pl[off + 3], r_pl[off + 2], r_pl[off + 1], r_pl[off]};
    end
  endfunction

  task check_iss;
    integer bad;
    begin
      checks = checks + 1;
      bad = 0;
      if (r_pl[0] !== 8'h05) bad = 1;                       // halted + prog_valid
      if (r_pl[1] !== exp_reason[7:0]) bad = 2;
      if (pl32(4) !== exp_cycles) bad = 3;
      if ({r_pl[9], r_pl[8]} !== exp_used[15:0]) bad = 4;
      if (pl32(12) !== exp_pc) bad = 5;
      for (k = 0; k < 32; k = k + 1) if (pl32(76 + 4*k) !== exp_regs[k]) bad = 6;
      for (k = 0; k < exp_used; k = k + 1) if (pl32(204 + 4*k) !== exp_dmem[k]) bad = 7;
      if (bad != 0) begin
        errors = errors + 1;
        $display("FAIL %0s: STATE differs from the ISS (check %0d)  TEST FAILED", tag, bad);
      end else begin
        $display("PASS %0s: final STATE matches the ISS (reason=%0d cycles=%0d)", tag, exp_reason, exp_cycles);
      end
    end
  endtask

  task expect_silence;
    input integer cycles;
    begin
      repeat (cycles) @(negedge clk);
      checks = checks + 1;
      if (rxq_r != rxq_w) begin
        errors = errors + 1;
        $display("FAIL %0s: %0d unexpected bytes from the FPGA  TEST FAILED", tag, rxq_w - rxq_r);
        rxq_r = rxq_w;
      end
    end
  endtask

  // =====================================================================
  // Host operations: send a command and check its response
  // =====================================================================
  task host_load;
    begin
      for (i = 0; i < prog_len; i = i + 1) begin
        tx_pl[4*i]     = prog[i][7:0];
        tx_pl[4*i + 1] = prog[i][15:8];
        tx_pl[4*i + 2] = prog[i][23:16];
        tx_pl[4*i + 3] = prog[i][31:24];
      end
      send_frame(CMD_LOAD, 4 * prog_len, 1'b0);
      tb_prog_valid = 1'b1;
      tb_prog_len = prog_len;
      ref_reset(1'b1);
      expect_short(CMD_LOAD | 8'h80, 16'd2, prog_len);
    end
  endtask

  task host_dump;
    begin
      send_frame(CMD_DUMP, 16'd0, 1'b0);
      expect_state(CMD_DUMP | 8'h80);
    end
  endtask

  task host_step;
    begin
      send_frame(CMD_STEP, 16'd0, 1'b0);
      ref_step;
      expect_state(CMD_STEP | 8'h80);
    end
  endtask

  task host_run;
    begin
      send_frame(CMD_RUN, 16'd0, 1'b0);
      ref_run;
      expect_state(CMD_RUN | 8'h80);
      check_iss;
    end
  endtask

  task host_reset;
    begin
      send_frame(CMD_RESET, 16'd0, 1'b0);
      ref_reset(1'b0);
      expect_short(CMD_RESET | 8'h80, 16'd0, 16'd0);
    end
  endtask

  // Full program check: load, step `steps` times (all if negative), run
  task program_test;
    input [127:0] test_name;
    input integer steps;
    integer s;
    begin
      load_test(test_name);
      tag = {name, "/load"}; host_load;
      tag = {name, "/dump"}; host_dump;
      s = 0;
      while (!r_halted && (steps < 0 || s < steps)) begin
        tag = {name, "/step"}; host_step;
        s = s + 1;
      end
      if (!r_halted) begin
        tag = {name, "/run"}; host_run;
      end else begin
        check_iss;
      end
      tag = {name, "/run_halted"};
      send_frame(CMD_RUN, 16'd0, 1'b0);  expect_short(ERR_HALTED, 16'd1, CMD_RUN);
      tag = {name, "/step_halted"};
      send_frame(CMD_STEP, 16'd0, 1'b0); expect_short(ERR_HALTED, 16'd1, CMD_STEP);
    end
  endtask

  // =====================================================================
  // Main
  // =====================================================================
  initial begin
    $readmemh("cpu_tests.hex", stream);
    index_tests;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (DMEM_DEPTH + 100) @(negedge clk);   // power-on reset sequence
    prog_len = 0;
    ref_reset(1'b0);

    // ---- 1. After power-on ----
    tag = "power_on/dump"; host_dump;

    // ---- 2. Errors without a program; check order ----
    tag = "step_no_program"; send_frame(CMD_STEP, 16'd0, 1'b0); expect_short(ERR_NO_PROGRAM, 16'd1, CMD_STEP);
    tag = "run_no_program";  send_frame(CMD_RUN, 16'd0, 1'b0);  expect_short(ERR_NO_PROGRAM, 16'd1, CMD_RUN);
    tag = "unknown_cmd";     send_frame(8'h09, 16'd0, 1'b0);     expect_short(ERR_UNKNOWN_CMD, 16'd1, 16'h0009);
    tag = "dump_bad_chk";    send_frame(CMD_DUMP, 16'd0, 1'b1);  expect_short(ERR_CHECKSUM, 16'd1, CMD_DUMP);
    tx_pl[0] = 8'h00;
    tag = "dump_len1";       send_frame(CMD_DUMP, 16'd1, 1'b0);  expect_short(ERR_LENGTH, 16'd1, CMD_DUMP);
    tag = "run_len1";        send_frame(CMD_RUN, 16'd1, 1'b0);   expect_short(ERR_LENGTH, 16'd1, CMD_RUN);
    for (i = 0; i < 6; i = i + 1) tx_pl[i] = i;
    tag = "load_len6";       send_frame(CMD_LOAD, 16'd6, 1'b0);  expect_short(ERR_LENGTH, 16'd1, CMD_LOAD);
    tag = "load_len0";       send_frame(CMD_LOAD, 16'd0, 1'b0);  expect_short(ERR_LENGTH, 16'd1, CMD_LOAD);
    tag = "load_len6_badchk"; send_frame(CMD_LOAD, 16'd6, 1'b1); expect_short(ERR_CHECKSUM, 16'd1, CMD_LOAD);
    tag = "unknown_badchk";  send_frame(8'h77, 16'd0, 1'b1);     expect_short(ERR_CHECKSUM, 16'd1, 16'h0077);
    tag = "errors/dump";     host_dump;                          // nothing changed

    // ---- 3. Programs ----
    program_test("        load_use", -1);    // every cycle by STEP
    program_test("           jumps", -1);
    program_test("             alu", 5);
    program_test("        branches", 0);
    program_test("         no_halt", 3);
    program_test("         illegal", 0);
    program_test("       random_05", 10);
    program_test("       random_17", 0);

    // RESET in the middle of a program
    load_test("       loadstore");
    tag = "loadstore/load";  host_load;
    for (j = 0; j < 7; j = j + 1) begin tag = "loadstore/step"; host_step; end
    tag = "loadstore/reset"; host_reset;
    tag = "loadstore/dump";  host_dump;
    for (j = 0; j < 2; j = j + 1) begin tag = "loadstore/step"; host_step; end
    tag = "loadstore/run";   host_run;
    tag = "loadstore/reset2"; host_reset;
    tag = "loadstore/run2";  host_run;          // a second full run after RESET

    // ---- 4. A frame sent during RUN is dropped; TIMEOUT ends the run ----
    load_test("    timeout_loop");
    tag = "timeout/load"; host_load;
    tag = "timeout/run_with_dump";
    send_frame(CMD_RUN, 16'd0, 1'b0);
    send_frame(CMD_DUMP, 16'd0, 1'b0);          // arrives while running
    ref_run;
    expect_state(CMD_RUN | 8'h80);
    check_iss;
    tag = "timeout/dropped_dump"; expect_silence(20000);

    // ---- 5. LOAD with a bad checksum: no program afterwards ----
    load_test("             alu");
    for (i = 0; i < prog_len; i = i + 1) begin
      tx_pl[4*i] = prog[i][7:0]; tx_pl[4*i+1] = prog[i][15:8];
      tx_pl[4*i+2] = prog[i][23:16]; tx_pl[4*i+3] = prog[i][31:24];
    end
    tag = "load_bad_chk"; send_frame(CMD_LOAD, 4 * prog_len, 1'b1);
    tb_prog_valid = 1'b0; tb_prog_len = 0; prog_len = 0;
    ref_reset(1'b0);
    expect_short(ERR_CHECKSUM, 16'd1, CMD_LOAD);
    tag = "after_bad_load/run";  send_frame(CMD_RUN, 16'd0, 1'b0); expect_short(ERR_NO_PROGRAM, 16'd1, CMD_RUN);
    tag = "after_bad_load/dump"; host_dump;

    // ---- 6. Inter-byte timeout and framing error drop the frame ----
    tag = "rx_timeout";
    send_byte(8'hA5, 1'b0); send_byte(CMD_DUMP, 1'b0); send_byte(8'h00, 1'b0);
    expect_silence(RX_TIMEOUT + 1000);
    tag = "rx_timeout/dump"; host_dump;
    tag = "rx_framing";
    send_byte(8'hA5, 1'b0); send_byte(CMD_DUMP, 1'b0); send_byte(8'h00, 1'b1);
    expect_silence(1000);
    tag = "rx_framing/dump"; host_dump;
    tag = "final"; expect_silence(5000);

    checks = checks + 1;
    if (rx_framing_errors != 0) begin
      errors = errors + 1;
      $display("FAIL: %0d framing errors on uart_txd  TEST FAILED", rx_framing_errors);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d checks)", checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
