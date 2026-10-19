`timescale 1ns/1ps
`default_nettype none

// Instruction decoder / control unit (combinational, ID stage).
// See docs/arquitectura.md 2.2 (illegal instructions) and 2.4 (signals).
// - rs1/rs2 are "effective": 0 when the instruction does not read them, so
//   the hazard and forwarding units never see false dependencies.
// - rd is 0 and reg_write is 0 when the instruction writes no register
//   (including writes to x0).
// - funct3 is passed through only for loads, stores and branches.
// - halt_cond: stop_code != 0, ebreak, or an illegal instruction. When set,
//   every other control output is 0 and halt_reason gives the cause with
//   priority stop_code > HALT (ebreak) > ILLEGAL.

module decoder (
  input  wire [31:0] instr,
  input  wire [2:0]  stop_code,
  output reg  [4:0]  rs1,
  output reg  [4:0]  rs2,
  output reg  [4:0]  rd,
  output reg  [3:0]  alu_op,
  output reg         alu_src,
  output reg         link,
  output reg         reg_write,
  output reg         mem_read,
  output reg         mem_write,
  output reg  [2:0]  funct3,
  output reg         branch,
  output reg         jalr,
  output reg         jal,
  output reg  [2:0]  imm_sel,
  output reg         halt_cond,
  output reg  [2:0]  halt_reason
);

  // Major opcodes
  localparam [6:0] OP_LOAD   = 7'b0000011;
  localparam [6:0] OP_IMM    = 7'b0010011;
  localparam [6:0] OP_STORE  = 7'b0100011;
  localparam [6:0] OP_OP     = 7'b0110011;
  localparam [6:0] OP_LUI    = 7'b0110111;
  localparam [6:0] OP_BRANCH = 7'b1100011;
  localparam [6:0] OP_JALR   = 7'b1100111;
  localparam [6:0] OP_JAL    = 7'b1101111;
  localparam [6:0] OP_SYSTEM = 7'b1110011;

  localparam [31:0] EBREAK = 32'h00100073;

  localparam [6:0] F7_ZERO = 7'b0000000;
  localparam [6:0] F7_ALT  = 7'b0100000;  // sub, sra, srai

  localparam [2:0] F3_ADD_SUB = 3'b000;
  localparam [2:0] F3_SLL     = 3'b001;
  localparam [2:0] F3_SRL_SRA = 3'b101;

  localparam [3:0] ALU_ADD = 4'b0000;

  localparam [2:0] IMM_I = 3'd0;
  localparam [2:0] IMM_S = 3'd1;
  localparam [2:0] IMM_B = 3'd2;
  localparam [2:0] IMM_U = 3'd3;
  localparam [2:0] IMM_J = 3'd4;

  localparam [2:0] HALT_NONE    = 3'd0;
  localparam [2:0] HALT_EBREAK  = 3'd1;
  localparam [2:0] HALT_ILLEGAL = 3'd2;

  wire [6:0] opcode = instr[6:0];
  wire [4:0] f_rd   = instr[11:7];
  wire [2:0] f3     = instr[14:12];
  wire [4:0] f_rs1  = instr[19:15];
  wire [4:0] f_rs2  = instr[24:20];
  wire [6:0] f7     = instr[31:25];

  reg legal;
  reg is_ebreak;
  reg writes_rd;  // the instruction writes rd (before the rd != 0 check)

  always @(*) begin
    // Defaults: an instruction that does nothing, assumed illegal.
    rs1         = 5'd0;
    rs2         = 5'd0;
    rd          = 5'd0;
    alu_op      = ALU_ADD;
    alu_src     = 1'b0;
    link        = 1'b0;
    reg_write   = 1'b0;
    mem_read    = 1'b0;
    mem_write   = 1'b0;
    funct3      = 3'd0;
    branch      = 1'b0;
    jalr        = 1'b0;
    jal         = 1'b0;
    imm_sel     = IMM_I;
    halt_cond   = 1'b0;
    halt_reason = HALT_NONE;
    legal       = 1'b0;
    is_ebreak   = 1'b0;
    writes_rd   = 1'b0;

    case (opcode)
      OP_OP: begin
        legal     = (f7 == F7_ZERO) ||
                    (f7 == F7_ALT && (f3 == F3_ADD_SUB || f3 == F3_SRL_SRA));
        rs1       = f_rs1;
        rs2       = f_rs2;
        writes_rd = 1'b1;
        alu_op    = {f7[5], f3};
      end
      OP_IMM: begin
        if (f3 == F3_SLL)
          legal = (f7 == F7_ZERO);
        else if (f3 == F3_SRL_SRA)
          legal = (f7 == F7_ZERO) || (f7 == F7_ALT);
        else
          legal = 1'b1;
        rs1       = f_rs1;
        writes_rd = 1'b1;
        alu_src   = 1'b1;
        alu_op    = {(f3 == F3_SRL_SRA) ? instr[30] : 1'b0, f3};
      end
      OP_LOAD: begin
        legal     = (f3 == 3'b000) || (f3 == 3'b001) || (f3 == 3'b010) ||
                    (f3 == 3'b100) || (f3 == 3'b101);
        rs1       = f_rs1;
        writes_rd = 1'b1;
        alu_src   = 1'b1;
        mem_read  = 1'b1;
        funct3    = f3;
      end
      OP_STORE: begin
        legal     = (f3 == 3'b000) || (f3 == 3'b001) || (f3 == 3'b010);
        rs1       = f_rs1;
        rs2       = f_rs2;
        alu_src   = 1'b1;
        mem_write = 1'b1;
        funct3    = f3;
        imm_sel   = IMM_S;
      end
      OP_BRANCH: begin
        legal     = (f3 == 3'b000) || (f3 == 3'b001);
        rs1       = f_rs1;
        rs2       = f_rs2;
        branch    = 1'b1;
        funct3    = f3;
        imm_sel   = IMM_B;
      end
      OP_JALR: begin
        legal     = (f3 == 3'b000);
        rs1       = f_rs1;
        writes_rd = 1'b1;
        alu_src   = 1'b1;
        link      = 1'b1;
        jalr      = 1'b1;
      end
      OP_JAL: begin
        legal     = 1'b1;
        writes_rd = 1'b1;
        link      = 1'b1;
        jal       = 1'b1;
        imm_sel   = IMM_J;
      end
      OP_LUI: begin
        legal     = 1'b1;
        writes_rd = 1'b1;
        alu_src   = 1'b1;  // rs1 = x0, so the ALU computes 0 + imm_U
        imm_sel   = IMM_U;
      end
      OP_SYSTEM: begin
        is_ebreak = (instr == EBREAK);
      end
      default: begin
        legal = 1'b0;
      end
    endcase

    if (writes_rd && f_rd != 5'd0) begin
      rd        = f_rd;
      reg_write = 1'b1;
    end

    if (stop_code != 3'd0 || is_ebreak || !legal) begin
      halt_cond   = 1'b1;
      halt_reason = (stop_code != 3'd0) ? stop_code :
                    is_ebreak           ? HALT_EBREAK : HALT_ILLEGAL;
      rs1         = 5'd0;
      rs2         = 5'd0;
      rd          = 5'd0;
      alu_op      = ALU_ADD;
      alu_src     = 1'b0;
      link        = 1'b0;
      reg_write   = 1'b0;
      mem_read    = 1'b0;
      mem_write   = 1'b0;
      funct3      = 3'd0;
      branch      = 1'b0;
      jalr        = 1'b0;
      jal         = 1'b0;
      imm_sel     = IMM_I;
    end
  end

endmodule

`default_nettype wire
