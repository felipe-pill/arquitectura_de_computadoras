## Basys 3 constraints for TP3 (top: basys3_top)

## ---------- Clock 100 MHz ----------
# Only the board clock is constrained; Vivado derives the MMCM output clock.
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk100mhz]
create_clock -period 10.000 -name sys_clk -waveform {0 5} [get_ports clk100mhz]

## ---------- Reset (BTN_CENTER) ----------
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports btn_reset]

## ---------- USB-UART ----------
# RX from PC -> FPGA input (idles high; pull-up helps when cable is unplugged)
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 PULLUP true } [get_ports uart_rxd]
# TX from FPGA -> PC
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports uart_txd]

## ---------- LEDs ----------
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN U19 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN V19 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN W18 IOSTANDARD LVCMOS33 } [get_ports {led[4]}]
set_property -dict { PACKAGE_PIN U15 IOSTANDARD LVCMOS33 } [get_ports {led[5]}]
set_property -dict { PACKAGE_PIN U14 IOSTANDARD LVCMOS33 } [get_ports {led[6]}]
set_property -dict { PACKAGE_PIN V14 IOSTANDARD LVCMOS33 } [get_ports {led[7]}]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports {led[8]}]
set_property -dict { PACKAGE_PIN V3  IOSTANDARD LVCMOS33 } [get_ports {led[9]}]
set_property -dict { PACKAGE_PIN W3  IOSTANDARD LVCMOS33 } [get_ports {led[10]}]
set_property -dict { PACKAGE_PIN U3  IOSTANDARD LVCMOS33 } [get_ports {led[11]}]
set_property -dict { PACKAGE_PIN P3  IOSTANDARD LVCMOS33 } [get_ports {led[12]}]
set_property -dict { PACKAGE_PIN N3  IOSTANDARD LVCMOS33 } [get_ports {led[13]}]
set_property -dict { PACKAGE_PIN P1  IOSTANDARD LVCMOS33 } [get_ports {led[14]}]
set_property -dict { PACKAGE_PIN L1  IOSTANDARD LVCMOS33 } [get_ports {led[15]}]

## ---------- Asynchronous I/O ----------
# btn_reset and uart_rxd go through 2-FF synchronizers; uart_txd and the
# LEDs are read by a human or by a 115200 baud UART, not by a clocked
# device, so these paths have no meaningful I/O timing.
set_false_path -from [get_ports {btn_reset uart_rxd}]
set_false_path -to   [get_ports {uart_txd led[*]}]

## ---------- Configuration ----------
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
