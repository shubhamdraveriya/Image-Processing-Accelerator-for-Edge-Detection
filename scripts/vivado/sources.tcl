# Common RTL source list (sourced by the build scripts).
set ROOT [file normalize [file join [file dirname [info script]] .. ..]]
set CORE_RTL [concat \
    [lsort [glob $ROOT/rtl/common/*.sv]] \
    [lsort [glob $ROOT/rtl/edge/*.sv]] \
    [lsort [glob $ROOT/rtl/top/*.sv]]]
