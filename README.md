# Onboard Hyperspectral Payload Processor

An FPGA processing chain for a hyperspectral imaging satellite, written in
vendor-neutral SystemVerilog. It started as a Sobel edge-detection
accelerator on a Basys 3 board and is now the kind of datapath a
Pixxel-class pushbroom payload runs between the detector and the downlink:

- **Calibration** of the raw detector stream: dark and gain correction, bad
  pixel replacement and band selection.
- **CCSDS 123.0-B-2 lossless compression**, the space agencies' standard for
  hyperspectral data. It is byte-exact against an independent reference model.
- **Onboard analytics**: NDVI, a cloud mask, vegetation and edge maps, and a
  per-frame keep/drop decision, so cloudy frames need not take downlink time.
- **Radiation tolerance**: SECDED-protected memories, triplicated control
  registers and fault-injection tests that prove both work.

Primary target: **AMD Zynq UltraScale+ ZCU106** (XCZU7EV). The datapath uses
no vendor IP or primitives, so the same RTL also synthesises for the
rad-tolerant **XQRKU060** (Kintex UltraScale) and for Versal-class parts.
Everything is verified in simulation and synthesised with Yosys in CI, with no
board needed. [What that does and does not prove](#what-is-not-verified-yet)
is listed at the end.

## At a glance

| | |
|---|---|
| Interfaces | AXI4-Stream data, one AXI4-Lite register slave, an interrupt per frame |
| Throughput | 1 sample per clock through calibration, compression and analytics (with 9 or more bands kept, 10 in the flight build) |
| Compression | CCSDS 123.0-B-2 lossless, D = 2..16 bits, P = 0..15, full or reduced prediction; every image is a complete standard file with its header |
| Analytics | 8-bit NDVI, cloud and vegetation masks, Sobel edges of the NDVI image, per-frame counts and keep flag |
| Flight build | `ECC = 1`, `TMR = 1`: every compressor state memory under SECDED, control counters triplicated, upset counters in telemetry |
| Size (Yosys, UltraScale+) | Whole payload about 7,200 LUTs, 4,800 FFs, 8 DSP48, 5 RAMB18; flight build about 7,800 LUTs, 5,000 FFs |
| Verification | 67 simulation cases on Icarus and Verilator, 54 model tests, byte-exact cross-check against the NTNU CCSDS 123 model, 27 deliberately injected bugs all caught |

## Architecture

```
                        ┌──────────────────────────── payload_top ─────────────────────────────┐
 detector  BIP samples  │ hs_frontend_core                              ┌▶ ccsds123_top ───────┼─▶ m_comp  64-bit, one CCSDS
 readout ──────────────▶│ line pacing ─▶ dark/gain ─▶ bad pixels ─▶ band ┤   predictor, coder,  │          123 file per frame
 (NB bands, D bits)     │ (line rate)    correction    replacement   select│   header, packer     │
                        │                                               └▶ analytics_top ──────┼─▶ m_prod  {cloud, veg, NDVI}
                        │                                                   NDVI, cloud mask,  ├─▶ m_edge  NDVI edges
                        │                                                   Sobel, summary     ├─▶ irq_frame + summary regs
                        │ AXI4-Lite: tables, band mask, thresholds, telemetry counters          │
                        └──────────────────────────────────────────────────────────────────────┘
```

In a Zynq system the processing system (PS) loads the calibration tables
over AXI4-Lite, DMA moves detector lines in and compressed files out, and
flight software reads each frame's summary on `irq_frame` to decide whether
to downlink that frame. All blocks share one clock and use AXI4-Stream with
`tuser` = first sample of a frame and `tlast` = last sample of a line (last
byte of an image on `m_comp`). Every block handles backpressure and never
drops a sample.

The stream is band-interleaved-by-pixel (BIP): bands 0..NB-1 of pixel 0, then
pixel 1, and so on, the order a pushbroom detector reads out.

## Blocks

### Hyperspectral front end (`rtl/hs/`)

```
s_axis ─▶ line_pacer ─▶ radiometric_corr ─▶ badpix_replace ─▶ band_select ─▶ m_axis
           line timing   (x - dark) * gain    nearest-left good   keep masked bands
```

| Block | What it does |
|---|---|
| `line_pacer` | Starts at most one line every `LINE_PERIOD` cycles, which emulates the detector's line rate when replaying from DDR. Counts overruns when backpressure makes a line miss its slot |
| `radiometric_corr` | `clamp(((x - dark[p,b]) * gain[p,b] + 2^(GF-1)) >> GF)`, with per pixel/band tables and one DSP48 |
| `badpix_replace` | Replaces a flagged sample with the last good sample to its left in the same band (0 if there is none) |
| `band_select` | Keeps the bands set in `BAND_MASK`, the way a hyperspectral mission keeps the bands a product needs. The mask switches only at frame start |
| `hs_frontend_core` | Chains the four blocks with a register slice between each, plus table loading and telemetry counters |
| `hs_frontend` | `hs_frontend_core` with its own AXI4-Lite slave, for use on its own |

### CCSDS 123.0-B-2 compressor (`rtl/ccsds123/`)

CCSDS 123.0-B-2 predicts each sample from its spatial neighbours and the
previous bands, with weights that adapt as the image streams through, then
entropy-codes the prediction residuals.

```
s_axis ─▶ predictor ─▶ slice ─▶ entropy coder ─▶ header insert ─▶ slice ─▶ packer ─▶ m_axis
 D-bit    9 stages,             Sigma/Gamma,      19-byte CCSDS             64-bit words,
 BIP      1 sample/clk          k, codewords      header per image          tkeep, tlast
```

| Block | What it does |
|---|---|
| `ccsds123_predictor` | Local sums, local differences, weighted prediction, mod-R scaling, residual mapping and sign-algorithm weight update (sections 4.4 to 4.10 of the standard). Line buffer in block RAM, per-band weights and state in small RAMs |
| `ccsds123_coder` | Sample-adaptive entropy coder (5.4.3.2): per-band accumulator, shared counter with rescaling, code parameter k, unary/binary codewords and escape codes |
| `ccsds123_packer` | Packs codewords into a 64-bit byte stream (lane 0 first), pads each image to a whole byte, `tkeep` and `tlast` on the last word |
| `ccsds123_top` | Chains them and, with `EMIT_HEADER = 1`, starts each image with the standard header built from the parameters |

Lossless, unsigned samples, D = 2..16 bits, P = 0..15 previous bands, full or
reduced prediction, neighbour- or column-oriented local sums, all weight and
coder parameters of the standard, BIP order, 1-byte output words. The
parameters are fixed at build time and recorded in the header. One sample per
clock when 9 or more bands are kept (10 in the flight build, whose predictor
has one more stage to register the ECC-decoded memory reads): the per-band
weight update has `NZ` clocks to finish, and with fewer bands the input
stalls until it has.

### Onboard analytics (`rtl/analytics/`)

From the calibrated stream, per pixel:

```
ndvi8 = floor(256 * NIR / (NIR + RED)), saturated to 255; 128 if both are 0
cloud = BLUE >= bright  and  |ndvi8 - 128| <= white      (bright and spectrally flat)
veg   = not cloud and ndvi8 >= veg
```

`ndvi8` is NDVI = (NIR - RED) / (NIR + RED) mapped from [-1, 1] to [0, 255],
computed with one 9-stage pipelined divider (`ndvi_div`) and no sign
handling. The NDVI image also runs through the original Sobel core, so field
boundaries and coastlines show up as edges.

| Output | Content |
|---|---|
| `m_prod` | One 16-bit word per pixel: `{cloud, veg, 000000, ndvi8}` |
| `m_edge` | Sobel magnitude of the NDVI image, `(NX-2) x (NY-2)` |
| Summary, `sum_valid` | Cloud, vegetation and edge pixel counts, and `keep = cloud * 256 <= cloud_max * NX * NY` |

The band indices and thresholds can change between frames: each frame is
classified with the configuration that was present at its first sample, even
while the previous frame is still in the pipeline.

### Payload top (`rtl/payload/`)

`payload_top` forks the calibrated stream into the compressor and the
analytics (a sample leaves only when both take it) and puts everything behind
one AXI4-Lite slave. Byte addresses `0x0000_0000` to `0x0FFF_FFFF` are the
front end (map at the top of `rtl/hs/hs_frontend.sv`: ID, line period, band
mask, dark/gain/bad-pixel tables, counters). The payload registers start at
`0x1000_0000`:

| Offset | Register | Access | Content |
|---|---|---|---|
| 0x00 | ID | RO | `0x504C_0005` |
| 0x04 | GEOMETRY | RO | `{NZ[15:0], NX[15:0]}` |
| 0x08 | LINES | RO | NY |
| 0x0C | CTRL | WO | bit 0: clear the counters below |
| 0x10 | AN_BANDS | RW | `{blue[23:16], nir[15:8], red[7:0]}`, indices among the kept bands |
| 0x14 | AN_BRIGHT | RW | cloud brightness threshold on the blue band (D bits) |
| 0x18 | AN_THRESH | RW | `{edge[23:16], veg[15:8], white[7:0]}` |
| 0x1C | AN_CLOUD_MAX | RW | keep a frame if its cloud fraction is at most value / 256 (0..256) |
| 0x20 to 0x2C | LAST_CLOUD, LAST_VEG, LAST_EDGE, LAST_KEEP | RO | summary of the last frame |
| 0x30, 0x34 | FRAMES_ANALYSED, FRAMES_KEPT | RO | frame counters |
| 0x38, 0x3C | IMAGES_COMPRESSED, BYTES_COMPRESSED | RO | compressor output counters |
| 0x40, 0x44 | ECC_CORRECTED, ECC_UNCORRECTABLE | RO | memory upsets (flight build) |
| 0x48 | TMR_UPSETS | RO | outvoted register upsets (flight build) |
| 0x4C | FRAMING_ERRS | RO | malformed frames seen by the compressor or the analytics |

### Reliability for space (`rtl/rel/`)

In orbit, heavy ions and protons flip bits (single-event upsets, SEUs) in
flip-flops, block RAM and the FPGA's configuration memory. With `ECC = 1` and
`TMR = 1` (on `ccsds123_top` or `payload_top`) the compressor protects its
own state:

| Block | What it does |
|---|---|
| `secded_enc` / `secded_dec` | Extended Hamming SECDED code for any data width: corrects any single-bit error and detects any double-bit error. 64 data bits give the classic (72,64) code |
| `ecc_sdp_ram` / `ecc_lb_ram_rf` | Drop-in replacements for the RAMs, with SECDED per slice (per weight for the predictor weights), error flags and an error-injection input |
| `tmr_reg` | Triplicated register with a majority voter that re-converges every clock, so an upset never reaches the output; reports outvoted upsets |

Every state memory of the compressor (line buffer, band state, weights,
accumulators) is ECC-protected, and the position counters and the coder's
counter are triplicated. These memories are rewritten every pixel or line,
so a corrected upset is also flushed out and they need no background
scrubber. The upset counters go to telemetry. The flight synthesis also bans
SRL primitives, whose contents configuration scrubbing cannot correct.

### Edge-detection core (`rtl/edge/`, `rtl/top/`)

The original project, cleaned up into a parameterised AXI4-Stream core:
`sobel_core` (3x3 Sobel, `|Gx| + |Gy|` saturated, valid region only),
`avg_pool2x2`, `edge_pipeline`, a dual-clock `axis_async_fifo` that replaces
the vendor FIFO IP, and `edge_accel_top` / `basys3_top` for the board demo.
`sobel_core` is reused by the analytics.

## Verification

Everything runs without a board, in CI on every push:

```
make test            # model tests, NTNU cross-check, Verilator lint, Icarus regression, Yosys synthesis
make sim-verilator   # the same regression compiled with Verilator
make synth           # Yosys synthesis only
python3 scripts/regress.py -k payload     # run the cases whose name contains "payload"
```

Needs `iverilog` (12+), `verilator` (5.x), `yosys` (0.33+), `git`, and
Python 3 with `numpy`, `pytest`, `bitarray` and `psutil`.

**Golden models.** Every block has a bit-exact Python model in `model/`:
`edge_golden.py`, `hs_golden.py`, `ccsds123.py` (compressor and decompressor
written from the standard), `analytics_golden.py` and `payload_golden.py`,
which chains them exactly as the hardware does. 54 pytest tests check the
models themselves, for example the compressor round trip, NDVI against
floating-point NDVI, and the Sobel model against a direct convolution.

**Testbenches.** Every testbench is self-checking: it streams data with
random `tvalid` gaps and random `tready` stalls, compares every output beat
(data, `tuser`, `tlast`, `tkeep`) with the model, and checks that outputs hold
steady while stalled.

| Area | Cases | What they cover |
|---|---|---|
| Edge core | 15 | 8 to 16-bit pixels, 2x2 to 128-wide frames, odd sizes, the full design across two unrelated clocks |
| Front end | 7 | Calibration, bad pixels, band masks, AXI4-Lite programming, line pacing and overruns |
| CCSDS 123 | 13 | D = 2 to 16, P = 0 to 15, full and reduced prediction, both local sums, NX = 1, NZ = 1 and 3 (hazard stalls), mod-R wrap, weight clipping, escape codes, counter rescaling, images back to back |
| Reliability | 6 + 9 | Fault injection (below); SECDED on every single and double-bit error for 9 widths from 1 to 64 bits |
| Analytics | 12 | Synthetic scenes and random data, 3x3 frames back to back, a new band choice and thresholds every frame, keep decision exactly on its boundary |
| Payload | 5 | The whole chain programmed over AXI4-Lite, compressed bytes, products, edges and every register checked; flight build; heavy backpressure from the analytics outputs |

**Independent CCSDS reference.** `make ntnu-check` clones the
[NTNU SmallSat Lab model](https://github.com/NTNU-SmallSat-Lab/ccsds123_issue_2_verification_model)
at a pinned commit (its authors verified it against the official CCSDS test
vectors) and compares complete compressed files on 11 configurations. All 11
are identical byte for byte, so the chain is RTL = `ccsds123.py` = NTNU model.

**Fault injection** (`FAULT` parameter of `tb/tb_ccsds123.sv`), with images
streaming through:

| Test | Result |
|---|---|
| Single-bit upsets in every state memory, flight build | Output byte-exact; every upset counted as corrected |
| Upsets in one copy of every TMR register | Output byte-exact; upsets counted as outvoted |
| The same memory upsets without ECC (control) | Output corrupted, which shows the injection hits state that matters |
| Double-bit memory upsets | Detected and counted as uncorrectable |

**Bug injection.** To check that the tests would notice real mistakes, small
bugs were put into the RTL one at a time (off-by-one comparisons, a wrong
band selected at a frame boundary, a lost backpressure term, thresholds taken
from the wrong frame, and so on). All 13 in the compressor and all 14 in the
analytics and payload made the regression fail.

**Synthesis.** `scripts/yosys/synth_check.sh` synthesises every top for the
7-series, UltraScale and UltraScale+ cell libraries and fails on latches,
netlist check errors or any SRL. That shows the RTL is synthesisable and maps
to block RAM and DSPs as intended. It is not Vivado timing closure.

## Resources

Yosys `synth_xilinx`, UltraScale+ cells, default parameters of each top:

| Design | LUTs | Flip-flops | DSP48 | Block RAM |
|---|---|---|---|---|
| `edge_accel_top` (64x64, 8-bit, Basys 3 demo) | 308 | 426 | 0 | 1 RAMB36, 1 RAMB18 (+2 LUTRAM cells) |
| `hs_frontend` (64 pixels, 16 bands, 16-bit) | 675 | 826 | 1 | 3 RAMB18 (+2 LUTRAM cells) |
| `ccsds123_top` (64x64, 16 bands, D = 16, P = 3) | 6,450 | 3,079 | 7 | 1 RAMB18 (+12 LUTRAM cells) |
| `ccsds123_top`, flight build | 7,269 | 3,304 | 7 | 1 RAMB36 (+16 LUTRAM cells) |
| `analytics_top` (32x24, 16 bands) | 795 | 997 | 1 | 1 RAMB18 |
| `payload_top` (32x16, 32 bands in, 16 kept, D = 12) | 7,151 | 4,815 | 8 | 5 RAMB18 (+12 LUTRAM cells) |
| `payload_top`, flight build | 7,803 | 5,031 | 8 | 5 RAMB18 (+16 LUTRAM cells) |

The XCZU7EV on the ZCU106 has 230k LUTs, 461k flip-flops, 1,728 DSPs and
312 RAMB36, and the XQRKU060 has 331k LUTs, 2,760 DSPs and 1,080 RAMB36, so
the whole flight payload uses a few percent of either. That leaves room for
several compressors in parallel (by strips of the image) to reach the line
rates of a wide-swath sensor. Yosys counts are an estimate; Vivado usually
packs LUTs tighter.

### Vivado results

Vivado 2018.2, routed. `synth_ooc.tcl` runs out of context (no I/O placement,
so slack at the ports is optimistic; the internal paths are real);
`build_basys3.tcl` is the full board build with pins and the clock IP.

| Design | Part, clock | LUTs | FFs | DSP | Block RAM | WNS | WHS |
|---|---|---|---|---|---|---|---|
| `edge_pipeline` 64x64x8 | XCZU7EV-2, 250 MHz | 192 | 339 | 0 | 1 RAMB18 | +2.350 ns | +0.052 ns |
| `payload_top` | XCZU7EV-2, 250 MHz | 3,736 | 4,423 | 9 | 1 RAMB36 + 6 RAMB18 | +0.261 ns | +0.047 ns |
| `payload_top`, flight build | XCZU7EV-2, 250 MHz | 4,342 | 4,794 | 9 | 2 RAMB36 + 5 RAMB18 | +0.461 ns | +0.031 ns |
| `payload_top`, flight build | XCKU060-2, 200 MHz | 4,349 | 4,794 | 9 | 2 RAMB36 + 5 RAMB18 | +0.290 ns | +0.053 ns |
| `basys3_top` (bitstream) | XC7A35T-1, 100 + 200 MHz | 258 | 420 | 0 | 1.5 tiles | +0.893 ns | +0.036 ns |

All timing constraints are met. The Basys 3 build reports 0.20 W on chip and
a clean `report_cdc` (every crossing safe).

What the first Vivado runs found, and the fixes (all with the full regression
passing, fault injection included):

| Path | First run | Fix |
|---|---|---|
| Coder codeword logic, header mux and the packer's 128-bit shift in one cycle (13 levels) | Worst path of the payload (+0.158 ns at 250 MHz), failing in the flight build | Register slice `u_cw_slice` between header insertion and the packer: one cycle of latency, byte stream unchanged |
| Predictor line buffer / band state read, SECDED decode, local sums, DSP input (flight build) | -0.351 ns at 250 MHz on XCZU7EV, -1.052 ns at 200 MHz on XCKU060 (about 165 MHz) | With `ECC = 1` a predictor stage P0 registers the decoded reads; the weight read moves to P0 and the hazard check covers it, so full rate now needs 10 bands instead of 9 |
| Predictor weight read, SECDED decode, multiply (flight build) | Same | Same P0 stage |
| Coder accumulator read, SECDED decode, update and write back in one cycle (flight build) | -0.734 ns at 200 MHz on XCKU060 | A read stage R registers the decoded accumulator; the update forwards from the two samples ahead, so one band (`NZ = 1`) still runs at one sample per clock |
| SW0 (`ready_in`) drove 38 flip-flops in the 200 MHz domain directly (Basys 3) | `report_cdc`: critical, unknown CDC circuitry | Two-flip-flop synchroniser in `basys3_top` |

## Targets

| Part | Role | Status |
|---|---|---|
| ZCU106 (XCZU7EV, Zynq UltraScale+) | Primary development target: PS for control and DMA, PL for this datapath | Payload and flight build meet 250 MHz in Vivado (out of context) |
| XQRKU060 (Kintex UltraScale, rad-tolerant) | Flight part | Flight build meets 200 MHz in Vivado on the commercial XCKU060 (same die), out of context |
| Versal XQR | Next-generation flight part | Same vendor-neutral RTL; not synthesised yet |
| Basys 3 (Artix-7) | Original edge-detection demo | Bitstream builds in Vivado, timing met; not run on a board |

Vivado scripts (`scripts/vivado/`, all run with Vivado 2018.2, see [Vivado results](#vivado-results)):

```
vivado -mode batch -source scripts/vivado/synth_ooc.tcl -tclargs zcu106 payload   # payload on XCZU7EV, 250 MHz
vivado -mode batch -source scripts/vivado/synth_ooc.tcl -tclargs ku060 flight     # flight build on XCKU060, 200 MHz
vivado -mode batch -source scripts/vivado/build_basys3.tcl                        # Basys 3 edge demo bitstream
```

## What is not verified yet

Neither a board nor Vivado was available while building this, so these are
open:

| Item | Status |
|---|---|
| Timing closure | **Out of context only.** Payload and flight build meet 250 MHz on XCZU7EV and the flight build 200 MHz on XCKU060 (see [Vivado results](#vivado-results)), but not yet inside a full Zynq design with the PS, DMA and real I/O. The `Report/` PNGs are from the original Basys 3 design |
| Basys 3 board | Bitstream built with timing met and a clean CDC report; never loaded on a board |
| Official CCSDS test vectors | Not run directly. Conformance rests on the byte-exact match with the NTNU model, which its authors checked against them |
| Configuration memory scrubbing | Not in this repo: it is the SEM IP on UltraScale, or built-in scrubbing on XQRKU060 and Versal, configured in Vivado |
| Full datapath TMR, DDR ECC, latch-up protection | Only control state is triplicated here; the rest is a TMR tool's, the board's or the PS's job |
| Radiation testing | None. Fault injection in simulation shows the protection logic works; it says nothing about real upset rates |
| PS software, DMA and ground segment | Not written: no driver, no CCSDS Space Packet framing, no downlink |
| Real sensor data | Tested with synthetic scenes (water, crops, soil and cloud spectra with noise, dark offsets, gain spread and dead pixels), not with real imagery |

## Repository layout

```
rtl/common/     AXI4-Stream register, async FIFO, RAMs, AXI4-Lite bridge, reset sync
rtl/edge/       Sobel, pooling, serializer, image ROM (the original project)
rtl/hs/         hyperspectral front end
rtl/ccsds123/   CCSDS 123.0-B-2 compressor
rtl/rel/        SECDED, ECC memories, TMR
rtl/analytics/  NDVI divider and analytics
rtl/payload/    payload_top
rtl/top/, rtl/board/, constraints/   edge demo top and Basys 3 wrapper
model/          bit-exact Python models and their tests
tb/             self-checking testbenches
scripts/        regression runner, NTNU cross-check, Yosys and Vivado scripts
```

## Roadmap

1. **Done:** streaming edge core with golden model and CI.
2. **Done:** hyperspectral front end.
3. **Done:** CCSDS 123.0-B-2 lossless compressor, byte-exact against an independent reference.
4. **Done:** SECDED memories, TMR and fault-injection tests.
5. **Done:** onboard analytics and the integrated payload top.
6. **Done:** Vivado timing and utilisation on ZCU106 and XCKU060 (out of context), and the Basys 3 bitstream.
7. PS integration on the ZCU106: DMA, a Linux or bare-metal driver, CCSDS Space Packets over Ethernet to a PC ground station.
8. Strip-parallel compressors for wide-swath line rates, and near-lossless mode (CCSDS 123.0-B-2 quantisation).
9. SEM scrubbing and a full TMR flow for the flight part.

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

`Basys3.xpr.zip` and `ip/async_fifo/` are the original Vivado 2018.2 project
and IP, kept for reference only. Basys 3 pins: BTNC = reset, SW0 = downstream
ready, Pmod JA1/JA2/JA3 = serial data/valid/last bit, LD0 = valid,
LD14 = framing error, LD15 = source done.
