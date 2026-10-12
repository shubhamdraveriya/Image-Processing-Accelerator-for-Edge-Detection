# Run with Vivado 2018.2; results are in the README (Vivado results).
# Out-of-context synthesis + implementation for a given part, to report
# utilisation and timing without a board.
#
#   vivado -mode batch -source scripts/vivado/synth_ooc.tcl -tclargs <target> [<design>]
#
#   target : zcu106  xczu7ev-ffvc1156-2-e (ZCU106 board part), 250 MHz
#            ku060   xcku060-ffva1156-2-e, commercial stand-in for the
#                    rad-tolerant XQRKU060 (same Kintex UltraScale die), 200 MHz
#   design : edge     edge_pipeline, 64 x 64 x 8 bit (default)
#            payload  payload_top, default parameters
#            flight   payload_top with ECC = 1 and TMR = 1
#
# No board I/O and no IP, so the result shows exactly what the datapath costs
# on each part. Outputs go to vivado_out/<target>_<design>/.
source [file join [file dirname [info script]] sources.tcl]

set target [expr {[llength $argv] > 0 ? [lindex $argv 0] : "zcu106"}]
set design [expr {[llength $argv] > 1 ? [lindex $argv 1] : "edge"}]
switch -- $target {
    zcu106  { set PART xczu7ev-ffvc1156-2-e; set PERIOD 4.000 }
    ku060   { set PART xcku060-ffva1156-2-e; set PERIOD 5.000 }
    default { error "unknown target $target (use zcu106 or ku060)" }
}
set OUT $ROOT/vivado_out/${target}_${design}
file mkdir $OUT

set_part $PART
switch -- $design {
    edge {
        read_verilog -sv $CORE_RTL
        synth_design -top edge_pipeline -part $PART -mode out_of_context \
            -generic DW=8 -generic IMG_W=64 -generic IMG_H=64
    }
    payload {
        read_verilog -sv $PAYLOAD_RTL
        synth_design -top payload_top -part $PART -mode out_of_context
    }
    flight {
        read_verilog -sv $PAYLOAD_RTL
        synth_design -top payload_top -part $PART -mode out_of_context \
            -generic ECC=1'b1 -generic TMR=1'b1
    }
    default { error "unknown design $design (use edge, payload or flight)" }
}

create_clock -name clk -period $PERIOD [get_ports clk]
set_input_delay  -clock clk 0.5 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock clk 0.5 [get_ports -filter {DIRECTION == OUT}]

opt_design
place_design
route_design

report_utilization    -file $OUT/utilization.rpt
report_timing_summary -file $OUT/timing_summary.rpt
write_checkpoint -force $OUT/routed.dcp
