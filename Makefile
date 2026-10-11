# Open-source, board-free flow: golden model tests, Verilator lint,
# Icarus/Verilator regression, Yosys synthesis check.
# Vivado builds live in scripts/vivado/ (see README).

PY  ?= python3
RTL := rtl/common/*.sv rtl/edge/*.sv rtl/top/*.sv
HS  := rtl/common/*.sv rtl/hs/*.sv

.PHONY: all test model-test lint sim sim-verilator synth clean

all: test

test: model-test lint sim synth

model-test:
	cd model && $(PY) -m pytest -q

lint:
	verilator --lint-only -Wall --top-module edge_pipeline  $(RTL)
	verilator --lint-only -Wall --top-module edge_accel_top $(RTL)
	verilator --lint-only -Wall --top-module hs_frontend    $(HS)
	verilator --lint-only -Wall -Wno-DECLFILENAME --top-module basys3_top lint/waivers.vlt \
		$(RTL) rtl/board/basys3_top.sv ip/clk_wiz_0/clk_wiz_0_stub.v

sim:
	$(PY) scripts/regress.py --sim icarus

sim-verilator:
	$(PY) scripts/regress.py --sim verilator

synth:
	scripts/yosys/synth_check.sh

clean:
	rm -rf build
