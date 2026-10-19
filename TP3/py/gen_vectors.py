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


# ---------------------------------------------------------------------------
# CPU-level tests (tb_cpu_core): programs + expected final state from the ISS
# ---------------------------------------------------------------------------

CPU_MAX_CYCLES = 3000       # must match MAX_CYCLES in tb_cpu_core.v
CPU_MAX_WORDS = 1 << 17     # stream array size in tb_cpu_core.v
CPU_MAGIC = 0xC0DE0001
ASM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "asm")

# Short programs for edge cases (same situations as test_iss.py)
EXTRA_PROGRAMS = {
    "minimal": "addi x1, x0, 5\nebreak",
    "illegal": "addi x1, x0, 1\n.word 0\naddi x1, x0, 2",
    "ecall": ".word 0x00000073",
    "timeout_loop": "loop: j loop",
    "jump_oor": "jal x0, 64\nebreak",
    "load_then_jal": "lw x1, 0(x0)\njal x2, 4\nebreak",
    "dmem_alias": "lui x1, 1\naddi x2, x0, 77\nsw x2, 4(x1)\nlw x3, 4(x0)\nebreak",
    "misaligned": """
        addi x1, x0, 0x100
        lui  x2, 0x11223
        addi x2, x2, 0x344
        sw   x2, 2(x1)
        lw   x3, 3(x1)
        lhu  x4, 1(x1)
        lhu  x5, 3(x1)
        addi x6, x0, 0x55
        sh   x6, 3(x1)
        lw   x7, 0(x1)
        ebreak""",
    "misaligned_fetch": "addi x5, x0, 10\njalr x0, 0(x5)\naddi x6, x0, 1\nebreak",
    "branch_after_load_x0": "lw x0, 0(x0)\nbeq x0, x0, 8\nnop\nebreak",
    "jalr_after_load": "addi x1, x0, 16\nsw x1, 0(x0)\nlw x2, 0(x0)\njalr x3, 0(x2)\nebreak",
    "store_after_load": "addi x1, x0, 9\nsw x1, 0(x0)\nlw x2, 0(x0)\nsw x2, 8(x0)\nebreak",
    "back_to_back_jal": "jal x1, 4\njal x2, 4\njal x3, 4\nebreak",
    "branch_to_branch": "beq x0, x0, 4\nbeq x0, x0, 4\nbne x0, x0, -8\nebreak",
    "illegal_wrong_path": "beq x0, x0, 8\n.word 0\nebreak",
    "oor_wrong_path": "addi x1, x0, 1\nbeq x0, x0, -4",
}


def random_program(rng, n_instr):
    """A random program over the whole subset, ending with ebreak.

    Registers are mostly x0..x7 so dependencies (forwarding, load-use) are
    dense. Branch and jal offsets are short and mostly forward; the backward
    ones make some programs loop until TIMEOUT. Most jalr targets are forward
    inside the program (x0 + absolute address); the rest use a register value
    and land anywhere (usually OOR). About 1 program in 10 gets one illegal word.
    The ISS models every one of these endings exactly.
    """
    def reg():
        return rng.randrange(8) if rng.random() < 0.85 else rng.randrange(32)

    def short_offset(p_back, back, fwd):
        if rng.random() < p_back:
            return 4 * rng.randrange(-back, 0)
        return 4 * rng.randrange(1, fwd + 1)

    kinds = (["r"] * 25 + ["i"] * 25 + ["load"] * 15 + ["store"] * 12
             + ["branch"] * 10 + ["lui"] * 5 + ["jal"] * 4 + ["jalr"] * 2)
    words = []
    for _ in range(n_instr):
        k = rng.choice(kinds)
        if k == "r":
            ins = Instr(rng.choice(list(isa.R_OPS)), reg(), reg(), reg())
        elif k == "i":
            name = rng.choice(list(isa.I_ALU_OPS) + list(isa.SHIFT_IMM_OPS))
            imm = rng.randrange(32) if name in isa.SHIFT_IMM_OPS else rng.randrange(-2048, 2048)
            ins = Instr(name, reg(), reg(), 0, imm)
        elif k == "load":
            ins = Instr(rng.choice(list(isa.LOAD_OPS)), reg(), reg(), 0, rng.randrange(-64, 64))
        elif k == "store":
            ins = Instr(rng.choice(list(isa.STORE_OPS)), 0, reg(), reg(), rng.randrange(-64, 64))
        elif k == "branch":
            ins = Instr(rng.choice(list(isa.BRANCH_OPS)), 0, reg(), reg(), short_offset(0.2, 6, 4))
        elif k == "lui":
            ins = Instr("lui", reg(), 0, 0, rng.randrange(1 << 20))
        elif k == "jal":
            ins = Instr("jal", reg(), 0, 0, short_offset(0.1, 4, 4))
        elif rng.random() < 0.8:  # jalr forward to an address inside the program
            ins = Instr("jalr", reg(), 0, 0, 4 * rng.randrange(len(words) + 1, n_instr + 1))
        else:                     # jalr through a register value
            ins = Instr("jalr", reg(), reg(), 0, rng.randrange(-16, 64))
        words.append(isa.encode(ins))
    if rng.random() < 0.1:
        words[rng.randrange(n_instr)] = rng.getrandbits(32) & ~0x7F  # opcode 0: illegal
    words.append(isa.EBREAK)
    return words


