`timescale 1ns/1ps
`default_nettype none

// Step mode, enable and reset testbench for cpu_core (+ imem, dmem).
// Spec (docs/arquitectura.md 6): the global enable en gates every state
// element; step mode is en pulsed one cycle at a time, so the core goes
// through the same sequence of enabled edges as in continuous mode and must
// reach exactly the same state after each one. With en = 0 nothing changes.
// Once halted, en is ignored. RESET (core reset, dmem cleared, program kept)
// works from any pipeline state.
//
// For each program in cpu_tests.hex (TP3/py/gen_vectors.py):
//   run 1 - continuous (en = 1): record the debug vector (PC + all pipeline
//           registers) after every edge and the dmem write of every edge;
//   run 2 - random en (duty cycle 1/2, 1/4, 3/4 or alternating, by test):
//           * enabled edge: the dmem write and the new state must equal the
//             run-1 trace at the same cycle count;
//           * disabled edge: no dmem enable or write, state and cycle_cnt
//             unchanged, imem address held at the PC, and no register
//             written (checked: the MEM/WB target and a rotating register);
//           * after halted, 8 more cycles with en = 1 change nothing;
//           * final state equal to the ISS (registers, all dmem, PC, cycles,
//             halt reason);
//   run 3 - continuous run cut by a reset at a random cycle, then a full run
//           from reset: final state equal to the ISS.

