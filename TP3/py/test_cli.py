"""Unit tests for cli.py: next-cycle hints, rendering, ISS check, the shell.

Run from the repo root:  python -m unittest discover -s TP3/py -v
The shell is driven against IssBoard, a fake Debug Unit that answers
LOAD/RESET/RUN/DUMP with protocol frames built from the ISS (and STEP from
a list of prepared states). Hint scenarios follow docs/arquitectura.md 3
and 5; control words are encoded here from docs/protocol.md 6.2.
"""

import io
import os
import struct
import unittest

import assembler
import cli
import isa
import iss
import protocol
from test_protocol import FakeSerial, make_state, response

ASM_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "asm")


def asm1(text):
    return assembler.assemble(text)[0]


def idex(rs1=0, rs2=0, rd=0, alu_src=0, link=0, reg_write=0, mem_read=0,
         mem_write=0, funct3=0, branch=0, jalr=0, is_halt=0, valid=1):
    return (rs1 | rs2 << 5 | rd << 10 | alu_src << 19 | link << 20 | reg_write << 21
            | mem_read << 22 | mem_write << 23 | funct3 << 24 | branch << 27
            | jalr << 28 | is_halt << 29 | valid << 30)


def exmem(rd=0, reg_write=0, mem_read=0, mem_write=0, is_halt=0, valid=1):
    return rd | reg_write << 5 | mem_read << 6 | mem_write << 7 | is_halt << 11 | valid << 12


def memwb(rd=0, reg_write=0, is_halt=0, valid=1):
    return rd | reg_write << 5 | is_halt << 7 | valid << 8


def state(**kw):
    return protocol.decode_state(make_state(**kw))


# ---------------------------------------------------------------------------
# Next-cycle hints
# ---------------------------------------------------------------------------

class TestHints(unittest.TestCase):
    def hints(self, **kw):
        return "\n".join(cli.next_cycle_hints(state(**kw)))

    def test_forward_from_ex_mem(self):
        text = self.hints(id_ex=(0, 0, 0, 0, idex(rs1=1)),
                          ex_mem=(0, 0x10, 0, exmem(rd=1, reg_write=1)))
        self.assertIn("forward EX/MEM -> EX rs1 (x1 = 0x00000010)", text)

    def test_newest_producer_wins(self):
        text = self.hints(id_ex=(0, 0, 0, 0, idex(rs2=1)),
                          ex_mem=(0, 0x10, 0, exmem(rd=1, reg_write=1)),
                          mem_wb=(0, 0x20, memwb(rd=1, reg_write=1)))
        self.assertIn("forward EX/MEM -> EX rs2", text)
        self.assertNotIn("MEM/WB", text)

    def test_load_in_mem_is_not_forwarded(self):
        text = self.hints(id_ex=(0, 0, 0, 0, idex(rs1=1)),
                          ex_mem=(0, 0x10, 0, exmem(rd=1, reg_write=1, mem_read=1)),
                          mem_wb=(0, 0x20, memwb(rd=1, reg_write=1)))
        self.assertIn("forward MEM/WB -> EX rs1 (x1 = 0x00000020)", text)

    def test_x0_is_never_forwarded(self):
        text = self.hints(id_ex=(0, 0, 0, 0, idex(rs1=0)),
                          ex_mem=(0, 0x10, 0, exmem(rd=0, reg_write=1)))
        self.assertEqual(text, "no hazards")

    def test_load_use_stall(self):
        text = self.hints(if_id=(0x8, asm1("add x6, x5, x0"), 1),
                          id_ex=(0x4, 0, 0, 0, idex(rd=5, reg_write=1, mem_read=1, alu_src=1)))
        self.assertIn("stall 1 cycle: load-use on x5", text)

    def test_ebreak_does_not_stall_behind_a_load(self):
        # ebreak's rs2 field is x1, but it reads no registers
        text = self.hints(if_id=(0x8, isa.EBREAK, 1),
                          id_ex=(0x4, 0, 0, 0, idex(rd=1, reg_write=1, mem_read=1)))
        self.assertNotIn("stall", text)
        self.assertIn("stop slot accepted in ID (HALT)", text)

    def test_branch_taken_with_forwarded_operand(self):
        # beq x1, x2: ID/EX holds a stale x1 = 0; EX/MEM produces x1 = 7 = x2
        text = self.hints(id_ex=(0x20, 0, 7, 0xFFFFFFF0, idex(rs1=1, rs2=2, branch=1)),
                          ex_mem=(0x1C, 7, 0, exmem(rd=1, reg_write=1)))
        self.assertIn("flush IF/ID and ID/EX: branch taken -> 0x00000010", text)

    def test_bne_not_taken(self):
        text = self.hints(id_ex=(0x20, 5, 5, 8, idex(rs1=1, rs2=2, branch=1, funct3=1)))
        self.assertIn("branch not taken", text)
        self.assertNotIn("flush IF/ID", text)

    def test_jalr_target_clears_bit0(self):
        text = self.hints(id_ex=(0x20, 0x2D, 0, 0, idex(rs1=10, rd=10, jalr=1, link=1, alu_src=1)))
        self.assertIn("jalr -> 0x0000002c", text)

    def test_jal_in_id(self):
        text = self.hints(if_id=(0x10, asm1("jal x1, 8"), 1))
        self.assertIn("jal in ID: flush IF/ID, jump to 0x00000018", text)

    def test_stop_slot_on_the_wrong_path_is_ignored(self):
        text = self.hints(if_id=(0x24, isa.EBREAK, 1),
                          id_ex=(0x20, 0x40, 0, 0, idex(rs1=1, jalr=1, alu_src=1)))
        self.assertIn("jalr", text)
        self.assertNotIn("stop slot", text)

    def test_stop_codes_and_halted(self):
        text = self.hints(if_id=(0x0C, 0x13, 1 | 3 << 1))
        self.assertIn("stop slot accepted in ID (OOR)", text)
        text = self.hints(flags=0b101, reason=2)
        self.assertEqual(text, "halted (ILLEGAL): the pipeline is empty; RESET or LOAD to run again")


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

