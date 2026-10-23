"""Cross-check of the CLI's next-cycle hints against the RTL.

tb_cpu_core writes build/TP3/tb_cpu_core/core_trace.txt: for the first 300
cycles of each of its programs, the debug vector (bytes 12..75 of a STATE
dump) and the hazard decisions the core takes on the next edge (forwarding
selects, load-use stall, EX redirect + target, jal in ID + target, HALT
accepted). Here each cycle's vector is decoded with protocol.decode_state()
and cli.next_cycle_events() must predict exactly what the hardware did.

Needs the trace: run  .\\sim.bat TP3 tb_cpu_core  first (otherwise skipped).
"""

import os
import unittest

import cli
import protocol

TRACE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "..", "..", "build", "TP3", "tb_cpu_core", "core_trace.txt")
FWD = {"00": None, "10": "EX/MEM", "01": "MEM/WB"}


def state_from_vec(vec_hex, halting, halted):
    """A STATE payload with the given debug vector (registers and dmem 0)."""
    vec = bytes.fromhex(vec_hex)[::-1]          # %h prints MSB first
    flags = (1 if halted else 0) | (2 if halting else 0) | 4
    status = bytes([flags]) + bytes(11)
    return protocol.decode_state(status + vec + bytes(128))


class TestHintsAgainstRtl(unittest.TestCase):
    def test_trace(self):
        if not os.path.exists(TRACE):
            self.skipTest("no RTL trace: run .\\sim.bat TP3 tb_cpu_core first")
        cycles = 0
        seen = {k: 0 for k in ("fwd", "load_use", "redirect", "id_jal", "halt_accept")}
        name = "?"
        with open(TRACE) as f:
            for line in f:
                parts = line.split()
                if parts[0] == "T":
                    name = " ".join(parts[1:])
                    continue
                (vec, halting, halted, fwd_a, fwd_b, load_use, redirect,
                 target, id_jal, jal_target, halt_accept) = parts[1:]
                s = state_from_vec(vec, halting == "1", halted == "1")
                ev = cli.next_cycle_events(s)
                hw = {
                    "fwd_a": FWD[fwd_a], "fwd_b": FWD[fwd_b],
                    "load_use": load_use == "1", "redirect": redirect == "1",
                    "id_jal": id_jal == "1", "halt_accept": halt_accept == "1",
                }
                got = {k: ev[k] for k in hw}
                where = f"{name}, cycle {s.cycles if s.cycles else cycles}"
                self.assertEqual(got, hw, where)
                if hw["redirect"]:
                    self.assertEqual(ev["target"], int(target, 16), where)
                if hw["id_jal"]:
                    self.assertEqual(ev["jal_target"], int(jal_target, 16), where)
                cycles += 1
                seen["fwd"] += bool(hw["fwd_a"] or hw["fwd_b"])
                for k in ("load_use", "redirect", "id_jal", "halt_accept"):
                    seen[k] += hw[k]
        # The trace must actually exercise every kind of event
        self.assertGreater(cycles, 1000)
        for k, n in seen.items():
            self.assertGreater(n, 10, f"too few '{k}' events in the trace")
        print(f"\n  checked {cycles} cycles against the RTL: {seen}")


if __name__ == "__main__":
    unittest.main()
