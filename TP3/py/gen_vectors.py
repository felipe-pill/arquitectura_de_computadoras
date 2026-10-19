"""Generate test vectors for the TP3 Verilog testbenches.

Called by TP3/sim/prebuild.bat with the simulation build directory:
    python gen_vectors.py <out_dir>

isa_vectors.hex - decoder / imm_gen vectors, one per line (32 hex digits):
    [31:0]    expected imm (imm_gen output for the expected imm_sel)
    [63:32]   instruction word
    [100:64]  expected decoder outputs (CTRL_* fields below)
    [103:101] stop_code input
The expected decoder outputs follow docs/arquitectura.md 2.2/2.4, using
isa.decode() (itself checked against the RV32I encodings in
test_assembler.py) as the reference for legality and fields.
"""

import os
import random
import sys

import isa
from isa import Instr

# Decoder output fields inside the 37-bit ctrl value: name -> (lsb, width)
CTRL_FIELDS = {
    "rs1": (0, 5), "rs2": (5, 5), "rd": (10, 5), "alu_op": (15, 4),
    "alu_src": (19, 1), "link": (20, 1), "reg_write": (21, 1),
    "mem_read": (22, 1), "mem_write": (23, 1), "funct3": (24, 3),
    "branch": (27, 1), "jalr": (28, 1), "jal": (29, 1), "imm_sel": (30, 3),
    "halt_cond": (33, 1), "halt_reason": (34, 3),
}
IMM_I, IMM_S, IMM_B, IMM_U, IMM_J = range(5)
MAX_ISA_VECTORS = 4096  # array size in tb_decoder.v / tb_imm_gen.v
STOP_OOR, STOP_TIMEOUT = isa.HALT_OOR, isa.HALT_TIMEOUT


def imm_of(word, sel):
    """Immediate of each RV32I format, straight from the spec bit layout."""
    b = lambda hi, lo: (word >> lo) & ((1 << (hi - lo + 1)) - 1)
    if sel == IMM_I:
        v = isa.sext(b(31, 20), 12)
    elif sel == IMM_S:
        v = isa.sext((b(31, 25) << 5) | b(11, 7), 12)
    elif sel == IMM_B:
        v = isa.sext((b(31, 31) << 12) | (b(7, 7) << 11) | (b(30, 25) << 5) | (b(11, 8) << 1), 13)
    elif sel == IMM_U:
        v = b(31, 12) << 12
    elif sel == IMM_J:
        v = isa.sext((b(31, 31) << 20) | (b(19, 12) << 12) | (b(20, 20) << 11) | (b(30, 21) << 1), 21)
    else:
        v = 0
    return v & isa.MASK32


def expected_ctrl(word, stop_code):
    """Expected decoder outputs as a dict (docs/arquitectura.md 2.4)."""
    c = {name: 0 for name in CTRL_FIELDS}
    ins = isa.decode(word)
    if stop_code or ins is None or ins.name == "ebreak":
        c["halt_cond"] = 1
        c["halt_reason"] = (stop_code if stop_code else
                            isa.HALT_ILLEGAL if ins is None else isa.HALT_EBREAK)
        return c

    n = ins.name
    f3 = (word >> 12) & 7
    alt = (word >> 30) & 1
    c["rs1"], c["rs2"] = ins.rs1, ins.rs2
    writes = n not in isa.STORE_OPS and n not in isa.BRANCH_OPS
    if writes and ins.rd != 0:
        c["rd"], c["reg_write"] = ins.rd, 1

    if n in isa.R_OPS:
        c["alu_op"] = (alt << 3) | f3
    elif n in isa.I_ALU_OPS:
        c["alu_op"], c["alu_src"] = f3, 1
    elif n in isa.SHIFT_IMM_OPS:
        c["alu_op"], c["alu_src"] = (alt << 3) | f3, 1
    elif n in isa.LOAD_OPS:
        c["alu_src"], c["mem_read"], c["funct3"] = 1, 1, f3
    elif n in isa.STORE_OPS:
        c["alu_src"], c["mem_write"], c["funct3"], c["imm_sel"] = 1, 1, f3, IMM_S
    elif n in isa.BRANCH_OPS:
        c["branch"], c["funct3"], c["imm_sel"] = 1, f3, IMM_B
    elif n == "jalr":
        c["alu_src"], c["link"], c["jalr"] = 1, 1, 1
    elif n == "jal":
        c["link"], c["jal"], c["imm_sel"] = 1, 1, IMM_J
    elif n == "lui":
        c["alu_src"], c["imm_sel"] = 1, IMM_U
    else:
        raise AssertionError(n)
    return c


