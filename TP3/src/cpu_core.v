`timescale 1ns/1ps
`default_nettype none

module cpu_core (
    input  wire        clk,
    input  wire        rst,

    // Instruction memory
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,

    // Data memory
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    input  wire [31:0] dmem_rdata,
    output wire        dmem_we,
    output wire  [3:0] dmem_be,

    // Debug (solo IF/ID por ahora)
    output wire [31:0] dbg_if_id_pc,
    output wire [31:0] dbg_if_id_instr
);

  // -------------------------
  // ALU op codes (must match alu.v)
  // -------------------------
  localparam [3:0]
    ALU_ADD_OP = 4'd0,
    ALU_SUB_OP = 4'd1;

  // -------------------------
  // RISC-V opcodes (subset)
  // -------------------------
  localparam [6:0]
    OPCODE_OP      = 7'b0110011, // R-type
    OPCODE_OP_IMM  = 7'b0010011, // I-type arithmetic
    OPCODE_LOAD    = 7'b0000011, // loads
    OPCODE_STORE   = 7'b0100011; // stores

  // ============================================================
  // IF stage
  // ============================================================
  reg  [31:0] pc;
  wire [31:0] pc_next;

  assign imem_addr = pc;
  assign pc_next   = pc + 32'd4;  // no branches yet

  // ============================================================
  // IF/ID pipeline regs
  // ============================================================
  reg [31:0] if_id_pc;
  reg [31:0] if_id_instr;

  // ============================================================
  // ID stage: regfile, decode, immgen
  // ============================================================
  wire [4:0] rs1 = if_id_instr[19:15];
  wire [4:0] rs2 = if_id_instr[24:20];
  wire [4:0] rd  = if_id_instr[11:7];

  wire [31:0] rs1_data;
  wire [31:0] rs2_data;

  // Forward-declared WB signals
  wire [31:0] wb_data;
  reg         mem_wb_reg_write;
  reg  [4:0]  mem_wb_rd;

  regfile u_regfile (
      .clk      (clk),
      .rs1      (rs1),
      .rs2      (rs2),
      .rd       (mem_wb_rd),
      .wd       (wb_data),
      .we       (mem_wb_reg_write),
      .rs1_data (rs1_data),
      .rs2_data (rs2_data)
  );

  // Decode outputs (combinational)
  reg        dec_reg_write;
  reg        dec_mem_read;
  reg        dec_mem_write;
  reg        dec_mem_to_reg;
  reg        dec_use_imm;
  reg  [3:0] dec_alu_op;
  reg [31:0] dec_imm;

  // Fields
  wire [6:0] dec_opcode = if_id_instr[6:0];
  wire [2:0] dec_funct3 = if_id_instr[14:12];
  wire [6:0] dec_funct7 = if_id_instr[31:25];

  always @* begin
    // Defaults = NOP
    dec_reg_write  = 1'b0;
    dec_mem_read   = 1'b0;
    dec_mem_write  = 1'b0;
    dec_mem_to_reg = 1'b0;
    dec_use_imm    = 1'b0;
    dec_alu_op     = ALU_ADD_OP;
    dec_imm        = 32'h0;

    case (dec_opcode)
      OPCODE_OP: begin
        // R-type: ADD / SUB (funct3=000)
        if (dec_funct3 == 3'b000) begin
          dec_reg_write = 1'b1;
          dec_use_imm   = 1'b0;
          dec_mem_to_reg= 1'b0;
          if (dec_funct7 == 7'b0100000)
            dec_alu_op = ALU_SUB_OP; // SUB
          else
            dec_alu_op = ALU_ADD_OP; // ADD
        end
      end

      OPCODE_OP_IMM: begin
        // I-type arithmetic: ADDI (funct3=000)
        if (dec_funct3 == 3'b000) begin
          dec_reg_write  = 1'b1;
          dec_use_imm    = 1'b1;
          dec_mem_to_reg = 1'b0;
          dec_alu_op     = ALU_ADD_OP;
          dec_imm        = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
        end
      end

      OPCODE_LOAD: begin
        // LW (funct3=010)
        if (dec_funct3 == 3'b010) begin
          dec_reg_write  = 1'b1;
          dec_mem_read   = 1'b1;
          dec_mem_to_reg = 1'b1;
          dec_use_imm    = 1'b1;
          dec_alu_op     = ALU_ADD_OP;  // addr = rs1 + imm
          dec_imm        = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
        end
      end

      OPCODE_STORE: begin
        // SW (funct3=010)
        if (dec_funct3 == 3'b010) begin
          dec_mem_write  = 1'b1;
          dec_use_imm    = 1'b1;
          dec_alu_op     = ALU_ADD_OP; // addr = rs1 + imm
          dec_imm        = {{20{if_id_instr[31]}},
                            if_id_instr[31:25],
                            if_id_instr[11:7]};
        end
      end

      default: begin
        // NOP
      end
    endcase
  end

  // ============================================================
  // ID/EX pipeline regs
  // ============================================================
  reg [31:0] id_ex_pc;
  reg [31:0] id_ex_rs1_data;
  reg [31:0] id_ex_rs2_data;
  reg [31:0] id_ex_imm;
  reg  [4:0] id_ex_rs1;
  reg  [4:0] id_ex_rs2;
  reg  [4:0] id_ex_rd;

  reg        id_ex_reg_write;
  reg        id_ex_mem_read;
  reg        id_ex_mem_write;
  reg        id_ex_mem_to_reg;
  reg        id_ex_use_imm;
  reg  [3:0] id_ex_alu_op;

  // ============================================================
  // EX stage: Forwarding + ALU
  // ============================================================
  reg  [1:0] forward_a;
  reg  [1:0] forward_b;
  wire [31:0] fwd_rs1;
  wire [31:0] fwd_rs2;

  // EX/MEM & MEM/WB signals used in forwarding
  reg [31:0] ex_mem_alu_result;
  reg [31:0] ex_mem_rs2_data;
  reg  [4:0] ex_mem_rd;
  reg        ex_mem_reg_write;
  reg        ex_mem_mem_read;
  reg        ex_mem_mem_write;
  reg        ex_mem_mem_to_reg;

  reg [31:0] mem_wb_alu_result;
  reg [31:0] mem_wb_mem_data;
  reg        mem_wb_mem_to_reg;

  // WB mux
  assign wb_data = mem_wb_mem_to_reg ? mem_wb_mem_data
                                     : mem_wb_alu_result;

  // Forwarding control
  always @* begin
    // defaults: no forwarding
    forward_a = 2'b00;
    forward_b = 2'b00;

    // EX hazard: EX/MEM → EX
    if (ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
        (ex_mem_rd == id_ex_rs1)) begin
      forward_a = 2'b10;
    end
    else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) &&
             (mem_wb_rd == id_ex_rs1)) begin
      forward_a = 2'b01;
    end

    if (ex_mem_reg_write && (ex_mem_rd != 5'd0) &&
        (ex_mem_rd == id_ex_rs2)) begin
      forward_b = 2'b10;
    end
    else if (mem_wb_reg_write && (mem_wb_rd != 5'd0) &&
             (mem_wb_rd == id_ex_rs2)) begin
      forward_b = 2'b01;
    end
  end

  // Forwarded operands
  assign fwd_rs1 = (forward_a == 2'b10) ? ex_mem_alu_result :
                   (forward_a == 2'b01) ? wb_data :
                                          id_ex_rs1_data;

  assign fwd_rs2 = (forward_b == 2'b10) ? ex_mem_alu_result :
                   (forward_b == 2'b01) ? wb_data :
                                          id_ex_rs2_data;

  // ALU inputs
  wire [31:0] alu_a = fwd_rs1;
  wire [31:0] alu_b = id_ex_use_imm ? id_ex_imm : fwd_rs2;

  wire [31:0] alu_result;
  wire        alu_zero, alu_neg, alu_carry, alu_overflow;

  alu u_alu (
      .a        (alu_a),
      .b        (alu_b),
      .op       (id_ex_alu_op),
      .result   (alu_result),
      .zero     (alu_zero),
      .neg      (alu_neg),
      .carry    (alu_carry),
      .overflow (alu_overflow)
  );

  // ============================================================
  // MEM stage → DMEM
  // ============================================================
  assign dmem_addr  = ex_mem_alu_result;
  assign dmem_wdata = ex_mem_rs2_data;  // already forwarded rs2_data
  assign dmem_we    = ex_mem_mem_write;
  assign dmem_be    = 4'b1111;

  // ============================================================
  // Hazard detection: load-use stall
  // ============================================================
  wire load_hazard;

  assign load_hazard =
      id_ex_mem_read &&
      (id_ex_rd != 5'd0) &&
      ((id_ex_rd == rs1) || (id_ex_rd == rs2));

  wire stall_pc    = load_hazard;
  wire stall_if_id = load_hazard;

  // ============================================================
  // Clocked stuff: PC + pipeline regs
  // ============================================================
  always @(posedge clk) begin
    if (rst) begin
      pc          <= 32'h00000000;
      if_id_pc    <= 32'h0;
      if_id_instr <= 32'h00000013; // NOP

      id_ex_pc         <= 32'h0;
      id_ex_rs1_data   <= 32'h0;
      id_ex_rs2_data   <= 32'h0;
      id_ex_imm        <= 32'h0;
      id_ex_rs1        <= 5'd0;
      id_ex_rs2        <= 5'd0;
      id_ex_rd         <= 5'd0;
      id_ex_reg_write  <= 1'b0;
      id_ex_mem_read   <= 1'b0;
      id_ex_mem_write  <= 1'b0;
      id_ex_mem_to_reg <= 1'b0;
      id_ex_use_imm    <= 1'b0;
      id_ex_alu_op     <= ALU_ADD_OP;

      ex_mem_alu_result <= 32'h0;
      ex_mem_rs2_data   <= 32'h0;
      ex_mem_rd         <= 5'd0;
      ex_mem_reg_write  <= 1'b0;
      ex_mem_mem_read   <= 1'b0;
      ex_mem_mem_write  <= 1'b0;
      ex_mem_mem_to_reg <= 1'b0;

      mem_wb_alu_result <= 32'h0;
      mem_wb_mem_data   <= 32'h0;
      mem_wb_rd         <= 5'd0;
      mem_wb_reg_write  <= 1'b0;
      mem_wb_mem_to_reg <= 1'b0;

    end else begin
      // PC update
      if (!stall_pc)
        pc <= pc_next;

      // IF/ID update
      if (!stall_if_id) begin
        if_id_pc    <= pc;
        if_id_instr <= imem_rdata;
      end

      // ID/EX update
      if (load_hazard) begin
        // Insert bubble (NOP) in EX
        id_ex_pc         <= 32'h0;
        id_ex_rs1_data   <= 32'h0;
        id_ex_rs2_data   <= 32'h0;
        id_ex_imm        <= 32'h0;
        id_ex_rs1        <= 5'd0;
        id_ex_rs2        <= 5'd0;
        id_ex_rd         <= 5'd0;
        id_ex_reg_write  <= 1'b0;
        id_ex_mem_read   <= 1'b0;
        id_ex_mem_write  <= 1'b0;
        id_ex_mem_to_reg <= 1'b0;
        id_ex_use_imm    <= 1'b0;
        id_ex_alu_op     <= ALU_ADD_OP;
      end else begin
        id_ex_pc         <= if_id_pc;
        id_ex_rs1_data   <= rs1_data;
        id_ex_rs2_data   <= rs2_data;
        id_ex_imm        <= dec_imm;
        id_ex_rs1        <= rs1;
        id_ex_rs2        <= rs2;
        id_ex_rd         <= rd;
        id_ex_reg_write  <= dec_reg_write;
        id_ex_mem_read   <= dec_mem_read;
        id_ex_mem_write  <= dec_mem_write;
        id_ex_mem_to_reg <= dec_mem_to_reg;
        id_ex_use_imm    <= dec_use_imm;
        id_ex_alu_op     <= dec_alu_op;
      end

      // EX/MEM
      ex_mem_alu_result <= alu_result;
      ex_mem_rs2_data   <= fwd_rs2;    // NOTE: forwarded value
      ex_mem_rd         <= id_ex_rd;
      ex_mem_reg_write  <= id_ex_reg_write;
      ex_mem_mem_read   <= id_ex_mem_read;
      ex_mem_mem_write  <= id_ex_mem_write;
      ex_mem_mem_to_reg <= id_ex_mem_to_reg;

      // MEM/WB
      mem_wb_alu_result <= ex_mem_alu_result;
      mem_wb_mem_data   <= dmem_rdata;
      mem_wb_rd         <= ex_mem_rd;
      mem_wb_reg_write  <= ex_mem_reg_write;
      mem_wb_mem_to_reg <= ex_mem_mem_to_reg;
    end
  end

  // Debug taps
  assign dbg_if_id_pc    = if_id_pc;
  assign dbg_if_id_instr = if_id_instr;

endmodule

`default_nettype wire
