#!/usr/bin/env bash
# Board-free synthesis check with Yosys (no Vivado needed).
#
# Synthesises edge_accel_top for 7-series (Basys 3), UltraScale (KU060 /
# XQRKU060) and UltraScale+ (ZCU106) cell libraries and fails if:
#   - the RTL does not elaborate or synthesise,
#   - the netlist has latches or other check problems,
#   - any SRL primitive appears (banned in the flight build: configuration
#     scrubbing cannot correct SRL contents).
# Writes per-family logs and a cell summary to build/yosys/.
#
# This proves the RTL is synthesisable and maps to the expected primitives.
# It is NOT a substitute for Vivado timing closure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/yosys"
mkdir -p "$OUT"
SRCS="$ROOT/rtl/common/*.sv $ROOT/rtl/edge/*.sv $ROOT/rtl/top/*.sv"
status=0

for fam in xc7 xcu xcup; do
    log="$OUT/$fam.log"
    # Run from data/ so the ROM's $readmemh finds its image.
    if ! (cd "$ROOT/data" && yosys -q -l "$log" -p "
            read_verilog -sv -DSYNTHESIS $SRCS;
            synth_xilinx -family $fam -top edge_accel_top;
            check -assert;
            select -assert-none t:SRL* t:\$dlatch t:\$_DLATCH_*;
            tee -o $OUT/$fam.stat stat" >/dev/null 2>&1); then
        echo "FAIL  $fam  (see build/yosys/$fam.log)"
        status=1
        continue
    fi
    summary=$(awk '/=== design hierarchy ===/{f=1} f && /^ +(LUT|FD|RAM|CARRY|DSP|SRL)/{printf "%s=%s ", $1, $2}' "$OUT/$fam.stat")
    echo "PASS  $fam  $summary"
done
exit $status
