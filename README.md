# Image Processing Accelerator for Edge Detection

A streaming Sobel edge-detection accelerator in SystemVerilog. It is the
foundation of a larger project: an onboard hyperspectral payload processor
(calibration plus CCSDS 123.0-B-2 compression) for Zynq UltraScale+ (ZCU106),
with a datapath that also synthesises for the rad-tolerant AMD XQRKU060.

Progress so far:
- **Phase 1:** the original Basys 3 design, cleaned up into a parameterised,
  AXI4-Stream, fully verified core.
- **Phase 2:** a hyperspectral pushbroom front end (`rtl/hs/`).
- **Phase 3:** a CCSDS 123.0-B-2 lossless compressor (`rtl/ccsds123/`),
  byte-exact against an independent reference implementation.
- **Phase 4:** radiation-tolerance features (`rtl/rel/`): SECDED-protected
  memories, triplicated control registers and fault-injection tests.

## Pipeline

```
 clk_src (100 MHz)                 clk_proc (200 MHz)
 image_rom_source ─▶ axis_async_fifo ─▶ edge_pipeline ──────────────────────────▶ axis_serializer ─▶ pins
                     (gray-code CDC)    │ reg ─▶ sobel_core ─▶ reg ─▶ avg_pool2x2 ─▶ reg │
```

| Block | What it does |
|---|---|
| `rtl/edge/image_rom_source.sv` | Plays a `$readmemh` image out as AXI-Stream, `NUM_FRAMES` times or forever |
| `rtl/common/axis_async_fifo.sv` | Dual-clock FIFO with gray-coded pointers (replaces the FIFO Generator IP) |
| `rtl/edge/sobel_core.sv` | 3x3 Sobel, `|Gx| + |Gy|` saturated to `2^DW - 1`; outputs `(W-2) x (H-2)` |
| `rtl/edge/avg_pool2x2.sv` | 2x2 average pooling, `floor(sum / 4)` |
| `rtl/edge/edge_pipeline.sv` | Sobel + pooling with a register slice at every boundary (the reusable core) |
| `rtl/edge/axis_serializer.sv` | Pixels to a 1-bit stream, MSB first, with a last-bit marker |
| `rtl/common/sdp_ram.sv` | Generic RAM; `RAM_STYLE` = `block`, `distributed`, `ultra` or `auto` |
| `rtl/common/axis_register.sv` | Skid buffer that registers `tready` |
| `rtl/top/edge_accel_top.sv` | Vendor-neutral top (no clocking IP) |
| `rtl/board/basys3_top.sv` | Basys 3 wrapper: `clk_wiz_0` plus pins |

**Interfaces.** Every block uses AXI4-Stream: `tdata`, `tvalid`, `tready`,
`tuser` = start of frame and `tlast` = end of line. `tuser` re-aligns the
internal row/column counters, and `framing_err` pulses when an input `tlast`
does not match the configured line length.

**Parameters.** `DW` (bits per pixel, tested at 8, 10, 12 and 16), `IMG_W` and
`IMG_H` (tested from 2x2 up to 128-wide frames). `edge_pipeline` needs even
`IMG_W` and `IMG_H`, and its output is `(IMG_W-2)/2 x (IMG_H-2)/2`.

**Border policy.** Sobel only produces a result where the full 3x3 window
lies inside the image (the "valid" convolution mode). There is no row wrap
and no garbage from uninitialised line buffers.

**Backpressure.** Each processing block stalls as a whole when its output is
not accepted, and register slices between blocks keep `tready` off the
critical path. No pixel is ever dropped, from the ROM to the serial pins.

## Hyperspectral front end (`rtl/hs/`)

The stream is band-interleaved-by-pixel (BIP), like a pushbroom detector
readout: band 0..NB-1 of pixel 0, then pixel 1, and so on. Each line holds
`NX * NB` samples. `tuser` marks the first sample of a frame and `tlast` the
last sample of a line.

```
s_axis ─▶ line_pacer ─▶ radiometric_corr ─▶ badpix_replace ─▶ band_select ─▶ m_axis
           line timing   (x - dark) * gain    nearest-left good   keep masked bands
                    (register slice between every block, AXI4-Lite register map)
```

