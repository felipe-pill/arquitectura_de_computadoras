"""Unit tests for isa.py and assembler.py.

Run from the repo root:  python -m unittest discover -s TP3/py -v
Expected encodings are taken from the RV32I base encoding tables (several
are well-known GNU as outputs, e.g. 'addi sp, sp, -16' = ff010113).
"""

import os
import struct
import tempfile
import unittest

import assembler
import isa
from assembler import AsmError, assemble

ASM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "asm")

KNOWN_ENCODINGS = [
    # R-type
    ("add x3, x1, x2", 0x002081B3),
    ("sub x5, x6, x7", 0x407302B3),
    ("sll x5, x6, x7", 0x007312B3),
    ("slt x5, x6, x7", 0x007322B3),
    ("sltu x5, x6, x7", 0x007332B3),
    ("xor x5, x6, x7", 0x007342B3),
    ("srl x5, x6, x7", 0x007352B3),
    ("sra x5, x6, x7", 0x407352B3),
    ("or x5, x6, x7", 0x007362B3),
    ("and x5, x6, x7", 0x007372B3),
    # I-type ALU
    ("addi x1, x0, 5", 0x00500093),
    ("addi sp, sp, -16", 0xFF010113),
    ("slti x1, x2, -1", 0xFFF12093),
    ("sltiu x1, x2, 1", 0x00113093),
    ("xori x1, x2, -1", 0xFFF14093),
    ("ori x1, x2, -1", 0xFFF16093),
    ("andi x1, x2, -1", 0xFFF17093),
    ("slli x1, x1, 3", 0x00309093),
    ("slli x1, x2, 31", 0x01F11093),
    ("srli x1, x2, 31", 0x01F15093),
    ("srai x1, x1, 1", 0x4010D093),
    # loads
    ("lb x1, -1(x2)", 0xFFF10083),
    ("lh x1, -1(x2)", 0xFFF11083),
    ("lw x4, 0(x0)", 0x00002203),
    ("lw ra, 12(sp)", 0x00C12083),
    ("lbu x1, -1(x2)", 0xFFF14083),
    ("lhu x1, -1(x2)", 0xFFF15083),
    # stores
    ("sb x2, 3(x1)", 0x002081A3),
    ("sh x2, 3(x1)", 0x002091A3),
    ("sw x3, 0(x0)", 0x00302023),
    ("sw ra, 12(sp)", 0x00112623),
    ("sw x2, -1(x1)", 0xFE20AFA3),
    # branches (numeric operand = byte offset)
    ("beq x1, x2, 8", 0x00208463),
    ("bne x1, x2, -4", 0xFE209EE3),
    ("beq x0, x0, 0", 0x00000063),
    ("beq x0, x0, 4094", 0x7E000FE3),
    # jumps
    ("jal x0, 0", 0x0000006F),
    ("jal x0, -4", 0xFFDFF06F),
    ("jal x0, 1048574", 0x7FFFF06F),
    ("jalr ra, 0(t0)", 0x000280E7),
    ("jalr x0, 0(ra)", 0x00008067),
    # U-type
    ("lui a0, 0x12345", 0x12345537),
    # HALT
    ("ebreak", 0x00100073),
]


class TestKnownEncodings(unittest.TestCase):
    def test_known_encodings(self):
        for src, expected in KNOWN_ENCODINGS:
            with self.subTest(src=src):
                self.assertEqual(assemble(src), [expected],
                                 f"{src}: expected {expected:08x}")

    def test_decode_encode_roundtrip(self):
        for src, word in KNOWN_ENCODINGS:
            with self.subTest(src=src):
                ins = isa.decode(word)
                self.assertIsNotNone(ins)
                self.assertEqual(isa.encode(ins), word)

    def test_disassemble_reassembles(self):
        for _, word in KNOWN_ENCODINGS:
            text = isa.disassemble(word)
            with self.subTest(text=text):
                self.assertEqual(assemble(text), [word])


class TestPseudoAndSyntax(unittest.TestCase):
    def test_pseudo_instructions(self):
        self.assertEqual(assemble("nop"), [0x00000013])
        self.assertEqual(assemble("halt"), [0x00100073])
        self.assertEqual(assemble("ret"), [0x00008067])
        self.assertEqual(assemble("mv a0, a1"), assemble("addi a0, a1, 0"))
        self.assertEqual(assemble("li t0, -5"), assemble("addi t0, x0, -5"))
        self.assertEqual(assemble("j -4"), [0xFFDFF06F])

    def test_jal_and_jalr_short_forms(self):
        self.assertEqual(assemble("jal 8"), assemble("jal ra, 8"))
        self.assertEqual(assemble("jalr t0"), assemble("jalr ra, 0(t0)"))
        self.assertEqual(assemble("jalr x1, x5, -8"), assemble("jalr x1, -8(x5)"))

    def test_labels_forward_and_backward(self):
        src = """
        start:  addi x1, x0, 1
                beq  x0, x0, end      # +8
        mid:    nop
        end:    bne  x1, x0, start    # -12
                jal  x0, mid          # -8
        """
        words = assemble(src)
        self.assertEqual(words[1], isa.encode(isa.Instr("beq", 0, 0, 0, 8)))
        self.assertEqual(words[3], isa.encode(isa.Instr("bne", 0, 1, 0, -12)))
        self.assertEqual(words[4], isa.encode(isa.Instr("jal", 0, 0, 0, -8)))

    def test_label_alone_on_line_and_two_labels(self):
        words = assemble("a:\nb: c: nop\n    j a\n")
        self.assertEqual(words, [0x00000013, isa.encode(isa.Instr("jal", 0, 0, 0, -4))])

    def test_comments_case_and_abi_names(self):
        self.assertEqual(assemble("ADDI A0, ZERO, 1 ; comment\n# full line\n"),
                         assemble("addi x10, x0, 1"))
        self.assertEqual(assemble("addi s0, fp, 0"), assemble("addi x8, x8, 0"))

    def test_immediate_formats(self):
        self.assertEqual(assemble("addi x1, x0, 0x10"), assemble("addi x1, x0, 16"))
        self.assertEqual(assemble("addi x1, x0, -0x10"), assemble("addi x1, x0, -16"))
        self.assertEqual(assemble("addi x1, x0, 0b101"), assemble("addi x1, x0, 5"))
        self.assertEqual(assemble("lw x1, (x2)"), assemble("lw x1, 0(x2)"))
        self.assertEqual(assemble("lui x1, -1"), assemble("lui x1, 0xfffff"))

    def test_word_directive(self):
        self.assertEqual(assemble(".word 0xdeadbeef\n.word -1"), [0xDEADBEEF, 0xFFFFFFFF])


