"""Interactive host CLI for the TP3 processor (docs/protocol.md).

    python TP3/py/cli.py --port COM5
    python TP3/py/cli.py --port COM5 -c "load TP3/asm/loop.s" -c run -c check

Commands: load <file>, step [n], run, reset, dump, mem, check, help, quit.
After each command it shows the processor state:
- status line (cycles, halted / halt reason, program size);
- the instruction in each pipeline stage, disassembled, with the values in
  flight, and what will happen on the next cycle (forwarding, stall, flush,
  HALT) - derived here from the dumped pipeline registers, the same way the
  hardware decides it (docs/arquitectura.md 3);
- registers and data memory, highlighting what changed since the previous
  screen.
`check` compares the final state with the reference ISS (iss.py).
"""

import argparse
import cmd
import os
import re
import sys

import isa
import iss
import protocol
from protocol import DebugClient, DebugError, ProtocolError

DEFAULT_BAUD = 115200
DEFAULT_TIMEOUT = 2.0          # seconds per response (RUN ends within 10 ms)
DEFAULT_MAX_CYCLES = 1000000   # must match MAX_CYCLES of the bitstream
STOP_CODE_NAMES = {3: "OOR", 4: "TIMEOUT"}
MEM_PREVIEW_WORDS = 32


# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------

class Style:
    def __init__(self, enabled):
        self.enabled = enabled

    def _wrap(self, code, text):
        return f"\x1b[{code}m{text}\x1b[0m" if self.enabled else text

    def bold(self, t):    return self._wrap("1", t)
    def dim(self, t):     return self._wrap("2", t)
    def changed(self, t): return self._wrap("1;33", t)   # bold yellow
    def good(self, t):    return self._wrap("32", t)
    def bad(self, t):     return self._wrap("31", t)
    def hint(self, t):    return self._wrap("36", t)


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _pad(text, width):
    """Left-justify text to a visible width (ignoring color codes)."""
    return text + " " * max(0, width - len(_ANSI_RE.sub("", text)))


def enable_windows_ansi():
    """Turn on ANSI escape processing in the Windows console."""
    if os.name != "nt":
        return
    try:
        import ctypes
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.GetStdHandle(-11)          # STD_OUTPUT_HANDLE
        mode = ctypes.c_uint32()
        if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
            kernel32.SetConsoleMode(handle, mode.value | 0x0004)  # VT processing
    except (AttributeError, OSError):
        pass


# ---------------------------------------------------------------------------
# Next-cycle hints (mirror of forward_unit, hazard_unit, branch_unit and the
# HALT / jal logic in cpu_core)
# ---------------------------------------------------------------------------

def _forward_source(s, rs):
    m, w = s.ex_mem, s.mem_wb
    if rs and m.reg_write and not m.mem_read and m.rd == rs:
        return "EX/MEM", m.result
    if rs and w.reg_write and w.rd == rs:
        return "MEM/WB", w.wb_data
    return None


def next_cycle_events(s):
    """What the pipeline will do on the next enabled edge, as a dict:
    fwd_a / fwd_b ("EX/MEM", "MEM/WB" or None, with fwd_*_value),
    redirect + target (taken branch or jalr in EX), branch_not_taken,
    load_use, halt_accept + halt_reason ("HALT", "ILLEGAL", "OOR", ...),
    id_jal + jal_target. Mirrors forward_unit, branch_unit, hazard_unit and
    the halt_accept / id_jal logic of cpu_core (checked against RTL traces
    in test_hints_rtl.py)."""
    e, d = s.id_ex, s.if_id
    ev = {"fwd_a": None, "fwd_b": None, "fwd_a_value": 0, "fwd_b_value": 0,
          "redirect": False, "target": 0, "branch_not_taken": False,
          "load_use": False, "halt_accept": False, "halt_reason": None,
          "id_jal": False, "jal_target": 0}

    # EX: forwarding and branch / jalr resolution
    fa, fb = _forward_source(s, e.rs1), _forward_source(s, e.rs2)
    if fa:
        ev["fwd_a"], ev["fwd_a_value"] = fa
    if fb:
        ev["fwd_b"], ev["fwd_b_value"] = fb
    op_a = fa[1] if fa else e.rs1_data
    op_b = fb[1] if fb else e.rs2_data
    taken = e.branch and ((op_a == op_b) != bool(e.funct3 & 1))
    ev["redirect"] = e.valid and (e.jalr or taken)
    if ev["redirect"]:
        ev["target"] = ((op_a + e.imm) & isa.MASK32 & ~1) if e.jalr else ((e.pc + e.imm) & isa.MASK32)
    ev["branch_not_taken"] = e.valid and e.branch and not taken

    # ID: load-use stall, stop slot acceptance, jal
    if d.valid:
        ins = isa.decode(d.instr)
        halt_cond = d.stop_code != 0 or ins is None or ins.name == "ebreak"
        rs1, rs2 = (0, 0) if halt_cond else (ins.rs1, ins.rs2)
        ev["load_use"] = bool(e.mem_read and e.rd and e.rd in (rs1, rs2))
        if halt_cond and not ev["redirect"] and not s.halting:
            ev["halt_accept"] = True
            ev["halt_reason"] = (STOP_CODE_NAMES.get(d.stop_code) if d.stop_code else
                                 "ILLEGAL" if ins is None else "HALT")
        if not halt_cond and ins.name == "jal" and not ev["redirect"]:
            ev["id_jal"] = True
            ev["jal_target"] = (d.pc + ins.imm) & isa.MASK32
    return ev


