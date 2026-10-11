# Out-of-context synthesis + implementation of the vendor-neutral core for a
# given part, to report utilisation and timing without a board.
#
#   vivado -mode batch -source scripts/vivado/synth_ooc.tcl -tclargs zcu106
#   vivado -mode batch -source scripts/vivado/synth_ooc.tcl -tclargs ku060
#
#   zcu106 : xczu7ev-ffvc1156-2-e (ZCU106 board part), 250 MHz target
#   ku060  : xcku060-ffva1156-2-e, commercial stand-in for the rad-tolerant
#            XQRKU060 (same Kintex UltraScale die), 200 MHz target
#
# The top is edge_pipeline (no board I/O, no IP), so the result shows exactly
# what the datapath costs on each part. Outputs go to vivado_out/<target>/.
source [file join [file dirname [info script]] sources.tcl]

set target [expr {[llength $argv] > 0 ? [lindex $argv 0] : "zcu106"}]
switch -- $target {
    zcu106  { set PART xczu7ev-ffvc1156-2-e; set PERIOD 4.000 }
    ku060   { set PART xcku060-ffva1156-2-e; set PERIOD 5.000 }
    default { error "unknown target $target (use zcu106 or ku060)" }
}
set OUT $ROOT/vivado_out/$target
file mkdir $OUT

set_part $PART
read_verilog -sv $CORE_RTL
synth_design -top edge_pipeline -part $PART -mode out_of_context \
    -generic DW=8 -generic IMG_W=64 -generic IMG_H=64

create_clock -name clk -period $PERIOD [get_ports clk]
set_input_delay  -clock clk 0.5 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock clk 0.5 [get_ports -filter {DIRECTION == OUT}]

opt_design
place_design
route_design

report_utilization    -file $OUT/utilization.rpt
report_timing_summary -file $OUT/timing_summary.rpt
