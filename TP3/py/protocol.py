"""Host side of the TP3 Debug Unit UART protocol (docs/protocol.md).

- frame(): build a request frame; read_frame(): read and check a response.
- decode_state(): turn a STATE payload into a State object with named fields.
- DebugClient: the five commands (LOAD, RESET, RUN, STEP, DUMP) over any
  serial-like object with write(bytes) and read(n) (pyserial.Serial or a
  fake one in tests). Error responses raise DebugError.
"""

import struct
from dataclasses import dataclass, field

import isa

SOF_REQUEST = 0xA5
SOF_RESPONSE = 0x5A

CMD_LOAD = 0x01
CMD_RESET = 0x02
CMD_RUN = 0x03
CMD_STEP = 0x04
CMD_DUMP = 0x05
CMD_NAMES = {CMD_LOAD: "LOAD", CMD_RESET: "RESET", CMD_RUN: "RUN",
             CMD_STEP: "STEP", CMD_DUMP: "DUMP"}

ERR_CHECKSUM = 0xE1
ERR_UNKNOWN_CMD = 0xE2
ERR_LENGTH = 0xE3
ERR_HALTED = 0xE4
ERR_NO_PROGRAM = 0xE5
ERROR_NAMES = {
    ERR_CHECKSUM: "ERR_CHECKSUM",
    ERR_UNKNOWN_CMD: "ERR_UNKNOWN_CMD",
    ERR_LENGTH: "ERR_LENGTH",
    ERR_HALTED: "ERR_HALTED",
    ERR_NO_PROGRAM: "ERR_NO_PROGRAM",
}

STATE_BASE_LEN = 204  # STATE length without dmem words (protocol.md 6)


class ProtocolError(Exception):
    """Malformed or missing response (timeout, bad SOF, bad checksum)."""


class DebugError(Exception):
    """The Debug Unit answered with an error code."""

    def __init__(self, code, cmd):
        self.code = code
        self.cmd = cmd
        super().__init__(f"{ERROR_NAMES.get(code, f'0x{code:02X}')} "
                         f"(command {CMD_NAMES.get(cmd, f'0x{cmd:02X}')})")


# ---------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------

def checksum(body):
    """CHK so that the 8-bit sum of CMD..CHK is 0 (protocol.md 3.3)."""
    return (-sum(body)) & 0xFF


def frame(code, payload=b"", sof=SOF_REQUEST):
    body = bytes([code]) + struct.pack("<H", len(payload)) + bytes(payload)
    return bytes([sof]) + body + bytes([checksum(body)])


def read_frame(ser):
    """Read one response frame. Returns (rsp, payload)."""
    def read_exact(n):
        data = ser.read(n)
        if len(data) != n:
            raise ProtocolError(f"timeout: expected {n} bytes, got {len(data)}")
        return data

    sof = read_exact(1)[0]
    if sof != SOF_RESPONSE:
        raise ProtocolError(f"bad SOF 0x{sof:02X} (expected 0x{SOF_RESPONSE:02X})")
    head = read_exact(3)
    rsp, length = head[0], struct.unpack("<H", head[1:3])[0]
    payload = read_exact(length) if length else b""
    chk = read_exact(1)[0]
    if (sum(head) + sum(payload) + chk) & 0xFF:
        raise ProtocolError("bad response checksum")
    return rsp, payload


# ---------------------------------------------------------------------------
# STATE payload (protocol.md 6)
# ---------------------------------------------------------------------------

def _bits(value, lo, width):
    return (value >> lo) & ((1 << width) - 1)


@dataclass
class IfId:
    pc: int
    instr: int
    valid: bool
    stop_code: int


@dataclass
class IdEx:
    pc: int
    rs1_data: int
    rs2_data: int
    imm: int
    rs1: int
    rs2: int
    rd: int
    alu_op: int
    alu_src: bool
    link: bool
    reg_write: bool
    mem_read: bool
    mem_write: bool
    funct3: int
    branch: bool
    jalr: bool
    is_halt: bool
    valid: bool


@dataclass
class ExMem:
    pc: int
    result: int
    store_data: int
    rd: int
    reg_write: bool
    mem_read: bool
    mem_write: bool
    funct3: int
    is_halt: bool
    valid: bool


@dataclass
class MemWb:
    pc: int
    wb_data: int
    rd: int
    reg_write: bool
    mem_read: bool
    is_halt: bool
    valid: bool


