`timescale 1ns/1ps
`default_nettype none

// 5-stage pipelined RV32I core (IF, ID, EX, MEM, WB).
// Design: docs/arquitectura.md; ports: docs/modulos.md section 3.
// - Forwarding EX/MEM and MEM/WB -> EX; regfile bypass for WB -> ID.
// - Load-use: 1-cycle stall. beq/bne/jalr resolved in EX (2-cycle flush),
//   jal in ID (1-cycle flush), static not-taken prediction.
// - imem is addressed with next_pc and dmem with the EX address, so their
//   registered outputs line up with IF and MEM.
// - Stop slots (ebreak, illegal, OOR, TIMEOUT) are accepted in ID and drained
//   as a HALT marker; halted rises when it leaves MEM/WB (pipeline empty).
// - en is the global enable (run / step): every state element is gated by
//   en_int = en && !halted. The clock is never touched.
// Memories are outside the core (system_top / testbench).

module cpu_core #(
  parameter integer IMEM_ADDR_W = 10,
  parameter integer DMEM_ADDR_W = 10,
  parameter integer MAX_CYCLES  = 1000000
)(
  input  wire                   clk,
  input  wire                   rst,
  input  wire                   en,
  input  wire [IMEM_ADDR_W:0]   imem_limit,
  // instruction memory read port
  output wire [IMEM_ADDR_W-1:0] imem_addr,
  input  wire [31:0]            imem_rdata,
  // data memory port A
  output wire                   dmem_en,
  output wire [3:0]             dmem_we,
  output wire [DMEM_ADDR_W-1:0] dmem_addr,
  output wire [31:0]            dmem_wdata,
  input  wire [31:0]            dmem_rdata,
  // status
  output wire                   halting,
  output wire                   halted,
  output wire [2:0]             halt_reason,
  output wire [31:0]            cycle_cnt,
  // debug
  input  wire [4:0]             dbg_reg_addr,
  output wire [31:0]            dbg_reg_data,
  output wire [511:0]           dbg_core_vec
);

  localparam [1:0] FWD_WB  = 2'b01;
  localparam [1:0] FWD_MEM = 2'b10;

  wire en_int = en && !halted;

  // ------------------------------------------------------------------
  // Forward declarations of signals used across stages
  // ------------------------------------------------------------------
  wire        ex_redirect;
  wire [31:0] ex_target;
  wire        load_use;
  wire        halt_accept;
  wire        id_jal;
  wire [31:0] id_jal_target;
  wire        timeout;

  // ------------------------------------------------------------------
  // IF
  // ------------------------------------------------------------------
  wire [31:0] if_pc;
  wire [2:0]  if_stop_code;

  wire [31:0] if_id_pc;
  wire [31:0] if_id_instr;
  wire [2:0]  if_id_stop_code;
  wire        if_id_valid;

  fetch_unit #(.IMEM_ADDR_W(IMEM_ADDR_W)) u_fetch (
    .clk(clk), .rst(rst), .en(en_int),
    .ex_redirect(ex_redirect), .ex_target(ex_target),
    .halt_accept(halt_accept), .halt_pc(if_id_pc),
    .halting(halting), .load_use(load_use),
    .id_jal(id_jal), .id_jal_target(id_jal_target),
    .timeout(timeout), .imem_limit(imem_limit),
    .pc(if_pc), .imem_addr(imem_addr), .fetch_stop_code(if_stop_code)
  );

  if_id_reg u_if_id (
    .clk(clk), .rst(rst), .en(en_int),
    .flush(ex_redirect | halt_accept | halting | id_jal),
    .hold(load_use),
    .in_pc(if_pc), .in_instr(imem_rdata), .in_stop_code(if_stop_code),
    .pc(if_id_pc), .instr(if_id_instr), .stop_code(if_id_stop_code),
    .valid(if_id_valid)
  );

  // ------------------------------------------------------------------
  // ID
  // ------------------------------------------------------------------
  wire [4:0]  dec_rs1, dec_rs2, dec_rd;
  wire [3:0]  dec_alu_op;
  wire        dec_alu_src, dec_link, dec_reg_write, dec_mem_read, dec_mem_write;
  wire [2:0]  dec_funct3;
  wire        dec_branch, dec_jalr, dec_jal;
  wire [2:0]  dec_imm_sel;
  wire        dec_halt_cond;
  wire [2:0]  dec_halt_reason;
  wire [31:0] id_imm;
  wire [31:0] id_rs1_data, id_rs2_data;

  decoder u_dec (
    .instr(if_id_instr), .stop_code(if_id_stop_code),
    .rs1(dec_rs1), .rs2(dec_rs2), .rd(dec_rd), .alu_op(dec_alu_op),
    .alu_src(dec_alu_src), .link(dec_link), .reg_write(dec_reg_write),
    .mem_read(dec_mem_read), .mem_write(dec_mem_write), .funct3(dec_funct3),
    .branch(dec_branch), .jalr(dec_jalr), .jal(dec_jal), .imm_sel(dec_imm_sel),
    .halt_cond(dec_halt_cond), .halt_reason(dec_halt_reason)
  );

  imm_gen u_imm (.instr(if_id_instr), .imm_sel(dec_imm_sel), .imm(id_imm));

  // WB-stage signals (regfile write port)
  wire [31:0] mem_wb_pc, mem_wb_wb_data;
  wire [8:0]  mem_wb_ctrl;
  wire [4:0]  wb_rd        = mem_wb_ctrl[4:0];
  wire        wb_reg_write = mem_wb_ctrl[5];
  wire        wb_is_halt   = mem_wb_ctrl[7];
  wire        wb_valid     = mem_wb_ctrl[8];

  regfile u_rf (
    .clk(clk), .rst(rst),
    .we(en_int && wb_reg_write), .waddr(wb_rd), .wdata(mem_wb_wb_data),
    .raddr1(dec_rs1), .raddr2(dec_rs2),
    .rdata1(id_rs1_data), .rdata2(id_rs2_data),
    .dbg_addr(dbg_reg_addr), .dbg_data(dbg_reg_data)
  );

  // ID/EX outputs (declared here: the hazard unit needs them)
  wire [31:0] id_ex_pc, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
  wire [30:0] id_ex_ctrl;
  wire [4:0]  ex_rs1       = id_ex_ctrl[4:0];
  wire [4:0]  ex_rs2       = id_ex_ctrl[9:5];
  wire [4:0]  ex_rd        = id_ex_ctrl[14:10];
  wire [3:0]  ex_alu_op    = id_ex_ctrl[18:15];
  wire        ex_alu_src   = id_ex_ctrl[19];
  wire        ex_link      = id_ex_ctrl[20];
  wire        ex_reg_write = id_ex_ctrl[21];
  wire        ex_mem_read  = id_ex_ctrl[22];
  wire        ex_mem_write = id_ex_ctrl[23];
  wire [2:0]  ex_funct3    = id_ex_ctrl[26:24];
  wire        ex_branch    = id_ex_ctrl[27];
  wire        ex_jalr      = id_ex_ctrl[28];
  wire        ex_is_halt   = id_ex_ctrl[29];
  wire        ex_valid     = id_ex_ctrl[30];

  hazard_unit u_hz (
    .if_id_valid(if_id_valid), .id_rs1(dec_rs1), .id_rs2(dec_rs2),
    .id_ex_mem_read(ex_mem_read), .id_ex_rd(ex_rd), .load_use(load_use)
  );

  assign halt_accept   = if_id_valid && dec_halt_cond && !ex_redirect && !halting;
  assign id_jal        = if_id_valid && dec_jal && !ex_redirect;
  assign id_jal_target = if_id_pc + id_imm;

  wire [30:0] id_ctrl = {1'b1,            // [30] valid (bubbles come from flush)
                         dec_halt_cond,   // [29] is_halt
                         dec_jalr,        // [28]
                         dec_branch,      // [27]
                         dec_funct3,      // [26:24]
                         dec_mem_write,   // [23]
                         dec_mem_read,    // [22]
                         dec_reg_write,   // [21]
                         dec_link,        // [20]
                         dec_alu_src,     // [19]
                         dec_alu_op,      // [18:15]
                         dec_rd,          // [14:10]
                         dec_rs2,         // [9:5]
                         dec_rs1};        // [4:0]

  id_ex_reg u_id_ex (
    .clk(clk), .rst(rst), .en(en_int),
    .flush(ex_redirect | load_use | !if_id_valid),
    .in_pc(if_id_pc), .in_rs1_data(id_rs1_data), .in_rs2_data(id_rs2_data),
    .in_imm(id_imm), .in_ctrl(id_ctrl),
    .pc(id_ex_pc), .rs1_data(id_ex_rs1_data), .rs2_data(id_ex_rs2_data),
    .imm(id_ex_imm), .ctrl(id_ex_ctrl)
  );

  // ------------------------------------------------------------------
  // EX
  // ------------------------------------------------------------------
  wire [31:0] ex_mem_pc, ex_mem_result, ex_mem_store_data;
  wire [12:0] ex_mem_ctrl;
  wire [4:0]  mem_rd        = ex_mem_ctrl[4:0];
  wire        mem_reg_write = ex_mem_ctrl[5];
  wire        mem_mem_read  = ex_mem_ctrl[6];
  wire [2:0]  mem_funct3    = ex_mem_ctrl[10:8];
  wire        mem_is_halt   = ex_mem_ctrl[11];
  wire        mem_valid     = ex_mem_ctrl[12];

  wire [1:0] fwd_a, fwd_b;

  forward_unit u_fwd (
    .id_ex_rs1(ex_rs1), .id_ex_rs2(ex_rs2),
    .ex_mem_rd(mem_rd), .ex_mem_reg_write(mem_reg_write),
    .ex_mem_mem_read(mem_mem_read),
    .mem_wb_rd(wb_rd), .mem_wb_reg_write(wb_reg_write),
    .fwd_a(fwd_a), .fwd_b(fwd_b)
  );

  wire [31:0] ex_op_a = (fwd_a == FWD_MEM) ? ex_mem_result :
                        (fwd_a == FWD_WB)  ? mem_wb_wb_data : id_ex_rs1_data;
  wire [31:0] ex_op_b = (fwd_b == FWD_MEM) ? ex_mem_result :
                        (fwd_b == FWD_WB)  ? mem_wb_wb_data : id_ex_rs2_data;

  wire [31:0] alu_y;

  alu u_alu (
    .a(ex_op_a), .b(ex_alu_src ? id_ex_imm : ex_op_b), .op(ex_alu_op), .y(alu_y)
  );

  branch_unit u_br (
    .valid(ex_valid), .branch(ex_branch), .jalr(ex_jalr), .is_bne(ex_funct3[0]),
    .rs1_val(ex_op_a), .rs2_val(ex_op_b), .pc(id_ex_pc), .imm(id_ex_imm),
    .alu_y(alu_y), .redirect(ex_redirect), .target(ex_target)
  );

  wire [31:0] ex_result = ex_link ? (id_ex_pc + 32'd4) : alu_y;

  // Data memory access starts here: the store is written at the EX -> MEM
  // edge and the load data is ready during MEM (docs/arquitectura.md 4.2).
  wire [31:0] st_wdata;
  wire [3:0]  st_be;

  store_align u_st (
    .funct3(ex_funct3[1:0]), .addr_lo(alu_y[1:0]), .data(ex_op_b),
    .wdata(st_wdata), .be(st_be)
  );

  assign dmem_en    = en_int;
  assign dmem_we    = (en_int && ex_mem_write) ? st_be : 4'b0000;
  assign dmem_addr  = alu_y[DMEM_ADDR_W+1:2];
  assign dmem_wdata = st_wdata;

  wire [12:0] ex_ctrl = {ex_valid,        // [12]
                         ex_is_halt,      // [11]
                         ex_funct3,       // [10:8]
                         ex_mem_write,    // [7]
                         ex_mem_read,     // [6]
                         ex_reg_write,    // [5]
                         ex_rd};          // [4:0]

  ex_mem_reg u_ex_mem (
    .clk(clk), .rst(rst), .en(en_int),
    .in_pc(id_ex_pc), .in_result(ex_result), .in_store_data(ex_op_b),
    .in_ctrl(ex_ctrl),
    .pc(ex_mem_pc), .result(ex_mem_result), .store_data(ex_mem_store_data),
    .ctrl(ex_mem_ctrl)
  );

  // ------------------------------------------------------------------
  // MEM
  // ------------------------------------------------------------------
  wire [31:0] load_data;

  load_align u_ld (
    .funct3(mem_funct3), .addr_lo(ex_mem_result[1:0]), .rdata(dmem_rdata),
    .data(load_data)
  );

  wire [31:0] mem_wb_data = mem_mem_read ? load_data : ex_mem_result;

  wire [8:0] mem_ctrl = {mem_valid,       // [8]
                         mem_is_halt,     // [7]
                         mem_mem_read,    // [6]
                         mem_reg_write,   // [5]
                         mem_rd};         // [4:0]

  mem_wb_reg u_mem_wb (
    .clk(clk), .rst(rst), .en(en_int),
    .in_pc(ex_mem_pc), .in_wb_data(mem_wb_data), .in_ctrl(mem_ctrl),
    .pc(mem_wb_pc), .wb_data(mem_wb_wb_data), .ctrl(mem_wb_ctrl)
  );

  // ------------------------------------------------------------------
  // WB: regfile write (above) and HALT / cycle counter
  // ------------------------------------------------------------------
  halt_ctrl #(.MAX_CYCLES(MAX_CYCLES)) u_halt (
    .clk(clk), .rst(rst), .en(en_int),
    .halt_accept(halt_accept), .halt_reason_in(dec_halt_reason),
    .wb_halt(wb_valid && wb_is_halt),
    .halting(halting), .halted(halted), .halt_reason(halt_reason),
    .cycle_cnt(cycle_cnt), .timeout(timeout)
  );

  // ------------------------------------------------------------------
  // Debug vector: bytes 12..75 of the state dump (docs/protocol.md 6.2)
  // ------------------------------------------------------------------
  assign dbg_core_vec = {
    {23'd0, mem_wb_ctrl},                    // [511:480] MEM/WB ctrl
    mem_wb_wb_data,                          // [479:448]
    mem_wb_pc,                               // [447:416]
    {19'd0, ex_mem_ctrl},                    // [415:384] EX/MEM ctrl
    ex_mem_store_data,                       // [383:352]
    ex_mem_result,                           // [351:320]
    ex_mem_pc,                               // [319:288]
    {1'b0, id_ex_ctrl},                      // [287:256] ID/EX ctrl
    id_ex_imm,                               // [255:224]
    id_ex_rs2_data,                          // [223:192]
    id_ex_rs1_data,                          // [191:160]
    id_ex_pc,                                // [159:128]
    {28'd0, if_id_stop_code, if_id_valid},   // [127:96]  IF/ID ctrl
    if_id_instr,                             // [95:64]
    if_id_pc,                                // [63:32]
    if_pc                                    // [31:0]    PC
  };

endmodule

`default_nettype wire
