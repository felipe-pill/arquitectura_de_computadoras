## ---------- Clock 100 MHz ----------
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk100mhz]
create_clock -period 10.000 -name sys_clk -waveform {0 5} [get_ports clk100mhz]

## ---------- Reset (BTN_CENTER) ----------
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports btn_reset]

## ---------- USB-UART ----------
# RX from PC -> FPGA input (idles high; pull-up helps when cable is unplugged)
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 PULLUP true } [get_ports uart_rxd]
# TX from FPGA -> PC
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports uart_txd]

## ---------- (Optional) LEDs ----------
# Example if your HDL exposes these ports:
# set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports led_tx_start]  ;# LD0
# set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports led_tx_done]   ;# LD1
