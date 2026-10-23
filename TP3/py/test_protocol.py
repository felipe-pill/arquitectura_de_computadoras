"""Unit tests for protocol.py (host side of docs/protocol.md).

Run from the repo root:  python -m unittest discover -s TP3/py -v
Expected frames are the examples of protocol.md section 7. STATE payloads
are built here with an encoder written from the byte offsets of
protocol.md section 6, independently of decode_state().
"""

import struct
import unittest

import isa
import protocol
from protocol import DebugClient, DebugError, ProtocolError


def h(text):
    return bytes.fromhex(text)


# ---------------------------------------------------------------------------
# Test helpers: STATE encoder (protocol.md 6) and a fake serial port
# ---------------------------------------------------------------------------

def make_state(flags=0, reason=0, prog_len=0, cycles=0, pc=0,
               if_id=(0, 0x13, 0), id_ex=(0, 0, 0, 0, 0), ex_mem=(0, 0, 0, 0),
               mem_wb=(0, 0, 0), regs=None, dmem=()):
    """if_id = (pc, instr, ctrl), id_ex = (pc, rs1_data, rs2_data, imm, ctrl),
    ex_mem = (pc, result, store_data, ctrl), mem_wb = (pc, wb_data, ctrl)."""
    regs = regs or [0] * 32
    out = bytearray(12)
    out[0] = flags
    out[1] = reason
    out[2:4] = prog_len.to_bytes(2, "little")
    out[4:8] = cycles.to_bytes(4, "little")
    out[8:10] = len(dmem).to_bytes(2, "little")
    for word in (pc, *if_id, *id_ex, *ex_mem, *mem_wb, *regs, *dmem):
        out += (word & 0xFFFFFFFF).to_bytes(4, "little")
    return bytes(out)


def response(code, payload=b""):
    return protocol.frame(code, payload, sof=protocol.SOF_RESPONSE)


class FakeSerial:
    """Serial port double: records written bytes, replays queued bytes.

    `responder(cmd, payload) -> bytes` (optional) builds the reply to each
    complete request frame written; otherwise replies come from `queue`."""

    def __init__(self, responder=None):
        self.responder = responder
        self.written = bytearray()
        self.rx = bytearray()
        self._pending = bytearray()

    def queue(self, data):
        self.rx += data

    def write(self, data):
        self.written += data
        self._pending += data
        while self.responder and len(self._pending) >= 5:
            assert self._pending[0] == protocol.SOF_REQUEST
            length = struct.unpack_from("<H", self._pending, 2)[0]
            if len(self._pending) < 5 + length:
                break
            req = bytes(self._pending[:5 + length])
            del self._pending[:5 + length]
            assert sum(req[1:]) & 0xFF == 0, "request checksum"
            self.rx += self.responder(req[1], req[4:4 + length])
        return len(data)

    def read(self, n):
        data = bytes(self.rx[:n])
        del self.rx[:n]
        return data


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

class TestFrames(unittest.TestCase):
    def test_request_examples_from_protocol_md(self):
        load = struct.pack("<II", 0x00500093, 0x00100073)
        self.assertEqual(protocol.frame(protocol.CMD_LOAD, load), h("A5 01 08 00 93 00 50 00 73 00 10 00 91"))
        self.assertEqual(protocol.frame(protocol.CMD_RESET), h("A5 02 00 00 FE"))
        self.assertEqual(protocol.frame(protocol.CMD_RUN), h("A5 03 00 00 FD"))
        self.assertEqual(protocol.frame(protocol.CMD_STEP), h("A5 04 00 00 FC"))
        self.assertEqual(protocol.frame(protocol.CMD_DUMP), h("A5 05 00 00 FB"))

    def test_response_examples_from_protocol_md(self):
        for raw, rsp, payload in (("5A 81 02 00 02 00 7B", 0x81, h("02 00")),
                                  ("5A 82 00 00 7E", 0x82, b""),
                                  ("5A E4 01 00 04 17", 0xE4, h("04")),
                                  ("5A E1 01 00 01 1D", 0xE1, h("01"))):
            ser = FakeSerial()
            ser.queue(h(raw))
            self.assertEqual(protocol.read_frame(ser), (rsp, payload))

    def test_read_frame_errors(self):
        for raw, msg in (("", "timeout"), ("A5 82 00 00 7E", "bad SOF"),
                         ("5A 82 00 00 7F", "checksum"), ("5A 85 05 00 00", "timeout")):
            ser = FakeSerial()
            ser.queue(h(raw))
            with self.assertRaisesRegex(ProtocolError, msg):
                protocol.read_frame(ser)


# ---------------------------------------------------------------------------
# STATE decoding
# ---------------------------------------------------------------------------