| Block | What it does |
|---|---|
| `line_pacer` | Starts at most one line every `LINE_PERIOD` cycles, which emulates the detector's line rate when replaying from DDR. Counts overruns when backpressure makes a line miss its slot |
| `radiometric_corr` | `clamp(((x - dark[p,b]) * gain[p,b] + 2^(GF-1)) >> GF)`, with per pixel/band tables and one DSP48 |
| `badpix_replace` | Replaces a flagged sample with the last good sample to its left in the same band (0 if there is none) |
| `band_select` | Keeps the bands set in `BAND_MASK`, the way Pixxel Firefly keeps ~45 of its ~135 bands. The mask switches only at frame start |
| `hs_frontend` | Chains the four blocks, with an AXI4-Lite slave (`axil_cfg_bridge`), table loading and telemetry counters |

The register map is documented at the top of `rtl/hs/hs_frontend.sv`. It
covers ID, geometry, line period, band mask, the dark/gain/bad-pixel tables,
and counters for overruns, framing errors, lines out and replaced samples.

`model/hs_golden.py` is the bit-exact reference. It also generates a
synthetic scene with water, vegetation (red edge), soil and cloud spectra,
plus dark offsets, gain spread, dead columns and saturating samples.
`tb/tb_hs_frontend.sv` programs the design over AXI4-Lite, streams the cube
with random stalls, checks every sample, then reads the counters back.

## CCSDS 123.0-B-2 lossless compressor (`rtl/ccsds123/`)

CCSDS 123.0-B-2 is the space agencies' standard for compressing
multispectral and hyperspectral images onboard. It predicts each sample from
its spatial neighbours and the previous bands with weights that adapt as the
image streams through, then entropy-codes the prediction residuals.

```
s_axis ─▶ predictor ─▶ slice ─▶ entropy coder ─▶ header insert ─▶ packer ─▶ m_axis
 D-bit    9 stages,             Sigma/Gamma,      19-byte CCSDS    64-bit words,
 BIP      1 sample/clk          k, codewords      header per image  tkeep, tlast
```

| Block | What it does |
|---|---|
| `ccsds123_predictor` | Local sums, local differences, weighted prediction, mod-R scaling, residual mapping and sign-algorithm weight update (sections 4.4 to 4.10 of the standard). Line buffer in block RAM, per-band weights and state in small RAMs |
| `ccsds123_coder` | Sample-adaptive entropy coder (5.4.3.2): per-band accumulator, shared counter with rescaling, code parameter k, unary/binary codewords and escape codes |
| `ccsds123_packer` | Packs codewords into a 64-bit AXI4-Stream byte stream (lane 0 first), pads each image to a whole byte, `tkeep` and `tlast` on the last word |
| `ccsds123_top` | Chains them and, with `EMIT_HEADER = 1`, starts each image with the standard header built from the parameters, so every image is a complete file any compliant decoder reads |

**Configuration.** Lossless, unsigned samples, D = 2..16 bits, full or
reduced prediction, P = 0..15 previous bands, wide neighbour- or
column-oriented local sums, all weight and coder parameters of the standard,
band-interleaved-by-pixel order (as a pushbroom sensor reads out), output
word size 1 byte. The parameters are fixed at build time and recorded in the
header.

**Throughput.** One sample per clock when the image has 9 or more bands. The
per-band weight update has `NZ` clocks to finish because the same band only
comes back one pixel later; with fewer bands the input stalls until it has.

