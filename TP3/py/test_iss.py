"""Unit tests for iss.py.

Run from the repo root:  python -m unittest discover -s TP3/py -v
Expected values come from the RV32I spec and the hardware design
(docs/arquitectura.md): they were worked out by hand, not taken from the ISS.
"""

import os
import tempfile
import unittest

import assembler
import isa
import iss

ASM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "asm")


def run_src(src, **kw):
    return iss.run(assembler.assemble(src), **kw)


def run_file(name, **kw):
    return iss.run(iss.load_program(os.path.join(ASM_DIR, name)), **kw)


class Checks(unittest.TestCase):
    def check(self, res, regs=None, dmem=None, pc=None, cycles=None,
              reason=isa.HALT_EBREAK, dmem_used=None, instret=None):
        self.assertEqual(res.halt_reason, reason, "halt_reason")
        self.assertEqual(res.regs[0], 0, "x0")
        for r, v in (regs or {}).items():
            self.assertEqual(res.regs[r], v & isa.MASK32,
                             f"x{r}: expected {v & isa.MASK32:08x}, got {res.regs[r]:08x}")
        for addr, v in (dmem or {}).items():
            self.assertEqual(res.dmem[addr // 4], v & isa.MASK32, f"dmem[0x{addr:x}]")
        for name, expected in (("pc", pc), ("cycles", cycles),
                               ("dmem_used", dmem_used), ("instret", instret)):
            if expected is not None:
                self.assertEqual(getattr(res, name), expected, name)


class TestExamplePrograms(Checks):
    def test_alu(self):
        res = run_file("alu.s")
        self.check(res, regs={
            1: 7, 2: 0xFFFFFFFD, 3: 4, 4: 10, 5: 5, 6: 0xFFFFFFFF, 7: 0xFFFFFFFA,
            8: 1, 9: 0, 10: 4, 11: 0x70, 12: 0x0FFFFFFF, 13: 0xFFFFFFFF,
            14: 0xF0, 15: 0xFFFFFFF7, 16: 0x7F8, 17: 1, 18: 1, 19: 0x80000000,
            20: 1, 21: 0xFFFFFFFF, 22: 0x12345678},
            pc=24 * 4, cycles=25 + 4, instret=24, dmem_used=0)

    def test_loadstore(self):
        res = run_file("loadstore.s")
        self.check(res, regs={
            1: 0x100, 2: 0x89ABCDEF, 3: 0x89ABCDEF, 4: 0xFFFFFFEF, 5: 0xCD,
            6: 0xFFFFFF89, 7: 0xFFFF89AB, 8: 0xCDEF, 9: 0xFFFFCDEF,
            10: 0xEF0000EF, 11: 0x0000CDEF, 12: 0xCDEF0000, 13: 0xEF, 14: 0xCDEF},
            dmem={0xFC: 0, 0x100: 0x89ABCDEF, 0x104: 0xEF0000EF,
                  0x108: 0x0000CDEF, 0x10C: 0xCDEF0000},
            cycles=22 + 4, dmem_used=68)

    def test_forwarding(self):
        res = run_file("forwarding.s")
        self.check(res, regs={1: 1, 2: 2, 3: 3, 4: 11, 5: 8, 6: 0x40, 7: 8, 8: 16, 9: 1},
                   dmem={0x00: 8, 0x40: 8}, cycles=17 + 4, dmem_used=17)

    def test_load_use(self):
        res = run_file("load_use.s")
        self.check(res, regs={1: 42, 2: 42, 3: 84, 4: 42, 5: 42, 6: 43, 7: 42, 8: 42, 9: 0},
                   dmem={0: 42, 4: 42}, cycles=15 + 4 + 3, instret=14, dmem_used=2)

    def test_branches(self):
        res = run_file("branches.s")
        self.check(res, regs={1: 5, 2: 5, 3: 7, 4: 7, 5: 7, 6: 0, 7: 30},
                   dmem={0: 7}, cycles=41, instret=25)

    def test_jumps(self):
        res = run_file("jumps.s")
        self.check(res, regs={1: 8, 2: 11, 6: 0x30, 7: 1, 10: 0x24},
                   pc=0x34, cycles=22, instret=10)

    def test_loop(self):
        res = run_file("loop.s")
        partial = [sum(range(1, i + 1)) for i in range(1, 11)]
        dmem = {0x80 + 4 * i: v for i, v in enumerate(partial)}
        dmem[0] = 55
        self.check(res, regs={1: 10, 2: 10, 3: 55, 4: 0xA8}, dmem=dmem,
                   cycles=78, dmem_used=42)

    def test_no_halt_stops_out_of_range(self):
        res = run_file("no_halt.s")
        self.check(res, regs={3: 3}, reason=isa.HALT_OOR, pc=0x0C, cycles=8, instret=3)


class TestHaltAndTiming(Checks):
    def test_minimal_program_cycles(self):
        # addi; ebreak -> N = 2 -> 6 cycles (docs/protocol.md section 7 example)
        res = run_src("addi x1, x0, 5\nebreak")
        self.check(res, regs={1: 5}, pc=4, cycles=6, instret=1)

    def test_illegal_halts_at_its_pc(self):
        res = run_src("addi x1, x0, 1\n.word 0\naddi x1, x0, 2")
        self.check(res, regs={1: 1}, reason=isa.HALT_ILLEGAL, pc=4, cycles=6)

    def test_ecall_is_illegal(self):
        res = run_src(".word 0x00000073")
        self.check(res, reason=isa.HALT_ILLEGAL, pc=0, cycles=5, instret=0)

    def test_timeout_infinite_loop(self):
        # 'j .' costs 2 cycles per iteration (1 jal penalty). Slot k is in ID
        # at d = 2 + 2k and becomes a TIMEOUT slot when d - 2 >= 20 -> k = 10.
        res = run_src("loop: j loop", max_cycles=20)
        self.check(res, reason=isa.HALT_TIMEOUT, pc=0, cycles=25, instret=10)

    def test_timeout_boundary(self):
        # ebreak is in ID at d = 3: halts normally only if 3 - 2 < max_cycles
        src = "addi x1, x0, 5\nebreak"
        self.check(run_src(src, max_cycles=1), regs={1: 5},
                   reason=isa.HALT_TIMEOUT, pc=4, cycles=6)
        self.check(run_src(src, max_cycles=2), regs={1: 5},
                   reason=isa.HALT_EBREAK, pc=4, cycles=6)

    def test_jump_out_of_program_is_oor(self):
        res = run_src("jal x0, 64\nebreak")
        self.check(res, reason=isa.HALT_OOR, pc=64, cycles=1 + 1 + 4 + 1)

    def test_load_to_x0_and_jal_after_load_do_not_stall(self):
        res = run_src("lw x1, 0(x0)\njal x2, 4\nebreak")
        # N = 3, jal penalty 1, no stall (jal reads no registers)
        self.check(res, regs={2: 8}, cycles=3 + 4 + 1)


class TestMemorySemantics(Checks):
    def test_dmem_aliasing(self):
        res = run_src("""
            lui  x1, 1              # x1 = 0x1000 = dmem size: aliases to 0
            addi x2, x0, 77
            sw   x2, 4(x1)          # writes word 1
            lw   x3, 4(x0)
            ebreak""")
        self.check(res, regs={3: 77}, dmem={4: 77}, dmem_used=2)

    def test_misaligned_accesses(self):
        res = run_src("""
            addi x1, x0, 0x100
            lui  x2, 0x11223
            addi x2, x2, 0x344      # x2 = 0x11223344
            sw   x2, 2(x1)          # addr[1:0] ignored -> word 0x100
            lw   x3, 3(x1)          # -> word 0x100
            lhu  x4, 1(x1)          # addr[0] ignored -> low half
            lhu  x5, 3(x1)          # -> high half
            addi x6, x0, 0x55
            sh   x6, 3(x1)          # writes high half
            lw   x7, 0(x1)
            ebreak""")
        self.check(res, regs={3: 0x11223344, 4: 0x3344, 5: 0x1122, 7: 0x00553344},
                   dmem={0x100: 0x00553344})

    def test_misaligned_fetch_ignores_low_pc_bits(self):
        res = run_src("""
            addi x5, x0, 10         # 0x0
            jalr x0, 0(x5)          # 0x4: pc = 10 -> fetches word 8
            addi x6, x0, 1          # 0x8: runs with pc = 10
            ebreak                  # 0xc: fetched with pc = 14
            """)
        self.check(res, regs={6: 1}, pc=14)

    def test_registers_and_dmem_start_at_zero(self):
        res = run_src("lw x1, 0(x0)\nadd x2, x3, x31\nebreak")
        self.check(res, regs={1: 0, 2: 0}, dmem_used=0)


class TestLoadProgram(unittest.TestCase):
    def test_hex_and_bin_match_source(self):
        words = assembler.assemble("addi x1, x0, -7\nebreak")
        with tempfile.TemporaryDirectory() as tmp:
            hex_path = os.path.join(tmp, "p.hex")
            bin_path = os.path.join(tmp, "p.bin")
            with open(hex_path, "w") as f:
                f.write(assembler.to_hex(words))
            with open(bin_path, "wb") as f:
                f.write(assembler.to_bin(words))
            self.assertEqual(iss.load_program(hex_path), words)
            self.assertEqual(iss.load_program(bin_path), words)

    def test_program_size_limits(self):
        with self.assertRaises(ValueError):
            iss.run([])
        with self.assertRaises(ValueError):
            iss.run([isa.NOP] * (iss.IMEM_DEPTH + 1))


if __name__ == "__main__":
    unittest.main()
