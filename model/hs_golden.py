#!/usr/bin/env python3
"""Bit-exact golden model for the hyperspectral front end (rtl/hs/).

Cubes are numpy arrays shaped (lines, pixels, bands) = (NY, NX, NB) and are
streamed in BIP order (band fastest, then pixel, then line).

  radiometric(x, dark, gain, dw, gf) : clamp(((x - dark) * gain + 2^(gf-1)) >> gf)
  badpix(x, bad)                     : bad samples take the last good sample to
                                       their left in the same band and line, or 0
  band_select(x, mask)               : keep bands where mask is True
  frontend(...)                      : the three in the RTL order

Command line (used by scripts/regress.py):

  hs_golden.py vectors --dw 12 --nx 32 --nb 16 --ny 6 --frames 2 --seed 1 \
                       --period 0 --out build/hs/case
    writes <out>_cfg.txt  (AXI-Lite writes: "<byte addr> <data>" in hex)
           <out>_in.hex   (input samples, BIP, frames back to back)
           <out>_exp.hex  (expected output samples)
           <out>_meta.txt (nsel, expected bad-pixel replacement count, ...)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

REG_LINE_PERIOD = 0x0C
REG_BAND_MASK = 0x100
REGION_DARK = 1 << 26
REGION_GAIN = 2 << 26
REGION_BADPIX = 3 << 26


def radiometric(x: np.ndarray, dark: np.ndarray, gain: np.ndarray, dw: int, gf: int) -> np.ndarray:
    v = ((x.astype(np.int64) - dark) * gain + (1 << (gf - 1))) >> gf
    return np.clip(v, 0, (1 << dw) - 1)


def badpix(x: np.ndarray, bad: np.ndarray) -> np.ndarray:
    out = x.copy()
    ny, nx, nb = x.shape
    for y in range(ny):
        for b in range(nb):
            last = None
            for p in range(nx):
                if bad[p, b]:
                    out[y, p, b] = 0 if last is None else last
                else:
                    last = x[y, p, b]
    return out


def band_select(x: np.ndarray, mask: np.ndarray) -> np.ndarray:
    return x[:, :, mask]


def frontend(x, dark, gain, bad, mask, dw, gf):
    return band_select(badpix(radiometric(x, dark, gain, dw, gf), bad), mask)


def synthetic_scene(rng, ny, nx, nb, dw):
    """Smooth spectra per pixel class, plus detector dark offset and noise."""
    maxv = (1 << dw) - 1
    wl = np.linspace(0.0, 1.0, nb)
    classes = np.stack([
        0.10 + 0.05 * wl,                                  # water
        0.05 + 0.50 / (1 + np.exp(-(wl - 0.45) * 30)),     # vegetation red edge
        0.25 + 0.20 * wl,                                  # soil
        0.80 + 0.10 * np.sin(6 * wl),                      # cloud / bright
    ])
    labels = rng.integers(0, len(classes), size=(ny, nx))
    radiance = classes[labels] * maxv * 0.8
    noise = rng.normal(0, maxv * 0.01, size=radiance.shape)
    return np.clip(radiance + noise, 0, maxv).astype(np.int64)


def make_case(args):
    rng = np.random.default_rng(args.seed)
    maxv = (1 << args.dw) - 1
    ny, nx, nb = args.ny, args.nx, args.nb
    dark = rng.integers(0, max(maxv // 16, 1), size=(nx, nb))
    gain = rng.integers(int(0.8 * (1 << args.gf)), int(1.3 * (1 << args.gf)), size=(nx, nb))
    gain[0, 0] = (1 << args.gw) - 1               # max gain: forces saturation
    bad = rng.random((nx, nb)) < 0.04
    bad[0, rng.integers(0, nb)] = True             # bad at pixel 0: no left neighbour
    if nx > 2:
        bad[1, :] = True                           # a fully dead pixel column
    if nx > 4:
        bad[nx // 2, :] = True                     # dead column right after (likely) good pixels
        bad[nx // 2 - 1, :] = False
    mask = rng.random(nb) < 0.6
    mask[rng.integers(0, nb)] = True
    frames = []
    for f in range(args.frames):
        sc = synthetic_scene(rng, ny, nx, nb, args.dw) + dark
        sc[0, 0, :] = 0                            # below dark: clamps to 0
        sc[-1, -1, :] = maxv                       # full scale
        frames.append(np.clip(sc, 0, maxv))
    outs = [frontend(fr, dark, gain, bad, mask, args.dw, args.gf) for fr in frames]
    return frames, outs, dark, gain, bad, mask


def write_hex(path: Path, arrays, dw: int):
    digits = (dw + 3) // 4
    with path.open("w") as f:
        for a in arrays:
            for v in a.reshape(-1):
                f.write(f"{int(v):0{digits}x}\n")


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("vectors")
    sp.add_argument("--dw", type=int, default=12)
    sp.add_argument("--gw", type=int, default=16)
    sp.add_argument("--gf", type=int, default=14)
    sp.add_argument("--nx", type=int, required=True)
    sp.add_argument("--nb", type=int, required=True)
    sp.add_argument("--ny", type=int, required=True)
    sp.add_argument("--frames", type=int, default=2)
    sp.add_argument("--seed", type=int, default=1)
    sp.add_argument("--period", type=int, default=0)
    sp.add_argument("--out", type=Path, required=True)
    args = ap.parse_args(argv)

    frames, outs, dark, gain, bad, mask = make_case(args)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_hex(Path(f"{args.out}_in.hex"), frames, args.dw)
    write_hex(Path(f"{args.out}_exp.hex"), outs, args.dw)
    with Path(f"{args.out}_cfg.txt").open("w") as f:
        f.write(f"{REG_LINE_PERIOD:08x} {args.period:08x}\n")
        for w in range((args.nb + 31) // 32):
            word = sum(1 << (i - 32 * w) for i in range(32 * w, min(32 * w + 32, args.nb)) if mask[i])
            f.write(f"{REG_BAND_MASK + 4 * w:08x} {word:08x}\n")
        for i in range(args.nx * args.nb):
            p, b = divmod(i, args.nb)
            f.write(f"{REGION_DARK + 4 * i:08x} {int(dark[p, b]):08x}\n")
            f.write(f"{REGION_GAIN + 4 * i:08x} {int(gain[p, b]):08x}\n")
            f.write(f"{REGION_BADPIX + 4 * i:08x} {int(bad[p, b]):08x}\n")
    nsel = int(mask.sum())
    nrepl = int(bad.sum()) * args.ny * args.frames
    Path(f"{args.out}_meta.txt").write_text(f"nsel={nsel}\nnrepl={nrepl}\n")
    print(f"hs vectors: {args.nx}x{args.nb} bands x {args.ny} lines x {args.frames} frames, "
          f"{args.dw}-bit, {nsel} bands kept, {nrepl} replacements -> {args.out}_*")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