def cpu_test_programs(seed=2026, n_random=80):
    """(name, words) for every CPU-level test."""
    import assembler
    tests = []
    for fname in sorted(os.listdir(ASM_DIR)):
        if fname.endswith(".s"):
            with open(os.path.join(ASM_DIR, fname), encoding="utf-8") as f:
                tests.append((fname[:-2], assembler.assemble(f.read())))
    for name, src in EXTRA_PROGRAMS.items():
        tests.append((name, assembler.assemble(src)))
    rng = random.Random(seed)
    for i in range(n_random):
        tests.append((f"random_{i:02d}", random_program(rng, rng.randrange(40, 120))))
    return tests


def _name_words(name):
    raw = name.encode("ascii")[:16].rjust(16, b" ")
    return [int.from_bytes(raw[i:i + 4], "big") for i in range(0, 16, 4)]


def write_cpu_tests(path, seed=2026):
    """cpu_tests.hex: a stream of 32-bit words, one per line:
        magic, n_tests, max_cycles, then per test:
        name (4 words, ASCII), prog_len, program words,
        exp_pc, exp_cycles, exp_reason, exp_dmem_used,
        x0..x31, dmem words [0, dmem_used)
    """
    import iss
    stream = []
    tests = cpu_test_programs(seed)
    reasons = {}
    for name, words in tests:
        res = iss.run(words, max_cycles=CPU_MAX_CYCLES)
        reasons[res.halt_reason] = reasons.get(res.halt_reason, 0) + 1
        stream += _name_words(name)
        stream += [len(words)] + words
        stream += [res.pc, res.cycles, res.halt_reason, res.dmem_used]
        stream += res.regs + res.used_dmem()
    stream = [CPU_MAGIC, len(tests), CPU_MAX_CYCLES] + stream
    assert len(stream) <= CPU_MAX_WORDS, "raise MAX_WORDS in tb_cpu_core.v"
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for w in stream:
            f.write(f"{w & isa.MASK32:08x}\n")
    return len(tests), reasons


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: gen_vectors.py <out_dir>", file=sys.stderr)
        return 2
    out_dir = argv[0]
    os.makedirs(out_dir, exist_ok=True)
    n = write_isa_vectors(os.path.join(out_dir, "isa_vectors.hex"))
    print(f"gen_vectors: {n} decoder/imm_gen vectors")
    n, reasons = write_cpu_tests(os.path.join(out_dir, "cpu_tests.hex"))
    summary = ", ".join(f"{isa.HALT_REASON_NAMES[r]}={c}" for r, c in sorted(reasons.items()))
    print(f"gen_vectors: {n} CPU tests ({summary}) -> {out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
