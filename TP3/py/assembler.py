"""Two-pass assembler for the TP3 RV32I subset.

Syntax (one statement per line):
    label:                      # labels may share a line with an instruction
    addi  x1, x0, 5             # comments start with '#' or ';'
    lw    a0, -4(sp)            # registers: x0..x31 or ABI names
    beq   x1, x2, loop          # branch/jump target: label or byte offset
    .word 0x00000013            # raw 32-bit word

Immediates: decimal or 0x/0b prefixed, optionally negative.
Pseudo-instructions (one word each): nop, mv rd, rs; li rd, imm12;
j target; ret; halt (= ebreak).

Usage:
    python assembler.py prog.s              # print .hex to stdout
    python assembler.py prog.s -o out/prog  # write out/prog.hex/.bin/.coe
    python assembler.py prog.s -o prog -f hex,bin
"""

import argparse
import re
import struct
import sys

import isa
from isa import Instr

LABEL_RE = re.compile(r"^\s*([A-Za-z_.][\w.]*)\s*:")
MEM_RE = re.compile(r"^(.*)\((\s*[\w]+\s*)\)$")


class AsmError(Exception):
    pass


def _strip_comment(line):
    for mark in ("#", ";"):
        idx = line.find(mark)
        if idx >= 0:
            line = line[:idx]
    return line.strip()


def _reg(tok):
    name = tok.strip().lower()
    if name not in isa.REGISTERS:
        raise ValueError(f"unknown register '{tok.strip()}'")
    return isa.REGISTERS[name]


def _int(tok):
    tok = tok.strip()
    try:
        return int(tok, 0)
    except ValueError:
        raise ValueError(f"bad immediate '{tok}'") from None


def _mem(tok):
    """'imm(reg)' or '(reg)' -> (imm, reg)."""
    m = MEM_RE.match(tok.strip())
    if not m:
        raise ValueError(f"expected 'offset(reg)', got '{tok.strip()}'")
    imm = _int(m.group(1)) if m.group(1).strip() else 0
    return imm, _reg(m.group(2))


def _target(tok, labels, pc):
    """Label -> offset from pc; plain integer -> taken as the offset itself."""
    tok = tok.strip()
    if tok in labels:
        return labels[tok] - pc
    try:
        return int(tok, 0)
    except ValueError:
        raise ValueError(f"unknown label '{tok}'") from None


def _expect(ops, count, mnemonic):
    if len(ops) != count:
        raise ValueError(f"'{mnemonic}' takes {count} operand(s), got {len(ops)}")


def _parse(mnemonic, ops, labels, pc):
    """Return the 32-bit word for one statement."""
    m = mnemonic
    if m == ".word":
        _expect(ops, 1, m)
        value = _int(ops[0])
        if not -(1 << 31) <= value <= isa.MASK32:
            raise ValueError(f".word value {value} does not fit in 32 bits")
        return value & isa.MASK32

    # pseudo-instructions
    if m == "nop":
        _expect(ops, 0, m)
        return isa.NOP
    if m in ("halt", "ebreak"):
        _expect(ops, 0, m)
        return isa.EBREAK
    if m == "mv":
        _expect(ops, 2, m)
        return isa.encode(Instr("addi", _reg(ops[0]), _reg(ops[1]), 0, 0))
    if m == "li":
        _expect(ops, 2, m)
        value = _int(ops[1])
        if not -2048 <= value <= 2047:
            raise ValueError(f"li only supports 12-bit values [-2048, 2047] "
                             f"(got {value}); use lui + addi")
        return isa.encode(Instr("addi", _reg(ops[0]), 0, 0, value))
    if m == "j":
        _expect(ops, 1, m)
        return isa.encode(Instr("jal", 0, 0, 0, _target(ops[0], labels, pc)))
    if m == "ret":
        _expect(ops, 0, m)
        return isa.encode(Instr("jalr", 0, 1, 0, 0))

    # real instructions
    if m in isa.R_OPS:
        _expect(ops, 3, m)
        return isa.encode(Instr(m, _reg(ops[0]), _reg(ops[1]), _reg(ops[2])))
    if m in isa.I_ALU_OPS or m in isa.SHIFT_IMM_OPS:
        _expect(ops, 3, m)
        return isa.encode(Instr(m, _reg(ops[0]), _reg(ops[1]), 0, _int(ops[2])))
    if m in isa.LOAD_OPS:
        _expect(ops, 2, m)
        imm, rs1 = _mem(ops[1])
        return isa.encode(Instr(m, _reg(ops[0]), rs1, 0, imm))
    if m in isa.STORE_OPS:
        _expect(ops, 2, m)
        imm, rs1 = _mem(ops[1])
        return isa.encode(Instr(m, 0, rs1, _reg(ops[0]), imm))
    if m in isa.BRANCH_OPS:
        _expect(ops, 3, m)
        return isa.encode(Instr(m, 0, _reg(ops[0]), _reg(ops[1]),
                                _target(ops[2], labels, pc)))
    if m == "jal":
        if len(ops) == 1:  # jal target  ->  jal ra, target
            return isa.encode(Instr(m, 1, 0, 0, _target(ops[0], labels, pc)))
        _expect(ops, 2, m)
        return isa.encode(Instr(m, _reg(ops[0]), 0, 0, _target(ops[1], labels, pc)))
    if m == "jalr":
        if len(ops) == 1:  # jalr rs  ->  jalr ra, 0(rs)
            return isa.encode(Instr(m, 1, _reg(ops[0]), 0, 0))
        if len(ops) == 2:  # jalr rd, imm(rs1)
            imm, rs1 = _mem(ops[1])
            return isa.encode(Instr(m, _reg(ops[0]), rs1, 0, imm))
        _expect(ops, 3, m)  # jalr rd, rs1, imm
        return isa.encode(Instr(m, _reg(ops[0]), _reg(ops[1]), 0, _int(ops[2])))
    if m == "lui":
        _expect(ops, 2, m)
        value = _int(ops[1])
        if -(1 << 19) <= value < 0:
            value &= 0xFFFFF
        return isa.encode(Instr(m, _reg(ops[0]), 0, 0, value))
    raise ValueError(f"unknown instruction '{m}'")


