# UNVERIFIED SCAFFOLDING: not yet run (no Vivado or board available).
# Full Basys 3 build (non-project mode): synth, place, route, reports, bitstream.
#   vivado -mode batch -source scripts/vivado/build_basys3.tcl
# Outputs go to vivado_out/basys3/.
source [file join [file dirname [info script]] sources.tcl]

set PART xc7a35tcpg236-1
set OUT  $ROOT/vivado_out/basys3
file mkdir $OUT

set_part $PART
read_verilog -sv $CORE_RTL
read_verilog -sv $ROOT/rtl/board/basys3_top.sv
read_mem $ROOT/data/image_stripes_64x64.mem
read_ip $ROOT/ip/clk_wiz_0/clk_wiz_0.xci
upgrade_ip [get_ips clk_wiz_0]
generate_target all [get_ips clk_wiz_0]
synth_ip [get_ips clk_wiz_0]
read_xdc $ROOT/constraints/basys3.xdc

synth_design -top basys3_top -part $PART
opt_design
place_design
phys_opt_design
route_design

report_utilization    -file $OUT/utilization.rpt
report_timing_summary -file $OUT/timing_summary.rpt
report_cdc            -file $OUT/cdc.rpt
report_power          -file $OUT/power.rpt
write_checkpoint -force $OUT/routed.dcp
write_bitstream -force $OUT/basys3_top.bit
