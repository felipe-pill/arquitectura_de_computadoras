# pip install pyserial
import serial, time

PORT = "COM5"   # MODIFICAR AL PUERTO DONDE SE CONECTE LA FPGA!!
BAUD = 115200

HDR_IN  = bytes([0xAA])
HDR_OUT = bytes([0x55])

# Tabla de operaciones
OPS = {
    "ADD": 0b100000,
    "SUB": 0b100010,
    "AND": 0b100100,
    "OR":  0b100101,
    "XOR": 0b100110,
    "NOR": 0b100111,
    "SRL": 0b000010,
    "SRA": 0b000011
}

def xfer(ser, op, a, b):
    pkt = HDR_IN + bytes([op & 0xFF, a & 0xFF, b & 0xFF])
    ser.write(pkt); ser.flush()
    got = ser.read(3)   # esperamos 0x55, result, flags
    return got

with serial.Serial(PORT, BAUD, timeout=1) as ser:
    time.sleep(0.2)
    ser.reset_input_buffer()
    ser.reset_output_buffer()

    print("=== Consola UART–ALU ===")
    print("Operaciones disponibles:", ", ".join(OPS.keys()))
    print("Escribí 'exit' para salir\n")

    while True:
        op_str = input("Operación (ADD/SUB/AND/OR/XOR/NOR/SRL/SRA): ").strip().upper()
        if op_str == "EXIT":
            break
        if op_str not in OPS:
            print("--- Operación inválida --- \n")
            continue

        try:
            a = int(input("A = "), 0)  # permite decimal o hex (ej: 15 o 0xA5)
            b = int(input("B = "), 0)
        except ValueError:
            print("--- Valor inválido --- \n")
            continue

        rep = xfer(ser, OPS[op_str], a, b)

        if len(rep) != 3 or rep[0] != 0x55:
            print("--- Respuesta incorrecta ---", rep)
        else:
            res, flags = rep[1], rep[2]
            z = flags & 1
            n = (flags >> 1) & 1
            v = (flags >> 3) & 1
            c = (flags >> 2) & 1
            print(f"➡ Resultado: 0x{res:02X} ({res})")
            print(f"   Flags -> Z:{z}  N:{n}  V:{v}  C:{c}\n")
