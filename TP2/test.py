# pip install pyserial
import serial, time
ser = serial.Serial('COM3', 115200, timeout=1)  # or COM3 on Windows
time.sleep(0.2)
ser.reset_input_buffer(); ser.reset_output_buffer()

msg = b'Hello Basys3!\r\n'
ser.write(msg)
print("TX:", msg)
rx = ser.read(len(msg))
print("RX:", rx)
