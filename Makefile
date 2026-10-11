# Open-source, board-free flow: golden model tests, Verilator lint,
# Icarus/Verilator regression, Yosys synthesis check.
# Vivado builds live in scripts/vivado/ (see README).

PY  ?= python3
RTL := rtl/common/*.sv rtl/edge/*.sv rtl/top/*.sv
HS  := rtl/common/*.sv rtl/hs/*.sv
CC  := rtl/common/*.sv rtl/ccsds123/*.sv

# independent CCSDS 123.0-B-2 reference (NTNU SmallSat Lab, MIT licence)
NTNU_URL    := https://github.com/NTNU-SmallSat-Lab/ccsds123_issue_2_verification_model.git
NTNU_COMMIT := 9fabb0371ebf93d72a0f83ca053e9cdb2c63e3c6
NTNU_DIR    := build/ntnu

.PHONY: all test model-test ntnu-check lint sim sim-verilator synth clean

all: test

test: model-test ntnu-check lint sim synth

model-test:
	cd model && $(PY) -m pytest -q

# compressed files from model/ccsds123.py must equal the NTNU model's, byte for byte
ntnu-check: $(NTNU_DIR)/.ok
	$(PY) scripts/check_ccsds123_ntnu.py --ntnu $(NTNU_DIR)

$(NTNU_DIR)/.ok:
	rm -rf $(NTNU_DIR)
	git clone -q $(NTNU_URL) $(NTNU_DIR)
	git -C $(NTNU_DIR) checkout -q $(NTNU_COMMIT)
	touch $@

lint:
	verilator --lint-only -Wall --top-module edge_pipeline  $(RTL)
	verilator --lint-only -Wall --top-module edge_accel_top $(RTL)
	verilator --lint-only -Wall --top-module hs_frontend    $(HS)
	verilator --lint-only -Wall --top-module ccsds123_top   $(CC)
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