class TestRender(unittest.TestCase):
    PROGRAM = assembler.assemble("addi x1, x0, 1\nadd x2, x1, x1\nsw x2, 0(x0)\nebreak")

    def test_stages_bubbles_and_markers(self):
        s = state(flags=0b100, prog_len=4, cycles=5, pc=0x10,
                  if_id=(0, 0x13, 0),
                  id_ex=(0x0C, 0, 0, 0, idex(is_halt=1)),
                  ex_mem=(0x08, 0x0, 0x2, exmem(mem_write=1)),
                  mem_wb=(0x04, 0x2, memwb(rd=2, reg_write=1)))
        text = cli.render(s, program=self.PROGRAM)
        self.assertIn("cycle 5 | READY | program 4 words", text)
        self.assertIn("(past the end of the program: OOR)", text)
        self.assertIn("-- bubble --", text)
        self.assertIn("HALT marker", text)
        self.assertIn("sw x2, 0(x0)", text)
        self.assertIn("store 0x00000002 done at [0x00000000]", text)
        self.assertIn("add x2, x1, x1", text)
        self.assertIn("x2 <= 0x00000002", text)

    def test_changed_registers_and_memory_are_marked(self):
        before = state(regs=[0, 1, 2] + [0] * 29, dmem=(5,))
        after = state(regs=[0, 1, 9] + [0] * 29, dmem=(5, 6))
        text = cli.render(after, prev=before)
        self.assertIn("x2  sp   00000009*", text)
        self.assertNotIn("x1  ra   00000001*", text)
        self.assertIn("[0x0004] 00000006           6 *", text)
        self.assertNotIn("[0x0000] 00000005           5 *", text)

    def test_long_memory_is_truncated(self):
        text = cli.render(state(dmem=tuple(range(40))))
        self.assertIn("... 8 more words", text)

    def test_colors_do_not_break_alignment(self):
        s = state(if_id=(0, 0x13, 0))
        plain = cli.render(s, st=cli.Style(False)).splitlines()
        color = [cli._ANSI_RE.sub("", line) for line in cli.render(s, st=cli.Style(True)).splitlines()]
        self.assertEqual(plain, color)


# ---------------------------------------------------------------------------
# Shell against a fake board backed by the ISS
# ---------------------------------------------------------------------------

def bubble_state(prog_len, prog_valid=True):
    return make_state(flags=0b100 if prog_valid else 0, prog_len=prog_len)


def iss_state(program, res):
    return make_state(flags=0b101, reason=res.halt_reason, prog_len=len(program),
                      cycles=res.cycles, pc=res.pc, regs=res.regs, dmem=res.used_dmem())