def next_cycle_hints(s):
    """What the pipeline will do on the next enabled edge, as text lines."""
    if s.halted:
        return [f"halted ({s.halt_reason_name}): the pipeline is empty; RESET or LOAD to run again"]
    ev = next_cycle_events(s)
    e = s.id_ex
    hints = []
    for name, rs, key in (("rs1", e.rs1, "fwd_a"), ("rs2", e.rs2, "fwd_b")):
        if ev[key]:
            hints.append(f"forward {ev[key]} -> EX {name} (x{rs} = 0x{ev[key + '_value']:08x})")
    if ev["redirect"]:
        why = "jalr" if e.jalr else "branch taken"
        hints.append(f"flush IF/ID and ID/EX: {why} -> 0x{ev['target']:08x}")
    elif ev["branch_not_taken"]:
        hints.append("branch not taken (no flush)")
    if ev["load_use"]:
        hints.append(f"stall 1 cycle: load-use on x{e.rd} (bubble into EX)")
    if ev["halt_accept"]:
        hints.append(f"stop slot accepted in ID ({ev['halt_reason']}): fetch stops, pipeline drains")
    if ev["id_jal"]:
        hints.append(f"jal in ID: flush IF/ID, jump to 0x{ev['jal_target']:08x}")
    if s.halting:
        hints.append("draining: HALT marker in flight, halted when it leaves WB")
    return hints or ["no hazards"]


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def _instr_at(program, pc):
    """Disassembly of the loaded program word at pc, or None if unknown."""
    if program is None or pc % 4 or not 0 <= pc // 4 < len(program):
        return None
    return isa.disassemble(program[pc // 4])


def _pipeline_rows(s, program, st):
    d, e, m, w = s.if_id, s.id_ex, s.ex_mem, s.mem_wb
    rows = []

    text = _instr_at(program, s.pc)
    if s.prog_len and s.pc >= 4 * s.prog_len:
        text = "(past the end of the program: OOR)"
    rows.append(("IF", f"0x{s.pc:08x}", text or "", ""))

    if not d.valid:
        rows.append(("ID", "", st.dim("-- bubble --"), ""))
    elif d.stop_code:
        rows.append(("ID", f"0x{d.pc:08x}",
                     st.bad(f"stop slot ({STOP_CODE_NAMES.get(d.stop_code, d.stop_code)})"), ""))
    else:
        rows.append(("ID", f"0x{d.pc:08x}", isa.disassemble(d.instr), f"word {d.instr:08x}"))

    def stage(name, regs, detail):
        if not regs.valid:
            return (name, "", st.dim("-- bubble --"), "")
        if regs.is_halt:
            return (name, f"0x{regs.pc:08x}", st.bad("HALT marker"), "")
        return (name, f"0x{regs.pc:08x}", _instr_at(program, regs.pc) or "?", detail)

    ex_detail = []
    if e.rs1:
        ex_detail.append(f"x{e.rs1}=0x{e.rs1_data:08x}")
    if e.rs2:
        ex_detail.append(f"x{e.rs2}=0x{e.rs2_data:08x}")
    if ex_detail:
        ex_detail.append("(read in ID, before forwarding)")
    if e.alu_src or e.branch:
        ex_detail.append(f"imm={isa.to_signed(e.imm)}")
    rows.append(stage("EX", e, " ".join(ex_detail)))

    if m.mem_write:
        mem_detail = f"store 0x{m.store_data:08x} done at [0x{m.result:08x}]"
    elif m.mem_read:
        mem_detail = f"load from [0x{m.result:08x}]"
    elif m.reg_write:
        mem_detail = f"result 0x{m.result:08x}"
    else:
        mem_detail = ""
    rows.append(stage("MEM", m, mem_detail))

    wb_detail = f"x{w.rd} <= 0x{w.wb_data:08x}" if w.reg_write else ""
    rows.append(stage("WB", w, wb_detail))
    return rows


def render(s, prev=None, program=None, st=None, mem_limit=MEM_PREVIEW_WORDS):
    """The full state screen as a string. prev = previous State (for diffs)."""
    st = st or Style(False)
    lines = []
    if s.halted:
        status = st.bad(f"HALTED ({s.halt_reason_name})")
    elif s.halting:
        status = st.hint("DRAINING")
    else:
        status = st.good("READY")
    prog = f"program {s.prog_len} words" if s.prog_valid else st.bad("no program")
    lines.append(st.bold(f"cycle {s.cycles}") + f" | {status} | {prog} | dmem used {s.dmem_used} words")

    lines.append("")
    lines.append(st.bold("Pipeline"))
    for name, pc, text, detail in _pipeline_rows(s, program, st):
        lines.append(f"  {name:<4} {pc:<11} {_pad(text, 28)} {detail}".rstrip())
    for h in next_cycle_hints(s):
        lines.append("  " + st.hint("next: " + h))

    lines.append("")
    lines.append(st.bold("Registers") + ("  (changed in yellow / *)" if prev else ""))
    for row in range(8):
        cells = []
        for col in range(4):
            r = col * 8 + row
            text = f"x{r:<2} {isa.ABI_NAMES[r]:<4} {s.regs[r]:08x}"
            changed = prev is not None and prev.regs[r] != s.regs[r]
            cells.append(st.changed(text + "*") if changed else text + " ")
        lines.append("  " + "  ".join(cells))

    lines.append("")
    lines.append(st.bold(f"Data memory (used: {s.dmem_used} words)"))
    if not s.dmem:
        lines.append("  " + st.dim("(empty)"))
    for i, word in enumerate(s.dmem[:mem_limit]):
        old = prev.dmem[i] if prev is not None and i < len(prev.dmem) else 0
        text = f"[0x{4 * i:04x}] {word:08x} {isa.to_signed(word):>11}"
        lines.append("  " + (st.changed(text + " *") if prev is not None and old != word else text))
    if len(s.dmem) > mem_limit:
        lines.append("  " + st.dim(f"... {len(s.dmem) - mem_limit} more words ('mem' shows all)"))
    return "\n".join(lines)


def compare_with_iss(s, program, max_cycles=DEFAULT_MAX_CYCLES):
    """Differences between a halted State and the ISS run of `program`."""
    res = iss.run(program, max_cycles=max_cycles)
    diffs = []
    if not s.halted:
        diffs.append("the processor has not halted yet (run it first)")
        return diffs
    if s.halt_reason != res.halt_reason:
        diffs.append(f"halt reason: board {s.halt_reason_name}, ISS {isa.HALT_REASON_NAMES[res.halt_reason]}")
    if s.pc != res.pc:
        diffs.append(f"pc: board 0x{s.pc:08x}, ISS 0x{res.pc:08x}")
    if s.cycles != res.cycles:
        diffs.append(f"cycles: board {s.cycles}, ISS {res.cycles}")
    for r in range(32):
        if s.regs[r] != res.regs[r]:
            diffs.append(f"x{r}: board 0x{s.regs[r]:08x}, ISS 0x{res.regs[r]:08x}")
    if s.dmem_used != res.dmem_used:
        diffs.append(f"dmem used: board {s.dmem_used} words, ISS {res.dmem_used}")
    for i, (a, b) in enumerate(zip(s.dmem, res.used_dmem())):
        if a != b:
            diffs.append(f"dmem[0x{4 * i:04x}]: board 0x{a:08x}, ISS 0x{b:08x}")
    return diffs


# ---------------------------------------------------------------------------
# Shell
# ---------------------------------------------------------------------------

class Shell(cmd.Cmd):
    intro = "TP3 RV32I debug CLI. Type 'help' for the commands."
    prompt = "rv> "

    def __init__(self, client, style, max_cycles=DEFAULT_MAX_CYCLES, out=None):
        super().__init__(stdout=out or sys.stdout)
        self.client = client
        self.st = style
        self.max_cycles = max_cycles
        self.program = None      # words loaded in this session (for disassembly)
        self.state = None        # last State shown
        self.failed = False      # an error happened (for scripted use)

    # ---- helpers ----
    def say(self, text=""):
        self.stdout.write(text + "\n")

    def show(self, new, mem_limit=MEM_PREVIEW_WORDS):
        self.say(render(new, self.state, self.program, self.st, mem_limit))
        self.state = new

    def onecmd(self, line):
        try:
            return super().onecmd(line)
        except DebugError as exc:
            self.failed = True
            self.say(self.st.bad(f"error from the board: {exc}"))
        except (ProtocolError, OSError, ValueError) as exc:
            self.failed = True
            self.say(self.st.bad(f"error: {exc}"))
        return False

    def emptyline(self):
        return False

    # ---- commands ----
    def do_load(self, arg):
        """load <file>: assemble (.s/.asm) or read (.hex/.bin) and load a program."""
        # Taken literally (no shlex): Windows paths contain backslashes.
        # Quotes around a path with spaces are optional.
        path = arg.strip()
        if len(path) >= 2 and path[0] == path[-1] and path[0] in "\"'":
            path = path[1:-1]
        if not path:
            raise ValueError("usage: load <file>")
        words = iss.load_program(path)
        n = self.client.load(words)
        self.program = words
        self.say(self.st.good(f"loaded {n} words from {path}"))
        self.state = None
        self.show(self.client.dump())

    def do_step(self, arg):
        """step [n]: advance n clock cycles (default 1), one STEP command each."""
        n = int(arg) if arg.strip() else 1
        if n < 1:
            raise ValueError("n must be >= 1")
        new = None
        for i in range(n):
            new = self.client.step()
            if new.halted and i < n - 1:
                self.say(f"halted after {i + 1} steps")
                break
        self.show(new)   # changes are shown against the state before the n steps

    def do_run(self, arg):
        """run: run until HALT, illegal instruction, end of program or TIMEOUT."""
        self.show(self.client.run())

    def do_reset(self, arg):
        """reset: reset the core and clear data memory (the program is kept)."""
        self.client.reset()
        self.say(self.st.good("reset done"))
        self.state = None
        self.show(self.client.dump())

    def do_dump(self, arg):
        """dump: read and show the state without advancing."""
        self.show(self.client.dump())

    def do_mem(self, arg):
        """mem: show the state with every used data memory word."""
        self.show(self.client.dump(), mem_limit=1 << 16)

    def do_check(self, arg):
        """check: compare the final state with the ISS run of the loaded program."""
        if self.program is None:
            raise ValueError("load a program first (in this session)")
        state = self.client.dump()
        diffs = compare_with_iss(state, self.program, self.max_cycles)
        if diffs:
            self.failed = True
            self.say(self.st.bad(f"{len(diffs)} differences with the ISS:"))
            for line in diffs:
                self.say("  " + line)
        else:
            self.say(self.st.good(f"matches the ISS: {state.halt_reason_name}, "
                                  f"{state.cycles} cycles, registers and data memory equal"))
        self.state = state

    def do_quit(self, arg):
        """quit: exit."""
        return True

    do_exit = do_quit
    do_EOF = do_quit


def main(argv=None):
    parser = argparse.ArgumentParser(description="TP3 RV32I debug CLI")
    parser.add_argument("--port", required=True, help="serial port, e.g. COM5 or /dev/ttyUSB1")
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT,
                        help="seconds to wait for each response")
    parser.add_argument("--max-cycles", type=int, default=DEFAULT_MAX_CYCLES,
                        help="MAX_CYCLES of the bitstream, used by 'check'")
    parser.add_argument("-c", "--command", action="append", default=[],
                        help="run this command and exit (can be repeated)")
    parser.add_argument("--no-color", action="store_true")
    args = parser.parse_args(argv)

    import serial  # pyserial
    color = not args.no_color and sys.stdout.isatty()
    if color:
        enable_windows_ansi()
    with serial.Serial(args.port, args.baud, timeout=args.timeout) as ser:
        ser.reset_input_buffer()
        shell = Shell(DebugClient(ser), Style(color), args.max_cycles)
        if args.command:
            for line in args.command:
                shell.say(Style(color).bold(f"rv> {line}"))
                shell.onecmd(line)
                if shell.failed:
                    return 1
            return 0
        shell.cmdloop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