module tb_cpu_step;

  localparam integer CLK_PERIOD  = 10;
  localparam integer IMEM_ADDR_W = 10;
  localparam integer DMEM_ADDR_W = 10;
  localparam integer IMEM_DEPTH  = 1 << IMEM_ADDR_W;
  localparam integer DMEM_DEPTH  = 1 << DMEM_ADDR_W;
  localparam integer MAX_CYCLES  = 3000;      // = CPU_MAX_CYCLES in gen_vectors.py
  localparam integer MAX_WORDS   = 1 << 17;   // = CPU_MAX_WORDS in gen_vectors.py
  localparam integer TRACE_LEN   = MAX_CYCLES + 16;
  localparam integer AFTER_HALT  = 8;
  localparam [31:0]  MAGIC       = 32'hC0DE0001;

  reg clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ---------------- DUT and memories (same wiring as tb_cpu_core) ----------------
  reg                    rst = 1'b1;
  reg                    en  = 1'b0;
  reg  [IMEM_ADDR_W:0]   imem_limit = 0;

  wire [IMEM_ADDR_W-1:0] imem_raddr;
  wire [31:0]            imem_rdata;
  reg                    imem_we = 1'b0;
  reg  [IMEM_ADDR_W-1:0] imem_waddr = 0;
  reg  [31:0]            imem_wdata = 32'd0;

  wire                   core_dmem_en;
  wire [3:0]             core_dmem_we;
  wire [DMEM_ADDR_W-1:0] core_dmem_addr;
  wire [31:0]            core_dmem_wdata;
  wire [31:0]            dmem_a_rdata, dmem_b_rdata;
  reg                    clr = 1'b0;
  reg  [DMEM_ADDR_W-1:0] clr_addr = 0;
  reg  [DMEM_ADDR_W-1:0] b_addr = 0;

  wire                   halting, halted;
  wire [2:0]             halt_reason;
  wire [31:0]            cycle_cnt;
  reg  [4:0]             dbg_reg_addr = 5'd0;
  wire [31:0]            dbg_reg_data;
  wire [511:0]           vec;

  imem #(.ADDR_W(IMEM_ADDR_W)) u_imem (
    .clk(clk), .we(imem_we), .waddr(imem_waddr), .wdata(imem_wdata),
    .raddr(imem_raddr), .rdata(imem_rdata)
  );

  dmem #(.ADDR_W(DMEM_ADDR_W)) u_dmem (
    .clk(clk),
    .a_en(clr ? 1'b1 : core_dmem_en),
    .a_we(clr ? 4'b1111 : core_dmem_we),
    .a_addr(clr ? clr_addr : core_dmem_addr),
    .a_wdata(clr ? 32'd0 : core_dmem_wdata),
    .a_rdata(dmem_a_rdata),
    .b_addr(b_addr), .b_rdata(dmem_b_rdata)
  );

  cpu_core #(
    .IMEM_ADDR_W(IMEM_ADDR_W), .DMEM_ADDR_W(DMEM_ADDR_W), .MAX_CYCLES(MAX_CYCLES)
  ) dut (
    .clk(clk), .rst(rst), .en(en), .imem_limit(imem_limit),
    .imem_addr(imem_raddr), .imem_rdata(imem_rdata),
    .dmem_en(core_dmem_en), .dmem_we(core_dmem_we), .dmem_addr(core_dmem_addr),
    .dmem_wdata(core_dmem_wdata), .dmem_rdata(dmem_a_rdata),
    .halting(halting), .halted(halted), .halt_reason(halt_reason),
    .cycle_cnt(cycle_cnt),
    .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data), .dbg_core_vec(vec)
  );

  wire [31:0] pc_if = vec[31:0];
  wire [45:0] dmem_write = {core_dmem_we, core_dmem_addr, core_dmem_wdata};

  // ---------------- Test stream and per-test data ----------------
  reg [31:0] stream [0:MAX_WORDS-1];
  integer p;

  task get;
    output [31:0] w;
    begin
      w = stream[p];
      p = p + 1;
    end
  endtask

  reg [127:0] name;
  reg [31:0]  w0, w1, w2, w3;
  integer     n_tests, t, i, k, prog_len, ran, duty, cut;
  reg [31:0]  prog     [0:IMEM_DEPTH-1];
  reg [31:0]  exp_pc, exp_cycles, exp_reason, exp_used;
  reg [31:0]  exp_regs [0:31];
  reg [31:0]  exp_dmem [0:DMEM_DEPTH-1];

  reg [511:0] trace  [0:TRACE_LEN-1];   // state after edge c (index = cycle_cnt)
  reg [45:0]  wtrace [0:TRACE_LEN-1];   // dmem write of the edge that ends cycle c+1
  reg [511:0] prev_vec;
  reg [31:0]  prev_cnt;
  reg         step_en;
  reg [4:0]   rf_addr_a, rf_addr_b;
  reg [31:0]  rf_before_a, rf_before_b;

  integer errors = 0;
  integer checks = 0;
  integer test_errors;
  integer seed = 2026;
  reg [8*12-1:0] phase;

  task fail;
    input [8*48-1:0] what;
    begin
      errors = errors + 1;
      test_errors = test_errors + 1;
      if (test_errors <= 5)
        $display("FAIL %0s [%0s]: %0s at cycle_cnt=%0d  TEST FAILED", name, phase, what, cycle_cnt);
    end
  endtask

  task expect32;
    input [8*16-1:0] what;
    input [31:0]     got, exp;
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        test_errors = test_errors + 1;
        $display("FAIL %0s [%0s]: %0s expected=%08h got=%08h  TEST FAILED", name, phase, what, exp, got);
      end
    end
  endtask

  // Reset the core and clear dmem (as the RESET command does). With
  // load_imem = 1 the program is also written into imem (LOAD).
  task reset_core;
    input load_imem;
    begin
      @(negedge clk);
      rst = 1'b1; en = 1'b0; clr = 1'b1;
      for (i = 0; i < DMEM_DEPTH; i = i + 1) begin
        clr_addr   = i;
        imem_we    = load_imem && (i < prog_len);
        imem_waddr = i;
        imem_wdata = (i < prog_len) ? prog[i] : 32'd0;
        @(negedge clk);
      end
      clr = 1'b0; imem_we = 1'b0;
      imem_limit = prog_len;
      @(negedge clk);
      @(negedge clk);
      rst = 1'b0;
    end
  endtask

  // Compare the final architectural state with the ISS
  task compare_final;
    begin
      expect32("halted", {31'd0, halted}, 32'd1);
      expect32("halt_reason", {29'd0, halt_reason}, exp_reason);
      expect32("cycles", cycle_cnt, exp_cycles);
      expect32("pc", pc_if, exp_pc);
      for (i = 0; i < 32; i = i + 1) begin
        dbg_reg_addr = i;
        #1;
        expect32("register", dbg_reg_data, exp_regs[i]);
      end
      for (i = 0; i < DMEM_DEPTH; i = i + 1) begin
        b_addr = i;
        @(negedge clk);
        expect32("dmem word", dmem_b_rdata, exp_dmem[i]);
      end
    end
  endtask

  // Random enable with a per-test duty cycle
  function next_en;
    input integer mode;
    input integer cyc;
    begin
      case (mode)
        0: next_en = ($random(seed) % 2) == 0;            // ~1/2
        1: next_en = ($random(seed) % 4) == 0;            // ~1/4
        2: next_en = ($random(seed) % 4) != 0;            // ~3/4
        default: next_en = cyc[0];                        // alternating
      endcase
    end
  endfunction

  initial begin
    $readmemh("cpu_tests.hex", stream);
    p = 0;
    get(w0);
    if (w0 !== MAGIC) begin
      $display("FAIL: cpu_tests.hex missing or bad magic  TEST FAILED");
      $fatal(1, "no test vectors");
    end
    get(w0); n_tests = w0;
    get(w0);
    if (w0 != MAX_CYCLES)
      $fatal(1, "cpu_tests.hex was generated for another MAX_CYCLES");

    for (t = 0; t < n_tests; t = t + 1) begin
      test_errors = 0;
      get(w0); get(w1); get(w2); get(w3);
      name = {w0, w1, w2, w3};
      get(w0); prog_len = w0;
      for (i = 0; i < prog_len; i = i + 1) get(prog[i]);
      get(exp_pc); get(exp_cycles); get(exp_reason); get(exp_used);
      for (i = 0; i < 32; i = i + 1) get(exp_regs[i]);
      for (i = 0; i < DMEM_DEPTH; i = i + 1) exp_dmem[i] = 32'd0;
      for (i = 0; i < exp_used; i = i + 1) get(exp_dmem[i]);

      // ---- Run 1: continuous, record the trace ----
      phase = "continuous";
      reset_core(1'b1);
      en = 1'b1;
      trace[0] = vec;
      ran = 0;
      while (!halted && ran < MAX_CYCLES + 100) begin
        wtrace[cycle_cnt] = dmem_write;
        @(negedge clk);
        trace[cycle_cnt] = vec;
        ran = ran + 1;
      end
      en = 1'b0;
      expect32("cycles", cycle_cnt, exp_cycles);

      // ---- Run 2: random enable, compare with the trace every cycle ----
      phase = "step";
      duty = t % 4;
      reset_core(1'b0);
      ran = 0;
      while (!halted && ran < 8 * (MAX_CYCLES + 100)) begin
        step_en = next_en(duty, ran);
        en = step_en;
        prev_vec = vec;
        prev_cnt = cycle_cnt;
        #1;
        checks = checks + 1;
        if (step_en) begin
          if (dmem_write !== wtrace[cycle_cnt]) fail("dmem write differs from continuous run");
        end else begin
          if (core_dmem_en !== 1'b0 || core_dmem_we !== 4'b0000) fail("dmem enabled while en = 0");
          if (imem_raddr !== pc_if[IMEM_ADDR_W+1:2]) fail("imem address moved while en = 0");
          // Registers that must not change: the one MEM/WB is about to write
          // (it is written only on the next enabled edge) and a rotating one
          rf_addr_a = vec[484:480];
          rf_addr_b = ran % 32;
          dbg_reg_addr = rf_addr_a; #1 rf_before_a = dbg_reg_data;
          dbg_reg_addr = rf_addr_b; #1 rf_before_b = dbg_reg_data;
        end
        @(negedge clk);
        checks = checks + 1;
        if (step_en) begin
          if (cycle_cnt !== prev_cnt + 1) fail("cycle_cnt did not advance");
          else if (vec !== trace[cycle_cnt]) fail("state differs from continuous run");
        end else begin
          if (cycle_cnt !== prev_cnt) fail("cycle_cnt changed while en = 0");
          if (vec !== prev_vec) fail("state changed while en = 0");
          dbg_reg_addr = rf_addr_a; #1;
          if (dbg_reg_data !== rf_before_a) fail("register written while en = 0");
          dbg_reg_addr = rf_addr_b; #1;
          if (dbg_reg_data !== rf_before_b) fail("register written while en = 0");
        end
        ran = ran + 1;
      end

      // en is ignored once halted
      phase = "after_halt";
      en = 1'b1;
      prev_vec = vec;
      prev_cnt = cycle_cnt;
      for (k = 0; k < AFTER_HALT; k = k + 1) begin
        #1;
        checks = checks + 1;
        if (core_dmem_we !== 4'b0000) fail("dmem write after halted");
        @(negedge clk);
        checks = checks + 1;
        if (vec !== prev_vec || cycle_cnt !== prev_cnt) fail("state changed after halted");
      end
      en = 1'b0;
      phase = "step";
      compare_final;

      // ---- Run 3: reset in the middle of a run, then run again ----
      phase = "reset_mid";
      reset_core(1'b0);
      cut = 1 + ($unsigned($random(seed)) % exp_cycles);  // 1 .. exp_cycles
      en = 1'b1;
      for (k = 0; k < cut && !halted; k = k + 1)
        @(negedge clk);
      en = 1'b0;
      reset_core(1'b0);       // RESET: program kept, dmem cleared
      en = 1'b1;
      ran = 0;
      while (!halted && ran < MAX_CYCLES + 100) begin
        @(negedge clk);
        ran = ran + 1;
      end
      en = 1'b0;
      @(negedge clk);
      compare_final;

      if (test_errors == 0)
        $display("PASS %0s: continuous, step (duty mode %0d) and reset after %0d cycles all match, cycles=%0d",
                 name, duty, cut, exp_cycles);
    end

    if (errors == 0)
      $display("ALL TESTS PASSED (%0d programs, %0d checks)", n_tests, checks);
    else
      $fatal(1, "%0d of %0d checks failed", errors, checks);
    $finish;
  end

endmodule

`default_nettype wire