class TestDecodeState(unittest.TestCase):
    def test_every_field(self):
        regs = [0x01010101 * r for r in range(32)]
        # ID/EX ctrl: rs1=1 rs2=2 rd=3 alu_op=0b1101 alu_src link reg_write
        # mem_read mem_write funct3=0b101 branch jalr is_halt valid
        idex_ctrl = (1 | 2 << 5 | 3 << 10 | 0b1101 << 15 | 1 << 19 | 1 << 20 | 1 << 21
                     | 1 << 22 | 1 << 23 | 0b101 << 24 | 1 << 27 | 1 << 28 | 1 << 29 | 1 << 30)
        exmem_ctrl = 7 | 1 << 5 | 1 << 6 | 1 << 7 | 0b010 << 8 | 1 << 11 | 1 << 12
        memwb_ctrl = 9 | 1 << 5 | 1 << 6 | 1 << 7 | 1 << 8
        payload = make_state(
            flags=0b101, reason=4, prog_len=0x123, cycles=0xA1B2C3D4, pc=0x40,
            if_id=(0x3C, 0x00500093, 1 | 4 << 1),
            id_ex=(0x38, 0x11, 0x22, 0xFFFFFFF8, idex_ctrl),
            ex_mem=(0x34, 0x33, 0x44, exmem_ctrl),
            mem_wb=(0x30, 0x55, memwb_ctrl),
            regs=regs, dmem=(0xDEADBEEF, 7))
        self.assertEqual(len(payload), 204 + 8)
        s = protocol.decode_state(payload)
        self.assertEqual((s.halted, s.halting, s.prog_valid), (True, False, True))
        self.assertEqual((s.halt_reason, s.halt_reason_name), (4, "TIMEOUT"))
        self.assertEqual((s.prog_len, s.cycles, s.pc), (0x123, 0xA1B2C3D4, 0x40))
        self.assertEqual(s.if_id, protocol.IfId(0x3C, 0x00500093, True, 4))
        e = s.id_ex
        self.assertEqual((e.pc, e.rs1_data, e.rs2_data, e.imm), (0x38, 0x11, 0x22, 0xFFFFFFF8))
        self.assertEqual((e.rs1, e.rs2, e.rd, e.alu_op, e.funct3), (1, 2, 3, 0b1101, 0b101))
        self.assertTrue(all((e.alu_src, e.link, e.reg_write, e.mem_read, e.mem_write,
                             e.branch, e.jalr, e.is_halt, e.valid)))
        self.assertEqual(s.ex_mem, protocol.ExMem(0x34, 0x33, 0x44, 7, True, True, True, 0b010, True, True))
        self.assertEqual(s.mem_wb, protocol.MemWb(0x30, 0x55, 9, True, True, True, True))
        self.assertEqual(s.regs, regs)
        self.assertEqual((s.dmem, s.dmem_used), ([0xDEADBEEF, 7], 2))

    def test_single_bits_land_in_their_field(self):
        # one ID/EX control bit at a time: only the matching field changes
        names = ["alu_src", "link", "reg_write", "mem_read", "mem_write", None, None, None,
                 "branch", "jalr", "is_halt", "valid"]
        for bit, name in zip(range(19, 31), names):
            if name is None:
                continue
            s = protocol.decode_state(make_state(id_ex=(0, 0, 0, 0, 1 << bit)))
            flags = {n: getattr(s.id_ex, n) for n in names if n}
            self.assertEqual([n for n, v in flags.items() if v], [name], f"bit {bit}")

    def test_bad_lengths(self):
        good = make_state(dmem=(1, 2))
        for bad in (good[:-1], good[:203], good + b"\0\0\0\0"):
            with self.assertRaises(ProtocolError):
                protocol.decode_state(bad)


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

class TestClient(unittest.TestCase):
    def test_load_sends_little_endian_words(self):
        ser = FakeSerial()
        ser.queue(response(0x81, struct.pack("<H", 2)))
        self.assertEqual(DebugClient(ser).load([0x00500093, 0x00100073]), 2)
        self.assertEqual(bytes(ser.written), h("A5 01 08 00 93 00 50 00 73 00 10 00 91"))

    def test_commands_and_state_responses(self):
        state = make_state(flags=0b101, reason=1, cycles=6, pc=4, regs=[0, 5] + [0] * 30)
        for method, code in (("run", 0x83), ("step", 0x84), ("dump", 0x85)):
            ser = FakeSerial()
            ser.queue(response(code, state))
            s = getattr(DebugClient(ser), method)()
            self.assertEqual((s.cycles, s.pc, s.regs[1]), (6, 4, 5))
            self.assertEqual(ser.written[1], code & 0x7F)
        ser = FakeSerial()
        ser.queue(response(0x82))
        DebugClient(ser).reset()
        self.assertEqual(bytes(ser.written), h("A5 02 00 00 FE"))

    def test_error_responses_raise(self):
        for code in (0xE1, 0xE2, 0xE3, 0xE4, 0xE5):
            ser = FakeSerial()
            ser.queue(response(code, bytes([protocol.CMD_STEP])))
            with self.assertRaises(DebugError) as ctx:
                DebugClient(ser).step()
            self.assertEqual((ctx.exception.code, ctx.exception.cmd), (code, protocol.CMD_STEP))
            self.assertIn(protocol.ERROR_NAMES[code], str(ctx.exception))

    def test_unexpected_response_and_timeout(self):
        ser = FakeSerial()
        ser.queue(response(0x85, make_state()))
        with self.assertRaisesRegex(ProtocolError, "unexpected response"):
            DebugClient(ser).run()
        with self.assertRaisesRegex(ProtocolError, "timeout"):
            DebugClient(FakeSerial()).dump()


if __name__ == "__main__":
    unittest.main()