class IssBoard:
    """Answers protocol requests like the Debug Unit would, using the ISS."""

    def __init__(self, step_states=(), corrupt_reg=None):
        self.program = None
        self.halted = False
        self.payload = bubble_state(0, prog_valid=False)
        self.step_states = list(step_states)
        self.corrupt_reg = corrupt_reg

    def __call__(self, cmd, payload):
        if cmd == protocol.CMD_LOAD:
            self.program = list(struct.unpack(f"<{len(payload) // 4}I", payload))
            self.halted = False
            self.payload = bubble_state(len(self.program))
            return response(0x81, struct.pack("<H", len(self.program)))
        if cmd == protocol.CMD_RESET:
            self.halted = False
            self.payload = bubble_state(len(self.program or []), self.program is not None)
            return response(0x82)
        if cmd == protocol.CMD_DUMP:
            return response(0x85, self.payload)
        if self.program is None:
            return response(protocol.ERR_NO_PROGRAM, bytes([cmd]))
        if self.halted:
            return response(protocol.ERR_HALTED, bytes([cmd]))
        if cmd == protocol.CMD_RUN:
            res = iss.run(self.program)
            if self.corrupt_reg is not None:
                res.regs[self.corrupt_reg] ^= 1
            self.payload = iss_state(self.program, res)
            self.halted = True
            return response(0x83, self.payload)
        if cmd == protocol.CMD_STEP:
            self.payload = self.step_states.pop(0)
            self.halted = bool(self.payload[0] & 1)
            return response(0x84, self.payload)
        return response(protocol.ERR_UNKNOWN_CMD, bytes([cmd]))


def run_shell(board, *lines):
    out = io.StringIO()
    shell = cli.Shell(protocol.DebugClient(FakeSerial(board)), cli.Style(False), out=out)
    for line in lines:
        shell.onecmd(line)
    return shell, out.getvalue()


class TestShell(unittest.TestCase):
    LOOP = os.path.join(ASM_DIR, "loop.s")

    def test_load_run_check(self):
        shell, text = run_shell(IssBoard(), f"load {self.LOOP}", "run", "check")
        self.assertFalse(shell.failed, text)
        self.assertIn("loaded 11 words", text)
        self.assertIn("HALTED (HALT)", text)
        self.assertIn("cycle 78", text)
        self.assertIn("matches the ISS: HALT, 78 cycles", text)
        self.assertIn("x3  gp   00000037*", text)                       # 55, changed by run

    def test_check_reports_differences(self):
        shell, text = run_shell(IssBoard(corrupt_reg=3), f"load {self.LOOP}", "run", "check")
        self.assertTrue(shell.failed)
        self.assertIn("1 differences with the ISS", text)
        self.assertIn("x3: board 0x00000036, ISS 0x00000037", text)

    def test_errors_from_the_board(self):
        shell, text = run_shell(IssBoard(), "run")
        self.assertTrue(shell.failed)
        self.assertIn("error from the board: ERR_NO_PROGRAM (command RUN)", text)
        shell, text = run_shell(IssBoard(), f"load {self.LOOP}", "run", "run")
        self.assertIn("ERR_HALTED (command RUN)", text)

    def test_step_n_stops_at_halt(self):
        steps = [make_state(flags=0b100, prog_len=2, cycles=1, regs=[0, 5] + [0] * 30),
                 make_state(flags=0b101, prog_len=2, cycles=2, regs=[0, 5] + [0] * 30, reason=1),
                 make_state(flags=0b101, prog_len=2, cycles=3)]
        shell, text = run_shell(IssBoard(step_states=steps),
                                f"load {self.LOOP}", "step 5")
        self.assertIn("halted after 2 steps", text)
        self.assertIn("cycle 2 | HALTED (HALT)", text)
        self.assertIn("x1  ra   00000005*", text)

    def test_load_windows_path_and_quotes(self):
        # backslashes must survive (regression: shlex dropped them)
        for arg in (self.LOOP.replace("/", "\\"), f'"{self.LOOP}"'):
            shell, text = run_shell(IssBoard(), f"load {arg}")
            self.assertFalse(shell.failed, text)
            self.assertIn("loaded 11 words", text)

    def test_reset_and_usage_errors(self):
        shell, text = run_shell(IssBoard(), f"load {self.LOOP}", "run", "reset")
        self.assertIn("reset done", text)
        self.assertIn("cycle 0 | READY", text)
        shell, text = run_shell(IssBoard(), "load")
        self.assertIn("usage: load <file>", text)
        shell, text = run_shell(IssBoard(), "check")
        self.assertIn("load a program first", text)


if __name__ == "__main__":
    unittest.main()
