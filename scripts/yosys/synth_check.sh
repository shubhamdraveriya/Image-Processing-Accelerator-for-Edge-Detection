#!/usr/bin/env bash
# Board-free synthesis check with Yosys (no Vivado needed).
#
# Synthesises each top (edge_accel_top, hs_frontend) for 7-series (Basys 3), UltraScale (KU060 /
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
status=0

# top : source directories (defaults of each top's parameters are used)
TOPS="edge_accel_top:common,edge,top hs_frontend:common,hs"

for entry in $TOPS; do
top=${entry%%:*}
SRCS=""
for d in $(echo "${entry#*:}" | tr ',' ' '); do SRCS="$SRCS $ROOT/rtl/$d/*.sv"; done
for fam in xc7 xcu xcup; do
    tag="${top}_$fam"
    log="$OUT/$tag.log"
    # Run from data/ so the ROM's $readmemh finds its image.
    if ! (cd "$ROOT/data" && yosys -q -l "$log" -p "
            read_verilog -sv -DSYNTHESIS $SRCS;
            synth_xilinx -family $fam -top $top;
            check -assert;
            select -assert-none t:SRL* t:\$dlatch t:\$_DLATCH_*;
            tee -o $OUT/$tag.stat stat" >/dev/null 2>&1); then
        echo "FAIL  $tag  (see build/yosys/$tag.log)"
        status=1
        continue
    fi
    summary=$(awk '/=== design hierarchy ===/{f=1} f && /^ +(LUT|FD|RAM|CARRY|DSP|SRL)/{printf "%s=%s ", $1, $2}' "$OUT/$tag.stat")
    echo "PASS  $tag  $summary"
done
done
exit $status