class TestErrors(unittest.TestCase):
    BAD = [
        "foo x1, x2, x3",            # unknown instruction
        "add x1, x2, x32",           # bad register
        "add x1, x2",                # operand count
        "addi x1, x0, 2048",         # 12-bit range
        "addi x1, x0, -2049",
        "lw x1, 2048(x0)",
        "sw x1, -2049(x0)",
        "slli x1, x1, 32",           # shamt range
        "beq x0, x0, 4096",          # branch range
        "beq x0, x0, 3",             # odd offset
        "jal x0, 1048576",           # jump range
        "lui x1, 0x100000",          # 20-bit range
        "beq x0, x0, nowhere",       # unknown label
        "li x1, 4096",               # li only 12 bits
        "lw x1, x2",                 # missing offset(reg)
        "addi x1, x0, abc",          # bad immediate
        "add x1, , x2",              # empty operand
        ".word 0x100000000",         # too wide
    ]

    def test_errors_report_line(self):
        for src in self.BAD:
            with self.subTest(src=src):
                with self.assertRaisesRegex(AsmError, r"^line 2: "):
                    assemble("nop\n" + src)

    def test_duplicate_label(self):
        with self.assertRaisesRegex(AsmError, "duplicate label"):
            assemble("a: nop\na: nop")

    def test_register_name_as_label(self):
        with self.assertRaisesRegex(AsmError, "register name"):
            assemble("sp: nop")


class TestDecoderIllegal(unittest.TestCase):
    ILLEGAL = {
        "all zeros": 0x00000000,
        "ecall": 0x00000073,
        "ebreak with extra bits": 0x00100173,
        "opcode[1:0] != 11": 0x00500091,
        "auipc": 0x00000097,
        "mul (funct7=1)": 0x022081B3,
        "funct7=0x20 with sll": 0x402091B3,
        "slli with imm[5]=1": 0x02009093,
        "srli with bad funct7": 0x2000D093,
        "blt": 0x0020C463,
        "ld (funct3=011)": 0x0000B203,
        "sd (funct3=011)": 0x0030B023,
        "jalr funct3=1": 0x000290E7,
    }

    def test_illegal_words(self):
        for name, word in self.ILLEGAL.items():
            with self.subTest(name=name):
                self.assertIsNone(isa.decode(word), f"{word:08x} should be illegal")

    def test_unused_register_fields_are_zero(self):
        # ebreak has rs2 field = 1; decoded it reads no registers
        self.assertEqual(isa.decode(isa.EBREAK), isa.Instr("ebreak"))
        lui = isa.decode(0x12345537)
        self.assertEqual((lui.rs1, lui.rs2), (0, 0))
        addi = isa.decode(0xFF010113)
        self.assertEqual(addi.rs2, 0)
        sw = isa.decode(0x00112623)
        self.assertEqual(sw.rd, 0)


class TestOutputFormats(unittest.TestCase):
    WORDS = [0x00500093, 0x00100073]

    def test_hex(self):
        self.assertEqual(assembler.to_hex(self.WORDS), "00500093\n00100073\n")

    def test_bin_is_little_endian(self):
        self.assertEqual(assembler.to_bin(self.WORDS),
                         bytes([0x93, 0x00, 0x50, 0x00, 0x73, 0x00, 0x10, 0x00]))

    def test_coe(self):
        self.assertEqual(assembler.to_coe(self.WORDS),
                         "memory_initialization_radix=16;\n"
                         "memory_initialization_vector=\n"
                         "00500093,\n00100073;\n")

    def test_cli_writes_all_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = os.path.join(tmp, "p.s")
            with open(src, "w") as f:
                f.write("addi x1, x0, 5\nebreak\n")
            base = os.path.join(tmp, "out")
            self.assertEqual(assembler.main([src, "-o", base]), 0)
            with open(base + ".hex") as f:
                self.assertEqual(f.read(), "00500093\n00100073\n")
            with open(base + ".bin", "rb") as f:
                self.assertEqual(struct.unpack("<2I", f.read()), tuple(self.WORDS))
            self.assertTrue(os.path.exists(base + ".coe"))


class TestExamplePrograms(unittest.TestCase):
    def test_all_programs_assemble_and_roundtrip(self):
        names = sorted(n for n in os.listdir(ASM_DIR) if n.endswith(".s"))
        self.assertGreaterEqual(len(names), 8)
        for name in names:
            with self.subTest(program=name):
                with open(os.path.join(ASM_DIR, name)) as f:
                    words = assemble(f.read())
                for w in words:
                    ins = isa.decode(w)
                    if ins is not None:  # .word 0 in branches.s is deliberately illegal
                        self.assertEqual(isa.encode(ins), w)


if __name__ == "__main__":
    unittest.main()
