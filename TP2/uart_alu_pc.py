# pip install pyserial
import serial, time

PORT = "COM3"   # <-- set your UART COM port
BAUD = 115200

HDR_IN  = bytes([0xAA])
HDR_OUT = bytes([0x55])

# opcodes from your ALU (6-bit values are placed in low bits of the byte)
OP_ADD = 0b100000
OP_SUB = 0b100010
OP_AND = 0b100100
OP_OR  = 0b100101
OP_XOR = 0b100110
OP_NOR = 0b100111
OP_SRL = 0b000010
OP_SRA = 0b000011

def xfer(op, a, b):
    pkt = HDR_IN + bytes([op & 0xFF, a & 0xFF, b & 0xFF])
    ser.write(pkt); ser.flush()
    # expect 0x55, RES, FLAGS
    got = ser.read(3)
    return got

with serial.Serial(PORT, BAUD, timeout=1) as ser:
    time.sleep(0.2)
    ser.reset_input_buffer(); ser.reset_output_buffer()

    for (name,op,a,b) in [
        ("ADD 15+27", OP_ADD, 15, 27),
        ("OR  A5|0F", OP_OR , 0xA5, 0x0F),
        ("SUB 10-20", OP_SUB, 10, 20),
        ("SRA 0x80>>2", OP_SRA, 0x80, 2),
    ]:
        rep = xfer(op,a,b)
        if len(rep) != 3 or rep[0] != 0x55:
            print(name, "-> bad reply:", rep); continue
        res, flags = rep[1], rep[2]
        z = flags & 1; n = (flags>>1)&1; c = (flags>>2)&1; v = (flags>>3)&1
        print(f"{name:12} => RES=0x{res:02X}  FLAGS(ZNV C)={z}{n}{v}{c}")
