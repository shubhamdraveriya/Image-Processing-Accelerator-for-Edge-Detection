# Image Processing Accelerator for Edge Detection

A streaming Sobel edge-detection accelerator in SystemVerilog. It is the
foundation of a larger project: an onboard hyperspectral payload processor
(calibration plus CCSDS 123.0-B-2 compression) for Zynq UltraScale+ (ZCU106),
with a datapath that also synthesises for the rad-tolerant AMD XQRKU060.

This repository is at **phase 1**: the original Basys 3 design, cleaned up
into a parameterised, AXI4-Stream, fully verified core.

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

## Verification

```
make test            # golden model tests + Verilator lint + Icarus regression
make sim-verilator   # the same regression compiled with Verilator
```

Needs `iverilog` (12+), `verilator` (5.x), Python 3 with `numpy` and `pytest`.

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
- `scripts/regress.py` lists the 15 cases: 8/10/12/16-bit, minimum sizes,
  odd sizes, full rate and heavy stalls. CI (`.github/workflows/ci.yml`) runs
  everything on every push.

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

The timing, CDC and power PNGs in `Report/` are from the original design. The
phase 1 RTL has been simulated and linted but **not yet run through Vivado**,
so it has no new utilisation or timing numbers yet.

## Roadmap

1. **Phase 1 (this):** production-grade streaming core, golden model, CI.
2. Hyperspectral front end on ZCU106: DDR line replay, dark/gain correction, bad pixels, band selection.
3. CCSDS 123.0-B-2 lossless compressor, bit-exact against software.
4. PS/PL integration: CCSDS Space Packets over Ethernet to a PC ground station.
5. Strip-parallel compressors at Pixxel-like line rates.
6. Space-grade build: TMR, BRAM ECC, SEM scrubbing with fault injection, XQRKU060 reports.