@dataclass
class State:
    halted: bool
    halting: bool
    prog_valid: bool
    halt_reason: int
    prog_len: int
    cycles: int
    pc: int
    if_id: IfId
    id_ex: IdEx
    ex_mem: ExMem
    mem_wb: MemWb
    regs: list
    dmem: list = field(default_factory=list)   # words [0, dmem_used)

    @property
    def dmem_used(self):
        return len(self.dmem)

    @property
    def halt_reason_name(self):
        return isa.HALT_REASON_NAMES.get(self.halt_reason, f"?{self.halt_reason}")


def decode_state(payload):
    """Decode a STATE payload (bytes) into a State."""
    if len(payload) < STATE_BASE_LEN or (len(payload) - STATE_BASE_LEN) % 4:
        raise ProtocolError(f"bad STATE length {len(payload)}")
    flags, reason, prog_len, cycles, dmem_used = struct.unpack_from("<BBHIH", payload, 0)
    if len(payload) != STATE_BASE_LEN + 4 * dmem_used:
        raise ProtocolError(f"STATE length {len(payload)} does not match dmem_used={dmem_used}")
    w = struct.unpack_from("<16I", payload, 12)
    pc = w[0]
    if_id = IfId(pc=w[1], instr=w[2], valid=bool(_bits(w[3], 0, 1)),
                 stop_code=_bits(w[3], 1, 3))
    c = w[8]
    id_ex = IdEx(pc=w[4], rs1_data=w[5], rs2_data=w[6], imm=w[7],
                 rs1=_bits(c, 0, 5), rs2=_bits(c, 5, 5), rd=_bits(c, 10, 5),
                 alu_op=_bits(c, 15, 4), alu_src=bool(_bits(c, 19, 1)),
                 link=bool(_bits(c, 20, 1)), reg_write=bool(_bits(c, 21, 1)),
                 mem_read=bool(_bits(c, 22, 1)), mem_write=bool(_bits(c, 23, 1)),
                 funct3=_bits(c, 24, 3), branch=bool(_bits(c, 27, 1)),
                 jalr=bool(_bits(c, 28, 1)), is_halt=bool(_bits(c, 29, 1)),
                 valid=bool(_bits(c, 30, 1)))
    c = w[12]
    ex_mem = ExMem(pc=w[9], result=w[10], store_data=w[11],
                   rd=_bits(c, 0, 5), reg_write=bool(_bits(c, 5, 1)),
                   mem_read=bool(_bits(c, 6, 1)), mem_write=bool(_bits(c, 7, 1)),
                   funct3=_bits(c, 8, 3), is_halt=bool(_bits(c, 11, 1)),
                   valid=bool(_bits(c, 12, 1)))
    c = w[15]
    mem_wb = MemWb(pc=w[13], wb_data=w[14], rd=_bits(c, 0, 5),
                   reg_write=bool(_bits(c, 5, 1)), mem_read=bool(_bits(c, 6, 1)),
                   is_halt=bool(_bits(c, 7, 1)), valid=bool(_bits(c, 8, 1)))
    regs = list(struct.unpack_from("<32I", payload, 76))
    dmem = list(struct.unpack_from(f"<{dmem_used}I", payload, STATE_BASE_LEN))
    return State(halted=bool(flags & 1), halting=bool(flags & 2),
                 prog_valid=bool(flags & 4), halt_reason=reason, prog_len=prog_len,
                 cycles=cycles, pc=pc, if_id=if_id, id_ex=id_ex, ex_mem=ex_mem,
                 mem_wb=mem_wb, regs=regs, dmem=dmem)


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

class DebugClient:
    """The Debug Unit commands over a serial-like object (stop-and-wait)."""

    def __init__(self, ser):
        self.ser = ser

    def _transaction(self, cmd, payload=b""):
        self.ser.write(frame(cmd, payload))
        rsp, data = read_frame(self.ser)
        if rsp == (cmd | 0x80):
            return data
        if rsp in ERROR_NAMES:
            raise DebugError(rsp, data[0] if data else cmd)
        raise ProtocolError(f"unexpected response 0x{rsp:02X} to {CMD_NAMES.get(cmd, cmd)}")

    def load(self, words):
        """Load a program (list of 32-bit words). Returns the word count."""
        payload = struct.pack(f"<{len(words)}I", *[w & isa.MASK32 for w in words])
        data = self._transaction(CMD_LOAD, payload)
        return struct.unpack("<H", data)[0]

    def reset(self):
        self._transaction(CMD_RESET)

    def run(self):
        return decode_state(self._transaction(CMD_RUN))

    def step(self):
        return decode_state(self._transaction(CMD_STEP))

    def dump(self):
        return decode_state(self._transaction(CMD_DUMP))
