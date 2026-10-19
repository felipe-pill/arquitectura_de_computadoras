"""Reference instruction-set simulator for the TP3 RV32I subset.

Models what the hardware reports at the end of a run, so the hardware
testbenches and the debug dumps can be compared against it:
- architectural state: x0..x31, PC, data memory, dmem_used (high-water mark);
- halt reason: HALT (ebreak), ILLEGAL, OOR (fetch past the loaded program),
  TIMEOUT (cycle limit);
- the exact cycle count of the 5-stage pipeline (docs/arquitectura.md 3.3, 5).

Hardware semantics reproduced (docs/arquitectura.md 1.4, 2.3, 5.2):
- separate imem/dmem address spaces, both from 0; address bits above the
  memory size are ignored (aliasing);
- lw/sw ignore addr[1:0], lh/lhu/sh ignore addr[0]; fetch ignores PC[1:0];
- all registers and dmem start at 0;
- the final PC is the address of the instruction that stopped execution.

Cycle model: let d(k) be the cycle in which dynamic instruction k is in ID
(cycle 1 is the first enabled cycle after reset, so d(0) = 2). Then
    d(k+1) = d(k) + 1 + stall(k) + penalty(k)
with stall(k) = 1 for a load-use dependency on k-1, and penalty(k) = 1 for
jal, 2 for jalr and taken beq/bne. A fetch latched while cycle_cnt >=
max_cycles becomes a TIMEOUT slot, i.e. slot k stops if d(k) - 2 >= max_cycles.
The halting slot reaches WB and sets `halted` at cycle d + 3, which is the
final cycle count.

Usage:
    python iss.py prog.s [--max-cycles N]     # also accepts .hex / .bin
"""

import argparse
import struct
import sys
from dataclasses import dataclass

import isa
from isa import MASK32

IMEM_DEPTH = 1024  # words, = 2**IMEM_ADDR_W
DMEM_DEPTH = 1024  # words, = 2**DMEM_ADDR_W
MAX_CYCLES = 1_000_000


@dataclass
class Result:
    regs: list           # 32 unsigned 32-bit values
    pc: int              # address of the instruction that stopped execution
    dmem: list           # full data memory, DMEM_DEPTH words
    dmem_used: int       # high-water mark in words
    cycles: int          # enabled cycles until `halted`
    instret: int         # instructions executed (the halting slot excluded)
    halt_reason: int     # isa.HALT_*

    def used_dmem(self):
        return self.dmem[:self.dmem_used]


def _alu(name, a, b):
    """32-bit ALU. a, b unsigned; returns unsigned."""
    sa, sb = isa.to_signed(a), isa.to_signed(b)
    sh = b & 0x1F
    if name in ("add", "addi"):
        r = a + b
    elif name == "sub":
        r = a - b
    elif name in ("sll", "slli"):
        r = a << sh
    elif name in ("slt", "slti"):
        r = int(sa < sb)
    elif name in ("sltu", "sltiu"):
        r = int(a < b)
    elif name in ("xor", "xori"):
        r = a ^ b
    elif name in ("srl", "srli"):
        r = a >> sh
    elif name in ("sra", "srai"):
        r = sa >> sh
    elif name in ("or", "ori"):
        r = a | b
    elif name in ("and", "andi"):
        r = a & b
    else:
        raise AssertionError(name)
    return r & MASK32


