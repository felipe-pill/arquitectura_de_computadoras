"""RV32I subset used in TP3: encodings, strict decoder, encoder, disassembler.

Shared by the assembler, the ISS and the host CLI. The decoder is the
reference for the hardware decoder: it rejects exactly what
docs/arquitectura.md section 2.2 calls illegal, and it zeroes the register
fields an instruction does not use ("effective" rs1/rs2/rd), like the RTL does.
"""

from dataclasses import dataclass

MASK32 = 0xFFFFFFFF
NOP = 0x00000013     # addi x0, x0, 0
EBREAK = 0x00100073  # HALT

# Halt reasons (docs/arquitectura.md 5.1, docs/protocol.md 6.1)
HALT_NONE = 0
HALT_EBREAK = 1
HALT_ILLEGAL = 2
HALT_OOR = 3
HALT_TIMEOUT = 4
HALT_REASON_NAMES = {
    HALT_NONE: "NONE",
    HALT_EBREAK: "HALT",
    HALT_ILLEGAL: "ILLEGAL",
    HALT_OOR: "OOR",
    HALT_TIMEOUT: "TIMEOUT",
}

# Major opcodes
OP_LOAD = 0b0000011
OP_IMM = 0b0010011
OP_STORE = 0b0100011
OP_OP = 0b0110011
OP_LUI = 0b0110111
OP_BRANCH = 0b1100011
OP_JALR = 0b1100111
OP_JAL = 0b1101111
OP_SYSTEM = 0b1110011

# name -> (funct3, funct7)
R_OPS = {
    "add": (0b000, 0b0000000),
    "sub": (0b000, 0b0100000),
    "sll": (0b001, 0b0000000),
    "slt": (0b010, 0b0000000),
    "sltu": (0b011, 0b0000000),
    "xor": (0b100, 0b0000000),
    "srl": (0b101, 0b0000000),
    "sra": (0b101, 0b0100000),
    "or": (0b110, 0b0000000),
    "and": (0b111, 0b0000000),
}
# name -> funct3
I_ALU_OPS = {"addi": 0b000, "slti": 0b010, "sltiu": 0b011,
             "xori": 0b100, "ori": 0b110, "andi": 0b111}
# name -> (funct3, funct7)
SHIFT_IMM_OPS = {"slli": (0b001, 0b0000000),
                 "srli": (0b101, 0b0000000),
                 "srai": (0b101, 0b0100000)}
LOAD_OPS = {"lb": 0b000, "lh": 0b001, "lw": 0b010, "lbu": 0b100, "lhu": 0b101}
STORE_OPS = {"sb": 0b000, "sh": 0b001, "sw": 0b010}
BRANCH_OPS = {"beq": 0b000, "bne": 0b001}

ABI_NAMES = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2",
             "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
             "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7",
             "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]
REGISTERS = {f"x{i}": i for i in range(32)}
REGISTERS.update({name: i for i, name in enumerate(ABI_NAMES)})
REGISTERS["fp"] = 8


def sext(value, bits):
    """Sign-extend the low `bits` of value to a Python int."""
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def to_signed(value):
    return sext(value, 32)


@dataclass(frozen=True)
class Instr:
    """A decoded instruction. Unused register fields are 0.

    imm is the sign-extended immediate, except for lui (the 20-bit field,
    0..0xFFFFF) and shifts (the shift amount).
    """
    name: str
    rd: int = 0
    rs1: int = 0
    rs2: int = 0
    imm: int = 0

    @property
    def is_load(self):
        return self.name in LOAD_OPS


def _bits(word, hi, lo):
    return (word >> lo) & ((1 << (hi - lo + 1)) - 1)


def decode(word):
    """Decode a 32-bit word. Returns an Instr, or None if it is illegal."""
    word &= MASK32
    opcode = _bits(word, 6, 0)
    rd = _bits(word, 11, 7)
    funct3 = _bits(word, 14, 12)
    rs1 = _bits(word, 19, 15)
    rs2 = _bits(word, 24, 20)
    funct7 = _bits(word, 31, 25)
    imm_i = sext(word >> 20, 12)

    if opcode == OP_OP:
        for name, (f3, f7) in R_OPS.items():
            if (f3, f7) == (funct3, funct7):
                return Instr(name, rd, rs1, rs2)
        return None
    if opcode == OP_IMM:
        for name, f3 in I_ALU_OPS.items():
            if f3 == funct3:
                return Instr(name, rd, rs1, 0, imm_i)
        for name, (f3, f7) in SHIFT_IMM_OPS.items():
            if (f3, f7) == (funct3, funct7):
                return Instr(name, rd, rs1, 0, rs2)  # shamt sits in the rs2 field
        return None
    if opcode == OP_LOAD:
        for name, f3 in LOAD_OPS.items():
            if f3 == funct3:
                return Instr(name, rd, rs1, 0, imm_i)
        return None
    if opcode == OP_STORE:
        imm_s = sext((funct7 << 5) | rd, 12)
        for name, f3 in STORE_OPS.items():
            if f3 == funct3:
                return Instr(name, 0, rs1, rs2, imm_s)
        return None
    if opcode == OP_BRANCH:
        imm_b = sext((_bits(word, 31, 31) << 12) | (_bits(word, 7, 7) << 11)
                     | (_bits(word, 30, 25) << 5) | (_bits(word, 11, 8) << 1), 13)
        for name, f3 in BRANCH_OPS.items():
            if f3 == funct3:
                return Instr(name, 0, rs1, rs2, imm_b)
        return None
    if opcode == OP_JALR:
        return Instr("jalr", rd, rs1, 0, imm_i) if funct3 == 0 else None
    if opcode == OP_JAL:
        imm_j = sext((_bits(word, 31, 31) << 20) | (_bits(word, 19, 12) << 12)
                     | (_bits(word, 20, 20) << 11) | (_bits(word, 30, 21) << 1), 21)
        return Instr("jal", rd, 0, 0, imm_j)
    if opcode == OP_LUI:
        return Instr("lui", rd, 0, 0, word >> 12)
    if opcode == OP_SYSTEM:
        return Instr("ebreak") if word == EBREAK else None
    return None