def pack_ctrl(c):
    value = 0
    for name, (lsb, width) in CTRL_FIELDS.items():
        assert 0 <= c[name] < (1 << width), (name, c[name])
        value |= c[name] << lsb
    return value


def isa_vector(word, stop_code=0):
    c = expected_ctrl(word, stop_code)
    imm = imm_of(word, c["imm_sel"])
    return (stop_code << 101) | (pack_ctrl(c) << 64) | (word << 32) | imm


def random_legal(rng, name):
    r = lambda: rng.randrange(32)
    if name in isa.R_OPS:
        return Instr(name, r(), r(), r())
    if name in isa.SHIFT_IMM_OPS:
        return Instr(name, r(), r(), 0, r())
    if name in isa.I_ALU_OPS or name in isa.LOAD_OPS or name == "jalr":
        return Instr(name, r(), r(), 0, rng.randrange(-2048, 2048))
    if name in isa.STORE_OPS:
        return Instr(name, 0, r(), r(), rng.randrange(-2048, 2048))
    if name in isa.BRANCH_OPS:
        return Instr(name, 0, r(), r(), 2 * rng.randrange(-2048, 2048))
    if name == "jal":
        return Instr(name, r(), 0, 0, 2 * rng.randrange(-(1 << 19), 1 << 19))
    if name == "lui":
        return Instr(name, r(), 0, 0, rng.randrange(1 << 20))
    raise AssertionError(name)


def isa_words(seed=2026):
    """Instruction words to test: every instruction, edge cases, junk."""
    rng = random.Random(seed)
    names = (list(isa.R_OPS) + list(isa.I_ALU_OPS) + list(isa.SHIFT_IMM_OPS)
             + list(isa.LOAD_OPS) + list(isa.STORE_OPS) + list(isa.BRANCH_OPS)
             + ["jal", "jalr", "lui"])
    words = [isa.NOP, isa.EBREAK, 0x00000000, 0xFFFFFFFF, 0x00000073]
    for name in names:                       # legal, random fields
        for _ in range(40):
            words.append(isa.encode(random_legal(rng, name)))
        for rd in (0, 31):                   # rd = x0 must not write
            ins = random_legal(rng, name)
            if name not in isa.STORE_OPS and name not in isa.BRANCH_OPS:
                ins = Instr(ins.name, rd, ins.rs1, ins.rs2, ins.imm)
            words.append(isa.encode(ins))
    opcodes = [isa.OP_LOAD, isa.OP_IMM, isa.OP_STORE, isa.OP_OP, isa.OP_LUI,
               isa.OP_BRANCH, isa.OP_JALR, isa.OP_JAL, isa.OP_SYSTEM]
    for op in opcodes:                       # right opcode, random other bits
        for _ in range(150):
            words.append((rng.getrandbits(25) << 7) | op)
    for _ in range(500):                     # fully random words
        words.append(rng.getrandbits(32))
    return words


def write_isa_vectors(path, seed=2026):
    rng = random.Random(seed + 1)
    words = isa_words(seed)
    vectors = [isa_vector(w) for w in words]
    for w in rng.sample(words, 100):         # stop_code overrides everything
        vectors.append(isa_vector(w, rng.choice((STOP_OOR, STOP_TIMEOUT))))
    assert len(vectors) <= MAX_ISA_VECTORS, "raise MAX_VEC in tb_decoder/tb_imm_gen"
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for v in vectors:
            f.write(f"{v:032x}\n")
    return len(vectors)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: gen_vectors.py <out_dir>", file=sys.stderr)
        return 2
    out_dir = argv[0]
    os.makedirs(out_dir, exist_ok=True)
    n = write_isa_vectors(os.path.join(out_dir, "isa_vectors.hex"))
    print(f"gen_vectors: {n} decoder/imm_gen vectors -> {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