def assemble(source):
    """Assemble source text. Returns the list of 32-bit words (address 0 first)."""
    # Pass 1: split statements, assign addresses, collect labels.
    labels = {}
    statements = []  # (line_no, mnemonic, operands, pc)
    pc = 0
    for line_no, raw in enumerate(source.splitlines(), start=1):
        line = _strip_comment(raw)
        while True:
            m = LABEL_RE.match(line)
            if not m:
                break
            name = m.group(1)
            if name in labels:
                raise AsmError(f"line {line_no}: duplicate label '{name}'")
            if name.lower() in isa.REGISTERS:
                raise AsmError(f"line {line_no}: label '{name}' is a register name")
            labels[name] = pc
            line = line[m.end():].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        mnemonic = parts[0].lower()
        ops = [op.strip() for op in parts[1].split(",")] if len(parts) > 1 else []
        if any(not op for op in ops):
            raise AsmError(f"line {line_no}: empty operand in '{raw.strip()}'")
        statements.append((line_no, mnemonic, ops, pc))
        pc += 4

    # Pass 2: encode.
    words = []
    for line_no, mnemonic, ops, pc in statements:
        try:
            words.append(_parse(mnemonic, ops, labels, pc))
        except ValueError as exc:
            raise AsmError(f"line {line_no}: {exc}") from None
    return words


def to_hex(words):
    """$readmemh format: one 8-digit word per line."""
    return "".join(f"{w:08x}\n" for w in words)


def to_bin(words):
    """Raw little-endian bytes: the memory image (and the LOAD payload)."""
    return struct.pack(f"<{len(words)}I", *words)


def to_coe(words):
    """Xilinx .coe memory initialization file."""
    body = ",\n".join(f"{w:08x}" for w in words)
    return ("memory_initialization_radix=16;\n"
            f"memory_initialization_vector=\n{body};\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description="TP3 RV32I assembler")
    parser.add_argument("source", help="assembly file")
    parser.add_argument("-o", "--output",
                        help="output base path (extension is added per format); "
                             "without it, .hex is printed to stdout")
    parser.add_argument("-f", "--formats", default="hex,bin,coe",
                        help="comma-separated: hex, bin, coe (default: all)")
    args = parser.parse_args(argv)

    with open(args.source, encoding="utf-8") as f:
        try:
            words = assemble(f.read())
        except AsmError as exc:
            print(f"{args.source}: {exc}", file=sys.stderr)
            return 1

    if not args.output:
        sys.stdout.write(to_hex(words))
        return 0
    writers = {"hex": to_hex, "bin": to_bin, "coe": to_coe}
    for fmt in args.formats.split(","):
        fmt = fmt.strip()
        if fmt not in writers:
            print(f"unknown format '{fmt}'", file=sys.stderr)
            return 1
        data = writers[fmt](words)
        path = f"{args.output}.{fmt}"
        if isinstance(data, bytes):
            with open(path, "wb") as f:
                f.write(data)
        else:
            with open(path, "w", encoding="ascii", newline="\n") as f:
                f.write(data)
    print(f"{len(words)} words -> {args.output}.{{{args.formats}}}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