**Reference model.** `model/ccsds123.py` is a compressor and decompressor
written from the standard. `make ntnu-check` clones the independent
[NTNU SmallSat Lab model](https://github.com/NTNU-SmallSat-Lab/ccsds123_issue_2_verification_model)
(verified by its authors against the official CCSDS test vectors) at a pinned
commit and compares the complete compressed files of both models on 11
configurations. All 11 are identical byte for byte. The chain is
RTL = `ccsds123.py` = NTNU model.

**Resources** (Yosys, default build: 64 x 64 pixels, 16 bands, D = 16, P = 3,
full prediction): about 6,500 LUTs, 3,100 flip-flops, 7 DSP48 and one
RAMB18 on UltraScale+, under 3% of the ZCU106's XCZU7EV.

## Reliability for space (`rtl/rel/`)

In orbit, heavy ions and protons flip bits (single-event upsets, SEUs) in
flip-flops, block RAM and the FPGA's configuration memory. The compressor
has a flight build (`ECC = 1`, `TMR = 1` on `ccsds123_top`) that protects
its own state:

| Block | What it does |
|---|---|
| `secded_enc` / `secded_dec` | Extended Hamming SECDED code for any data width: corrects any single-bit error, detects any double-bit error. 64 data bits give the classic (72,64) code |
| `ecc_sdp_ram` / `ecc_lb_ram_rf` | Drop-in replacements for the RAMs, with SECDED per slice (per weight, for the predictor weights), error flags and an error-injection input |
| `tmr_reg` | Triplicated register with a majority voter that re-converges every clock, so an upset never reaches the output; reports outvoted upsets |

In the flight build every state memory of the compressor (line buffer, band
state, weights, accumulators) is ECC-protected and the position counters and
the coder's counter are triplicated. These memories are rewritten every
pixel or line, so a corrected upset is also flushed out and they need no
background scrubber. `ccsds123_top` counts corrected and uncorrectable memory
errors and outvoted register upsets for telemetry.

The protection is cheap: on UltraScale (Yosys, default image size) the
flight build is about 7,300 LUTs, 3,300 flip-flops, 7 DSP48 and one RAMB36,
against 6,450 LUTs, 3,100 flip-flops and one RAMB18 without it.

Fault-injection tests (`tb/tb_ccsds123.sv`, `FAULT` parameter) inject upsets
into live state while images stream through:

| Test | Result |
|---|---|
| Single-bit memory upsets, flight build | Output byte-exact; every upset counted as corrected |
| Upsets in one copy of every TMR register | Output byte-exact; upsets counted as outvoted |
| The same memory upsets without ECC (control) | Output corrupted, which shows the injection hits state that matters |
| Double-bit memory upsets | Detected and counted as uncorrectable |

What this does not cover, and a flight design still needs:
- **Configuration memory scrubbing.** On AMD parts this is the Soft Error
  Mitigation (SEM) IP, or the XQRKU060's and Versal's built-in scrubbing. It
  is vendor IP configured in Vivado, so it is not in this repo.
- **Full TMR of the datapath.** Only the control state is triplicated here.
  Flight teams usually triplicate the whole netlist with a TMR tool, or rely
  on per-image error detection, as this design does through its error
  counters.
- **DDR ECC and single-event latch-up protection.** These are board and
  processing-system level.

## Fixes against the original design

| Original problem | Now |
|---|---|
| `top.xdc` pinned `final_pixel_out[7:0]`, which no longer existed | `constraints/basys3.xdc` matches `basys3_top` |
| Window, Sobel and FIFO read never stalled, so pixels were lost when the serializer was busy | End-to-end AXI-Stream backpressure, tested with random stalls |
| No border handling: the window was "valid" from the first pixel, with row-wrap artifacts | Valid-region output only, with `tuser`/`tlast` regenerated |
| BRAM read started at address 1 and wrapped to 0 | Source reads `0 .. W*H-1` in order |
| 64 x 64 x 8-bit hard-coded everywhere | `DW`, `IMG_W`, `IMG_H` parameters |
| Line buffers were shift registers (SRLs) | Line buffers are inferred RAM, selectable per target |
| Vendor FIFO Generator IP in the datapath | Portable `axis_async_fifo` |
| Testbenches had to be checked by eye in the waveform | Self-checking testbenches against a Python golden model, in CI |

## Verification (no board needed)

All verification is board-free and runs in CI on every push:

```
make test            # model tests + NTNU cross-check + Verilator lint + Icarus regression + Yosys synthesis
make sim-verilator   # the same regression compiled with Verilator
make synth           # Yosys synthesis only
```

Needs `iverilog` (12+), `verilator` (5.x), `yosys` (0.33+), `git`, Python 3 with
`numpy`, `pytest`, `bitarray` and `psutil` (the last two for the NTNU model).

- `model/edge_golden.py` is the bit-exact reference: what the RTL must
  produce. `model/test_edge_golden.py` checks it against a direct
  per-pixel convolution.
- `tb/tb_axis_stage.sv` tests `sobel_core`, `avg_pool2x2` and `edge_pipeline`.
  It drives random `tvalid` gaps and random `tready` stalls, compares every
  output beat (data, `tuser`, `tlast`) with the golden model, and checks the
  AXI-Stream rule that the output holds steady while stalled.
- `tb/tb_edge_accel_top.sv` runs the whole design across two unrelated
  clocks (including a source faster than the processing clock), de-serializes
  the output pins and checks every pixel.
- `tb/tb_hs_frontend.sv` covers the hyperspectral front end, including
  AXI4-Lite programming, line pacing and overrun detection.
- `tb/tb_ccsds123.sv` streams images through `ccsds123_top` with random
  stalls and checks every mapped residual leaving the predictor, every output
  byte against `model/ccsds123.py`, `tkeep`, `tlast` and stability under
  backpressure. The 13 cases cover D = 2, 8, 10, 12, 14 and 16, P = 0 to 15,
  full and reduced prediction, both local sums, Nx = 1, Nz = 1 and 3 (hazard
  stalls), R = 32 with mod-R wrap-around, weight clipping, escape codes,
  counter rescaling, several images back to back and header on or off.
  Deliberately injected bugs (13 different ones) all make the regression fail.
- `tb/tb_secded.sv` checks the SECDED code on every single-bit and
  double-bit error pattern for nine data widths from 1 to 64 bits. The
  fault-injection cases (`rel_seu_*`) are described under Reliability.
- `make ntnu-check` compares `model/ccsds123.py` with the NTNU reference model
  (needs `bitarray` and `psutil`).
- `scripts/regress.py` lists the cases: 8/10/12/16-bit, minimum sizes,
  odd sizes, full rate and heavy stalls. CI (`.github/workflows/ci.yml`) runs
  everything on every push.
- `scripts/yosys/synth_check.sh` synthesises `edge_accel_top`, `hs_frontend`,
  `ccsds123_top` and its flight build (ECC and TMR on) with Yosys
  for the 7-series, UltraScale and UltraScale+ cell libraries. It fails on
  latches, netlist check errors or any SRL (the flight build bans SRLs),
  and prints the cell counts. That proves the RTL is synthesisable and maps
  to block RAM as intended, but it is not Vivado timing closure.

## Building with Vivado

```
vivado -mode batch -source scripts/vivado/build_basys3.tcl            # Basys 3 bitstream + reports
vivado -mode batch -source scripts/vivado/synth_ooc.tcl -tclargs zcu106   # core on XCZU7EV, 250 MHz
vivado -mode batch -source scripts/vivado/synth_ooc.tcl -tclargs ku060    # core on XCKU060, 200 MHz
```

The `ku060` run uses the commercial XCKU060 as a stand-in for the XQRKU060
flight part (same Kintex UltraScale die). Reports go to `vivado_out/`.

`Basys3.xpr.zip` and `ip/async_fifo/` are the original Vivado 2018.2 project
and IP. They are kept for reference only; the scripts above replace them.

**Basys 3 pins:** BTNC = reset, SW0 = downstream ready, Pmod JA1/JA2/JA3 =
serial data/valid/last bit, LD0 = valid, LD14 = framing error, LD15 = source done.

## Status of hardware results

| Item | Status |
|---|---|
| RTL behaviour | Verified in simulation against the golden model (Icarus and Verilator) |
| Synthesisability | Checked with Yosys for 7-series, UltraScale and UltraScale+ |
| CCSDS 123 conformance | Byte-exact with the NTNU reference model on 11 configurations; not run against the official CCSDS test vectors themselves |
| Vivado timing, utilisation, CDC | **Not run.** The `Report/` PNGs are from the original design |
| `constraints/basys3.xdc`, `rtl/board/basys3_top.sv`, `scripts/vivado/*.tcl` | **Unverified scaffolding**, never run through Vivado or on a board |

Yosys cell counts for the whole demo (64x64, 8-bit) are about 340 LUTs,
430 flip-flops, one RAMB36 (image ROM), one RAMB18 (Sobel line buffers) and
a few LUTRAMs (FIFO and pooling buffers).

## Roadmap

1. **Done:** production-grade streaming core, golden model, CI.
2. **Done:** hyperspectral front end: line pacing, dark/gain correction, bad pixels, band selection.
3. **Done:** CCSDS 123.0-B-2 lossless compressor, byte-exact against an independent reference.
4. PS/PL integration: CCSDS Space Packets over Ethernet to a PC ground station.
5. Strip-parallel compressors at Pixxel-like line rates.
6. **Done (in the RTL):** a space-grade build with TMR, memory ECC and fault-injection tests. Still to do: SEM scrubbing and XQRKU060 reports in Vivado.
