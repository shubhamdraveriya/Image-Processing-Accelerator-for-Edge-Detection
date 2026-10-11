## UNVERIFIED SCAFFOLDING: not yet run through Vivado or tested on a board.
## Basys 3 (XC7A35T-1CPG236C) pin map for rtl/board/basys3_top.sv
## The 100 MHz input clock constraint comes from the clk_wiz_0 IP's own XDC
## (create_clock -period 10 on clk_in1), so it is not repeated here.

## Clock and reset
set_property -dict {PACKAGE_PIN W5  IOSTANDARD LVCMOS33} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports rst]        ;# BTNC

## Downstream ready (SW0)
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports ready_in]

## Serial output on Pmod JA (JA1 data, JA2 valid, JA3 last bit of each pixel)
set_property -dict {PACKAGE_PIN J1  IOSTANDARD LVCMOS33} [get_ports final_serial_out]
set_property -dict {PACKAGE_PIN L2  IOSTANDARD LVCMOS33} [get_ports final_valid_out]
set_property -dict {PACKAGE_PIN J2  IOSTANDARD LVCMOS33} [get_ports final_bit_last]

## Status LEDs
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports led_valid]        ;# LD0
set_property -dict {PACKAGE_PIN P1  IOSTANDARD LVCMOS33} [get_ports led_framing_err]  ;# LD14
set_property -dict {PACKAGE_PIN L1  IOSTANDARD LVCMOS33} [get_ports led_done]         ;# LD15

## Configuration
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]

## Asynchronous / quasi-static I/O
set_false_path -from [get_ports {rst ready_in}]
set_false_path -to   [get_ports {final_serial_out final_valid_out final_bit_last led_*}]

## Gray-code pointer crossings in axis_async_fifo: bound the skew instead of
## letting the tool time them as synchronous 100 -> 200 MHz paths.
set_max_delay -datapath_only -from [get_cells -hier -filter {NAME =~ *u_cdc/wgray_reg[*]}] \
                             -to   [get_cells -hier -filter {NAME =~ *u_cdc/wgray_s1_reg[*]}] 5.000
set_max_delay -datapath_only -from [get_cells -hier -filter {NAME =~ *u_cdc/rgray_reg[*]}] \
                             -to   [get_cells -hier -filter {NAME =~ *u_cdc/rgray_s1_reg[*]}] 5.000
