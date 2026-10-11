# Common RTL source list (sourced by the build scripts).
set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
set CORE_RTL [concat \
    [lsort [glob $ROOT/rtl/common/*.sv]] \
    [lsort [glob $ROOT/rtl/edge/*.sv]] \
    [lsort [glob $ROOT/rtl/top/*.sv]]]
# the hyperspectral payload: front end, CCSDS 123 compressor, reliability
# primitives, analytics and payload_top
set PAYLOAD_RTL [concat \
    [lsort [glob $ROOT/rtl/common/*.sv]] \
    $ROOT/rtl/edge/sobel_core.sv \
    [lsort [glob $ROOT/rtl/rel/*.sv]] \
    [lsort [glob $ROOT/rtl/hs/*.sv]] \
    [lsort [glob $ROOT/rtl/ccsds123/*.sv]] \
    [lsort [glob $ROOT/rtl/analytics/*.sv]] \
    [lsort [glob $ROOT/rtl/payload/*.sv]]]
