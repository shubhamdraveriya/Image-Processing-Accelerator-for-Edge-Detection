
set_property PACKAGE_PIN W5 [get_ports sys_clk]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
#create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} -add [get_ports sys_clk]



set_property PACKAGE_PIN U18 [get_ports rst]
set_property IOSTANDARD LVCMOS33 [get_ports rst]

set_property PACKAGE_PIN V17 [get_ports ready_in]
set_property IOSTANDARD LVCMOS33 [get_ports ready_in]


set_property PACKAGE_PIN U16 [get_ports final_valid_out]
set_property IOSTANDARD LVCMOS33 [get_ports final_valid_out]


set_property PACKAGE_PIN V13 [get_ports {final_pixel_out[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {final_pixel_out[0]}]

# final_pixel_out[1] (Using LED 9 - led[9])
set_property PACKAGE_PIN V3 [get_ports {final_pixel_out[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {final_pixel_out[1]}]

# final_pixel_out[2] (Using LED 10 - led[10])
set_property PACKAGE_PIN W3 [get_ports {final_pixel_out[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {final_pixel_out[2]}]

# final_pixel_out[3] (Using LED 11 - led[11])
set_property PACKAGE_PIN U3 [get_ports {final_pixel_out[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {final_pixel_out[3]}]

# final_pixel_out[4] (Using LED 12 - led[12])
set_property PACKAGE_PIN P3 [get_ports {final_pixel_out[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {final_pixel_out[4]}]

# final_pixel_out[5] (Using LED 13 - led[13])
set_property PACKAGE_PIN N3 [get_ports {final_pixel_out[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {final_pixel_out[5]}]

# final_pixel_out[6] (Using LED 14 - led[14])
set_property PACKAGE_PIN P1 [get_ports {final_pixel_out[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {final_pixel_out[6]}]

# final_pixel_out[7] (Using LED 15 - led[15])
set_property PACKAGE_PIN L1 [get_ports {final_pixel_out[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {final_pixel_out[7]}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]

set_false_path -from [get_ports {rst ready_in}]
set_false_path -to [get_ports {final_pixel_out[*] final_valid_out}]