#!/usr/bin/env python3
"""Run the self-checking RTL regression with Icarus Verilog or Verilator.

Each case generates stimulus + expected output with model/edge_golden.py,
builds the testbench with the case parameters and checks for PASS.

  python3 scripts/regress.py                 # all cases, Icarus
  python3 scripts/regress.py --sim verilator # all cases, Verilator
  python3 scripts/regress.py -k pipeline     # only cases whose name matches
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build" / "regress"
GOLDEN = [sys.executable, str(ROOT / "model" / "edge_golden.py")]

RTL_CORE = sorted((ROOT / "rtl" / "common").glob("*.sv")) + sorted((ROOT / "rtl" / "edge").glob("*.sv"))
RTL_TOP = RTL_CORE + sorted((ROOT / "rtl" / "top").glob("*.sv"))
RTL_HS = sorted((ROOT / "rtl" / "common").glob("*.sv")) + sorted((ROOT / "rtl" / "hs").glob("*.sv"))
HS_GOLDEN = [sys.executable, str(ROOT / "model" / "hs_golden.py")]
RTL_CCSDS = (sorted((ROOT / "rtl" / "common").glob("*.sv")) + sorted((ROOT / "rtl" / "rel").glob("*.sv"))
             + sorted((ROOT / "rtl" / "ccsds123").glob("*.sv")))
CCSDS_MODEL = [sys.executable, str(ROOT / "model" / "ccsds123.py")]

MODE = {"sobel": 0, "pool": 1, "pipeline": 2}

# name, mode, DW, W, H, frames, valid %, ready %, seed
STAGE_CASES = [
    ("sobel_8b_64x64_full_rate",   "sobel",    8,  64, 64, 2, 100, 100, 1),
    ("sobel_8b_64x64_stress",      "sobel",    8,  64, 64, 2,  60,  40, 2),
    ("sobel_10b_37x21_odd_size",   "sobel",   10,  37, 21, 3,  80,  70, 3),
    ("sobel_12b_3x3_minimum",      "sobel",   12,   3,  3, 4,  90,  30, 4),
    ("pool_8b_62x62_full_rate",    "pool",     8,  62, 62, 2, 100, 100, 5),
    ("pool_10b_2x2_minimum",       "pool",    10,   2,  2, 4,  50,  50, 6),
    ("pool_12b_18x6_stress",       "pool",    12,  18,  6, 3,  70,  20, 7),
    ("pipeline_8b_64x64_full",     "pipeline", 8,  64, 64, 2, 100, 100, 8),
    ("pipeline_8b_64x64_stress",   "pipeline", 8,  64, 64, 3,  75,  35, 9),
    ("pipeline_10b_128x16_wide",   "pipeline",10, 128, 16, 2,  85,  60, 10),
    ("pipeline_16b_34x20",         "pipeline",16,  34, 20, 3,  70,  80, 11),
    ("pipeline_12b_6x4_tiny",      "pipeline",12,   6,  4, 5,  30,  90, 12),
]

# name, image source, frames, src half period, proc half period, ready %
TOP_CASES = [
    ("top_stripes_100_200MHz",  "stripes", 2, 5.0, 2.5,  70),
    ("top_random_100_200MHz",   "random",  2, 5.0, 2.5,  50),
    ("top_random_fast_src",     "random",  2, 2.0, 3.7, 100),
]

# name, DW, NX, NB, NY, frames, line period, expect overrun, valid %, ready %, seed
HS_CASES = [
    ("hs_12b_32x16_stress",        12,  32, 16, 6, 2,    0, 0,  80,  70, 1),
    ("hs_16b_24x40_two_mask_words",16,  24, 40, 4, 2,    0, 0,  90,  60, 2),
    ("hs_10b_2x1_minimum",         10,   2,  1, 5, 3,    0, 0,  50,  50, 3),
    ("hs_12b_40x1_single_band",    12,  40,  1, 4, 2,    0, 0,  95,  95, 7),
    ("hs_14b_64x8_full_rate",      14,  64,  8, 4, 2,    0, 0, 100, 100, 4),
    ("hs_12b_16x8_paced",          12,  16,  8, 6, 2,  200, 0, 100, 100, 5),
    ("hs_12b_16x8_overrun",        12,  16,  8, 6, 2,  130, 1, 100,  30, 6),
]

# CCSDS 123 compressor: name, model/RTL settings (defaults: 16x8x10, D=12,
# P=3, full, neighbour sums, Omega=13, R=64, v=-1..3, t_inc=2^6, U_max=18,
# gamma*=6, gamma0=1, K=3, scene image, header on, 1 frame), valid %, ready %
CCSDS_CASES = [
    ("c123_default_stress",          dict(), 80, 70),
    ("c123_full_rate_3_frames",      dict(frames=3, seed=2), 100, 100),
    ("c123_d16_p15_omega19",         dict(nx=24, ny=6, nz=20, d=16, p=15, omega=19, k=14, seed=3), 90, 80),
    ("c123_d8_reduced_column",       dict(nx=20, ny=10, nz=12, d=8, p=4, reduced=1, column=1, k=2, seed=4), 85, 60),
    ("c123_full_column",             dict(nx=18, ny=7, nz=11, p=2, column=1, seed=5), 75, 75),
    ("c123_nx1_reduced_column",      dict(nx=1, ny=40, nz=6, p=5, reduced=1, column=1, seed=6), 90, 90),
    ("c123_nz3_hazard_stalls",       dict(nx=12, ny=6, nz=3, p=2, seed=7), 100, 100),
    ("c123_nz1_p0",                  dict(nx=9, ny=9, nz=1, p=0, seed=8), 100, 90),
    ("c123_random_r32_wide_v",       dict(nx=16, ny=8, nz=10, d=10, omega=16, r=32, vmin=-6, vmax=9, tinc=4,
                                          image="random", seed=9), 80, 80),
    ("c123_extremes_escapes",        dict(nx=14, ny=6, nz=9, d=16, p=6, umax=8, gstar=4, k=0, image="extremes",
                                          seed=10), 70, 90),
    ("c123_d2_minimum",              dict(nx=10, ny=6, nz=5, d=2, p=1, umax=8, gstar=11, g0=8, k=0,
                                          image="random", seed=11), 90, 50),
    ("c123_body_only_2_frames",      dict(frames=2, header=0, gstar=11, g0=5, seed=12), 85, 85),
    ("c123_d14_64x16x32",            dict(nx=64, ny=16, nz=32, d=14, p=8, seed=13), 100, 100),
    # reliability (flight build: ecc=1 tmr=1); fault: 1 single-bit memory
    # upsets, 2 TMR register upsets, 3 single-bit upsets without ECC (control:
    # must corrupt), 4 double-bit upsets (must be detected); inj = per mille
    ("rel_flight_build_clean",       dict(nx=24, ny=8, nz=16, d=14, p=8, ecc=1, tmr=1, seed=14), 80, 70),
    ("rel_seu_memory_corrected",     dict(ecc=1, tmr=1, fault=1, inj=20, frames=2, seed=15), 90, 80),
    ("rel_seu_weights_p15_corrected",dict(nx=24, ny=6, nz=20, d=16, p=15, omega=19, k=14, ecc=1, tmr=1,
                                          fault=1, inj=30, seed=16), 90, 90),
    ("rel_seu_registers_outvoted",   dict(ecc=1, tmr=1, fault=2, inj=20, frames=2, seed=17), 90, 80),
    ("rel_seu_unprotected_corrupts", dict(fault=3, inj=5, seed=18), 90, 80),
    ("rel_seu_double_detected",      dict(ecc=1, fault=4, inj=5, seed=19), 90, 80),
]

# SECDED code: every 1- and 2-bit error pattern for these data widths
SECDED_WIDTHS = [1, 4, 8, 11, 16, 26, 32, 57, 64]
CCSDS_DEFAULT = dict(nx=16, ny=8, nz=10, d=12, p=3, reduced=0, column=0, omega=13, r=64, vmin=-1, vmax=3,
                     tinc=6, umax=18, gstar=6, g0=1, k=3, image="scene", frames=1, seed=1, header=1,
                     ecc=0, tmr=0, fault=0, inj=5)


def run(cmd: list[str], log: Path) -> tuple[bool, str]:
    with log.open("a") as f:
        f.write("$ " + " ".join(cmd) + "\n")
        p = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        f.write(p.stdout)
    return p.returncode == 0, p.stdout


def build_and_run(sim: str, top: str, sources: list[Path], params: dict, plusargs: list[str],
                  wd: Path, log: Path) -> tuple[bool, str]:
    srcs = [str(s) for s in sources]
    if sim == "icarus":
        vvp = wd / "sim.vvp"
        cmd = ["iverilog", "-g2012", "-o", str(vvp), "-s", top]
        cmd += [f"-P{top}.{k}={v}" for k, v in params.items()]
        ok, out = run(cmd + srcs, log)
        if not ok:
            return False, out
        return run(["vvp", "-n", str(vvp)] + plusargs, log)
    obj = wd / "obj"
    cmd = ["verilator", "--binary", "--timing", "-j", "0", "-Wno-fatal", "-Wno-lint", "-Wno-style",
           "--top-module", top, "-Mdir", str(obj)]
    cmd += [f"-G{k}={v}" for k, v in params.items()]
    ok, out = run(cmd + srcs, log)
    if not ok:
        return False, out
    return run([str(obj / f"V{top}")] + plusargs, log)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", choices=["icarus", "verilator"], default="icarus")
    ap.add_argument("-k", default="", help="only run cases whose name contains this")
    args = ap.parse_args()

    results = []
    for name, mode, dw, w, h, frames, vp, rp, seed in STAGE_CASES:
        if args.k not in name:
            continue
        wd = BUILD / args.sim / name
        wd.mkdir(parents=True, exist_ok=True)
        log = wd / "run.log"
        log.write_text("")
        vec = wd / "vec"
        t0 = time.time()
        ok, out = run(GOLDEN + ["vectors", "--mode", mode, "--dw", str(dw), "--w", str(w), "--h", str(h),
                                "--frames", str(frames), "--seed", str(seed), "--out", str(vec)], log)
        if ok:
            params = dict(MODE=MODE[mode], DW=dw, IMG_W=w, IMG_H=h, FRAMES=frames,
                          VALID_PCT=vp, READY_PCT=rp, SEED=seed)
            ok, out = build_and_run(args.sim, "tb_axis_stage", RTL_CORE + [ROOT / "tb" / "tb_axis_stage.sv"],
                                    params, [f"+IN={vec}_in.hex", f"+EXP={vec}_exp.hex"], wd, log)
        results.append((name, ok and "PASS:" in out, time.time() - t0, log))

    for name, image, frames, src_half, proc_half, rp in TOP_CASES:
        if args.k not in name:
            continue
        wd = BUILD / args.sim / name
        wd.mkdir(parents=True, exist_ok=True)
        log = wd / "run.log"
        log.write_text("")
        t0 = time.time()
        ok = True
        if image == "stripes":
            mem = ROOT / "data" / "image_stripes_64x64.mem"
        else:
            ok, _ = run(GOLDEN + ["vectors", "--mode", "pipeline", "--w", "64", "--h", "64", "--frames", "1",
                                  "--seed", "42", "--out", str(wd / "img")], log)
            mem = wd / "img_in.hex"
        out = ""
        if ok:
            ok, out = run(GOLDEN + ["expect", "--mode", "pipeline", "--w", "64", "--h", "64",
                                    "--frames", str(frames), "--mem", str(mem), "--out", str(wd / "top")], log)
        if ok:
            params = dict(FRAMES=frames, INIT_FILE=f'"{mem}"' if args.sim == "icarus" else f'"{mem}"',
                          SRC_HALF=src_half, PROC_HALF=proc_half, READY_PCT=rp)
            ok, out = build_and_run(args.sim, "tb_edge_accel_top", RTL_TOP + [ROOT / "tb" / "tb_edge_accel_top.sv"],
                                    params, [f"+EXP={wd / 'top'}_exp.hex"], wd, log)
        results.append((name, ok and "PASS:" in out, time.time() - t0, log))

    for name, dw, nx, nb, ny, frames, period, ovr, vp, rp, seed in HS_CASES:
        if args.k not in name:
            continue
        wd = BUILD / args.sim / name
        wd.mkdir(parents=True, exist_ok=True)
        log = wd / "run.log"
        log.write_text("")
        vec = wd / "vec"
        t0 = time.time()
        ok, out = run(HS_GOLDEN + ["vectors", "--dw", str(dw), "--nx", str(nx), "--nb", str(nb), "--ny", str(ny),
                                   "--frames", str(frames), "--seed", str(seed), "--period", str(period),
                                   "--out", str(vec)], log)
        if ok:
            meta = dict(l.split("=") for l in Path(f"{vec}_meta.txt").read_text().split())
            params = dict(DW=dw, NX=nx, NB=nb, NY=ny, FRAMES=frames, NSEL=meta["nsel"], NREPL=meta["nrepl"],
                          PERIOD=period, EXPECT_OVR=ovr, VALID_PCT=vp, READY_PCT=rp, SEED=seed)
            ok, out = build_and_run(args.sim, "tb_hs_frontend", RTL_HS + [ROOT / "tb" / "tb_hs_frontend.sv"],
                                    params, [f"+IN={vec}_in.hex", f"+EXP={vec}_exp.hex", f"+CFG={vec}_cfg.txt"],
                                    wd, log)
        results.append((name, ok and "PASS:" in out, time.time() - t0, log))

    for name, cfg, vp, rp in CCSDS_CASES:
        if args.k not in name:
            continue
        c = {**CCSDS_DEFAULT, **cfg}
        wd = BUILD / args.sim / name
        wd.mkdir(parents=True, exist_ok=True)
        log = wd / "run.log"
        log.write_text("")
        vec = wd / "vec"
        t0 = time.time()
        cmd = CCSDS_MODEL + ["vectors", "--out", str(vec)]
        for k in ("nx", "ny", "nz", "d", "p", "omega", "r", "vmin", "vmax", "tinc", "umax", "gstar", "g0", "k",
                  "image", "frames", "seed"):
            cmd += [f"--{k}", str(c[k])]
        cmd += [f"--{k}" for k in ("reduced", "column", "header") if c[k]]
        ok, out = run(cmd, log)
        if ok:
            params = dict(NX=c["nx"], NY=c["ny"], NZ=c["nz"], D=c["d"], P=c["p"], FULL=0 if c["reduced"] else 1,
                          LOCAL_SUM=2 if c["column"] else 0, OMEGA=c["omega"], R=c["r"], VMIN=c["vmin"],
                          VMAX=c["vmax"], TINC_LOG2=c["tinc"], UMAX=c["umax"], GSTAR=c["gstar"], GAMMA0=c["g0"],
                          KINIT=c["k"], EMIT_HEADER=c["header"], FRAMES=c["frames"], VALID_PCT=vp, READY_PCT=rp,
                          SEED=c["seed"], ECC=c["ecc"], TMR=c["tmr"], FAULT=c["fault"], INJ_PM=c["inj"])
            ok, out = build_and_run(args.sim, "tb_ccsds123", RTL_CCSDS + [ROOT / "tb" / "tb_ccsds123.sv"], params,
                                    [f"+IN={vec}_in.hex", f"+DELTA={vec}_delta.hex", f"+EXP={vec}_exp.hex",
                                     f"+META={vec}_meta.txt"], wd, log)
        results.append((name, ok and "PASS:" in out, time.time() - t0, log))

    for dw in SECDED_WIDTHS:
        name = f"rel_secded_{dw}b"
        if args.k not in name:
            continue
        wd = BUILD / args.sim / name
        wd.mkdir(parents=True, exist_ok=True)
        log = wd / "run.log"
        log.write_text("")
        t0 = time.time()
        ok, out = build_and_run(args.sim, "tb_secded",
                                [ROOT / "rtl" / "rel" / "secded_enc.sv", ROOT / "rtl" / "rel" / "secded_dec.sv",
                                 ROOT / "tb" / "tb_secded.sv"], dict(DW=dw, WORDS=20 if dw <= 32 else 4), [], wd, log)
        results.append((name, ok and "PASS:" in out, time.time() - t0, log))

    if not results:
        print("no cases matched")
        return 1
    width = max(len(r[0]) for r in results)
    for name, ok, dt, log in results:
        print(f"{name:<{width}}  {'PASS' if ok else 'FAIL'}  {dt:6.1f}s" + ("" if ok else f"  (see {log.relative_to(ROOT)})"))
    n_fail = sum(not r[1] for r in results)
    print(f"\n{len(results) - n_fail}/{len(results)} passed ({args.sim})")
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