def run(program, max_cycles=MAX_CYCLES, imem_depth=IMEM_DEPTH, dmem_depth=DMEM_DEPTH):
    """Run `program` (list of words, loaded at address 0) until it stops."""
    if not 1 <= len(program) <= imem_depth:
        raise ValueError(f"program must have 1..{imem_depth} words")
    imem = [w & MASK32 for w in program] + [0] * (imem_depth - len(program))
    prog_len = len(program)
    regs = [0] * 32
    dmem = [0] * dmem_depth
    dmem_used = 0
    pc = 0
    d = 2                # cycle in which the current slot is in ID
    prev_load_rd = 0     # rd of the previous instruction if it was a load
    instret = 0

    while True:
        # Halt slot? Same priority as the hardware: TIMEOUT > OOR > instruction.
        reason = isa.HALT_NONE
        ins = None
        if d - 2 >= max_cycles:
            reason = isa.HALT_TIMEOUT
        elif pc >= 4 * prog_len:
            reason = isa.HALT_OOR
        else:
            ins = isa.decode(imem[(pc >> 2) % imem_depth])
            if ins is None:
                reason = isa.HALT_ILLEGAL
            elif ins.name == "ebreak":
                reason = isa.HALT_EBREAK
        if reason != isa.HALT_NONE:
            return Result(regs, pc, dmem, dmem_used, d + 3, instret, reason)

        stall = int(prev_load_rd != 0 and prev_load_rd in (ins.rs1, ins.rs2))
        penalty = 0
        next_pc = (pc + 4) & MASK32
        a, b = regs[ins.rs1], regs[ins.rs2]
        n = ins.name
        result = None

        if n in isa.R_OPS:
            result = _alu(n, a, b)
        elif n in isa.I_ALU_OPS or n in isa.SHIFT_IMM_OPS:
            result = _alu(n, a, ins.imm & MASK32)
        elif n == "lui":
            result = (ins.imm << 12) & MASK32
        elif n == "jal":
            result = next_pc
            next_pc = (pc + ins.imm) & MASK32
            penalty = 1
        elif n == "jalr":
            result = next_pc
            next_pc = (a + ins.imm) & MASK32 & ~1
            penalty = 2
        elif n in isa.BRANCH_OPS:
            if (a == b) == (n == "beq"):
                next_pc = (pc + ins.imm) & MASK32
                penalty = 2
        elif n in isa.LOAD_OPS:
            addr = (a + ins.imm) & MASK32
            word = dmem[(addr >> 2) % dmem_depth]
            if n == "lw":
                result = word
            elif n in ("lh", "lhu"):
                half = (word >> (16 * ((addr >> 1) & 1))) & 0xFFFF
                result = isa.sext(half, 16) & MASK32 if n == "lh" else half
            else:
                byte = (word >> (8 * (addr & 3))) & 0xFF
                result = isa.sext(byte, 8) & MASK32 if n == "lb" else byte
        elif n in isa.STORE_OPS:
            addr = (a + ins.imm) & MASK32
            idx = (addr >> 2) % dmem_depth
            if n == "sw":
                dmem[idx] = b
            elif n == "sh":
                shift = 16 * ((addr >> 1) & 1)
                dmem[idx] = (dmem[idx] & ~(0xFFFF << shift) & MASK32) | ((b & 0xFFFF) << shift)
            else:
                shift = 8 * (addr & 3)
                dmem[idx] = (dmem[idx] & ~(0xFF << shift) & MASK32) | ((b & 0xFF) << shift)
            dmem_used = max(dmem_used, idx + 1)
        else:
            raise AssertionError(n)

        if result is not None and ins.rd != 0:
            regs[ins.rd] = result
        prev_load_rd = ins.rd if ins.is_load else 0
        instret += 1
        pc = next_pc
        d += 1 + stall + penalty


def load_program(path):
    """Read a program from .s/.asm (assembled), .hex ($readmemh) or .bin (LE)."""
    if path.endswith((".s", ".asm")):
        import assembler
        with open(path, encoding="utf-8") as f:
            return assembler.assemble(f.read())
    if path.endswith(".hex"):
        with open(path, encoding="ascii") as f:
            return [int(tok, 16) for tok in f.read().split()]
    if path.endswith(".bin"):
        with open(path, "rb") as f:
            data = f.read()
        if len(data) % 4:
            raise ValueError(f"{path}: size is not a multiple of 4")
        return list(struct.unpack(f"<{len(data) // 4}I", data))
    raise ValueError(f"{path}: unknown extension (use .s, .asm, .hex or .bin)")


def format_result(res):
    lines = [f"halt: {isa.HALT_REASON_NAMES[res.halt_reason]} at pc=0x{res.pc:08x}  "
             f"cycles={res.cycles}  instret={res.instret}"]
    for i in range(0, 32, 4):
        lines.append("  ".join(f"x{r:<2}={res.regs[r]:08x}" for r in range(i, i + 4)))
    lines.append(f"dmem_used={res.dmem_used} words")
    for i, w in enumerate(res.used_dmem()):
        if w:
            lines.append(f"  [0x{4 * i:04x}] = 0x{w:08x}")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description="TP3 RV32I reference ISS")
    parser.add_argument("program", help=".s/.asm, .hex or .bin file")
    parser.add_argument("--max-cycles", type=int, default=MAX_CYCLES)
    args = parser.parse_args(argv)
    print(format_result(run(load_program(args.program), args.max_cycles)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
