#!/usr/bin/env bash
# Board-free synthesis check with Yosys (no Vivado needed).
#
# Synthesises each top (edge_accel_top, hs_frontend, ccsds123_top) for 7-series (Basys 3), UltraScale (KU060 /
# XQRKU060) and UltraScale+ (ZCU106) cell libraries and fails if:
#   - the RTL does not elaborate or synthesise,
#   - the netlist has latches or other check problems,
#   - any SRL primitive appears (banned in the flight build: configuration
#     scrubbing cannot correct SRL contents). Yosys ignores the per-signal
#     shreg_extract = "no" attributes that Vivado honours, so SRL inference is
#     switched off globally (-nosrl), as a flight Vivado flow would do; the
#     check still catches SRLs instantiated by hand. The design is flattened
#     (as Vivado does by default) so constants propagate across modules.
# Writes per-family logs and a cell summary to build/yosys/.
#
# This proves the RTL is synthesisable and maps to the expected primitives.
# It is NOT a substitute for Vivado timing closure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/build/yosys"
mkdir -p "$OUT"
status=0

# top[@flight] : source directories. Default parameters are used; @flight
# builds the same top with ECC = 1 and TMR = 1 (the flight configuration).
TOPS="${TOPS:-edge_accel_top:common,edge,top hs_frontend:common,hs ccsds123_top:common,rel,ccsds123 ccsds123_top@flight:common,rel,ccsds123}"

for entry in $TOPS; do
top=${entry%%:*}
chparam=""
variant=""
fams="xc7 xcu xcup"
if [[ $top == *@flight ]]; then
    top=${top%@flight}
    chparam="chparam -set ECC 1 -set TMR 1 $top;"
    variant="_flight"
    fams="xcu xcup"          # flight targets: XQRKU060 (UltraScale) and ZCU106 / Versal-class parts
fi
SRCS=""
for d in $(echo "${entry#*:}" | tr ',' ' '); do SRCS="$SRCS $ROOT/rtl/$d/*.sv"; done
for fam in $fams; do
    tag="${top}${variant}_$fam"
    log="$OUT/$tag.log"
    # Run from data/ so the ROM's $readmemh finds its image.
    if ! (cd "$ROOT/data" && yosys -q -l "$log" -p "
            read_verilog -sv -DSYNTHESIS $SRCS;
            $chparam
            synth_xilinx -family $fam -top $top -nosrl -flatten;
            check -assert;
            select -assert-none t:SRL* t:\$dlatch t:\$_DLATCH_*;
            tee -o $OUT/$tag.stat stat" >/dev/null 2>&1); then
        echo "FAIL  $tag  (see build/yosys/$tag.log)"
        status=1
        continue
    fi
    # cell totals: the last count of each cell type (the design total)
    summary=$(awk '/^ +(LUT|FD|RAM|CARRY|DSP|SRL)/{c[$1]=$2} END{for(k in c) print k "=" c[k]}' "$OUT/$tag.stat" \
              | sort | tr '\n' ' ')
    echo "PASS  $tag  $summary"
done
done
exit $status