def _check_reg(r):
    if not 0 <= r < 32:
        raise ValueError(f"register x{r} out of range")
    return r


def _check_signed(value, bits, what):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if not lo <= value <= hi:
        raise ValueError(f"{what} {value} out of range [{lo}, {hi}]")
    return value & ((1 << bits) - 1)


def encode(ins):
    """Encode an Instr into a 32-bit word. Raises ValueError on bad fields."""
    n = ins.name
    rd, rs1, rs2 = _check_reg(ins.rd), _check_reg(ins.rs1), _check_reg(ins.rs2)
    if n in R_OPS:
        f3, f7 = R_OPS[n]
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_OP
    if n in SHIFT_IMM_OPS:
        f3, f7 = SHIFT_IMM_OPS[n]
        if not 0 <= ins.imm <= 31:
            raise ValueError(f"shift amount {ins.imm} out of range [0, 31]")
        return (f7 << 25) | (ins.imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_IMM
    if n in I_ALU_OPS or n in LOAD_OPS or n == "jalr":
        imm = _check_signed(ins.imm, 12, "immediate")
        if n in I_ALU_OPS:
            f3, op = I_ALU_OPS[n], OP_IMM
        elif n in LOAD_OPS:
            f3, op = LOAD_OPS[n], OP_LOAD
        else:
            f3, op = 0, OP_JALR
        return (imm << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
    if n in STORE_OPS:
        imm = _check_signed(ins.imm, 12, "offset")
        return (((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15)
                | (STORE_OPS[n] << 12) | ((imm & 0x1F) << 7) | OP_STORE)
    if n in BRANCH_OPS:
        if ins.imm % 2:
            raise ValueError(f"branch offset {ins.imm} is odd")
        imm = _check_signed(ins.imm, 13, "branch offset")
        return ((_bits(imm, 12, 12) << 31) | (_bits(imm, 10, 5) << 25) | (rs2 << 20)
                | (rs1 << 15) | (BRANCH_OPS[n] << 12) | (_bits(imm, 4, 1) << 8)
                | (_bits(imm, 11, 11) << 7) | OP_BRANCH)
    if n == "jal":
        if ins.imm % 2:
            raise ValueError(f"jump offset {ins.imm} is odd")
        imm = _check_signed(ins.imm, 21, "jump offset")
        return ((_bits(imm, 20, 20) << 31) | (_bits(imm, 10, 1) << 21)
                | (_bits(imm, 11, 11) << 20) | (_bits(imm, 19, 12) << 12)
                | (rd << 7) | OP_JAL)
    if n == "lui":
        if not 0 <= ins.imm <= 0xFFFFF:
            raise ValueError(f"lui immediate {ins.imm:#x} out of range [0, 0xfffff]")
        return (ins.imm << 12) | (rd << 7) | OP_LUI
    if n == "ebreak":
        return EBREAK
    raise ValueError(f"unknown instruction '{n}'")


def disassemble(word):
    """Readable text for a word, e.g. 'addi x1, x0, 5'. Offsets are relative."""
    ins = decode(word)
    if ins is None:
        return f"illegal 0x{word & MASK32:08x}"
    n = ins.name
    if n in R_OPS:
        return f"{n} x{ins.rd}, x{ins.rs1}, x{ins.rs2}"
    if n in I_ALU_OPS or n in SHIFT_IMM_OPS:
        return f"{n} x{ins.rd}, x{ins.rs1}, {ins.imm}"
    if n in LOAD_OPS or n == "jalr":
        return f"{n} x{ins.rd}, {ins.imm}(x{ins.rs1})"
    if n in STORE_OPS:
        return f"{n} x{ins.rs2}, {ins.imm}(x{ins.rs1})"
    if n in BRANCH_OPS:
        return f"{n} x{ins.rs1}, x{ins.rs2}, {ins.imm}"
    if n == "jal":
        return f"jal x{ins.rd}, {ins.imm}"
    if n == "lui":
        return f"lui x{ins.rd}, 0x{ins.imm:x}"
    return n
