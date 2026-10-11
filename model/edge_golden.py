#!/usr/bin/env python3
"""Bit-exact golden model for the edge accelerator RTL.

The functions here define what the hardware must produce. Every testbench
compares the RTL output against these, beat for beat.

  sobel_valid(img, dw) : |Gx| + |Gy| on every pixel whose 3x3 window lies
                         fully inside the image -> (H-2) x (W-2), saturated
                         to 2**dw - 1.
  avg_pool2x2(img)     : floor((a + b + c + d) / 4), stride 2.
  edge_pipeline(img)   : avg_pool2x2(sobel_valid(img)).

Command line (used by the Makefile):

  edge_golden.py vectors --mode {sobel,pool,pipeline} --dw 8 --w 64 --h 64 \
                         --frames 2 --seed 1 --out build/vec/case
      writes <out>_in.hex and <out>_exp.hex (one hex word per line, raster
      order, frames back to back)

  edge_golden.py expect --mode pipeline --dw 8 --w 64 --h 64 --frames 2 \
                        --mem data/image_stripes_64x64.mem --out build/top
      expected output for an image stored as a $readmemh file
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np


def sobel_valid(img: np.ndarray, dw: int) -> np.ndarray:
    a = img.astype(np.int64)
    h, w = a.shape
    if h < 3 or w < 3:
        raise ValueError("image must be at least 3x3")
    # p[r][c] = window element (row r, col c) for every output position
    p = [[a[r:h - 2 + r, c:w - 2 + c] for c in range(3)] for r in range(3)]
    gx = (p[0][2] + 2 * p[1][2] + p[2][2]) - (p[0][0] + 2 * p[1][0] + p[2][0])
    gy = (p[0][0] + 2 * p[0][1] + p[0][2]) - (p[2][0] + 2 * p[2][1] + p[2][2])
    mag = np.abs(gx) + np.abs(gy)
    return np.minimum(mag, (1 << dw) - 1)


def avg_pool2x2(img: np.ndarray) -> np.ndarray:
    a = img.astype(np.int64)
    h, w = a.shape
    if h % 2 or w % 2:
        raise ValueError("avg_pool2x2 needs even dimensions")
    s = a[0::2, 0::2] + a[0::2, 1::2] + a[1::2, 0::2] + a[1::2, 1::2]
    return s >> 2


def edge_pipeline(img: np.ndarray, dw: int) -> np.ndarray:
    return avg_pool2x2(sobel_valid(img, dw))


MODES = {
    "sobel": lambda img, dw: sobel_valid(img, dw),
    "pool": lambda img, dw: avg_pool2x2(img),
    "pipeline": edge_pipeline,
}


def test_frames(rng: np.random.Generator, n: int, h: int, w: int, dw: int) -> list[np.ndarray]:
    """A mix of random, saturating and structured frames."""
    maxv = (1 << dw) - 1
    yy, xx = np.mgrid[0:h, 0:w]
    patterns = [
        lambda: rng.integers(0, maxv + 1, size=(h, w)),
        lambda: np.where(((xx // 4) + (yy // 4)) % 2 == 0, maxv, 0),   # checkerboard, saturates
        lambda: (xx * maxv // max(w - 1, 1)),                           # horizontal ramp
        lambda: np.where(xx >= w // 2, maxv, 0),                        # vertical edge
        lambda: np.where(yy >= h // 2, maxv, 0),                        # horizontal edge
    ]
    return [patterns[i % len(patterns)]().astype(np.int64) for i in range(n)]


def write_hex(path: Path, frames: list[np.ndarray], dw: int) -> None:
    digits = (dw + 3) // 4
    with path.open("w") as f:
        for fr in frames:
            for v in fr.reshape(-1):
                f.write(f"{int(v):0{digits}x}\n")


def read_mem(path: Path, h: int, w: int) -> np.ndarray:
    vals = []
    for line in path.read_text().split("\n"):
        line = line.split("//")[0].strip()
        if not line or line.startswith("@"):
            continue
        vals.extend(int(tok, 16) for tok in line.split())
    if len(vals) < h * w:
        raise ValueError(f"{path}: {len(vals)} words, need {h * w}")
    return np.array(vals[: h * w], dtype=np.int64).reshape(h, w)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("vectors", "expect"):
        sp = sub.add_parser(name)
        sp.add_argument("--mode", choices=MODES, required=True)
        sp.add_argument("--dw", type=int, default=8)
        sp.add_argument("--w", type=int, required=True)
        sp.add_argument("--h", type=int, required=True)
        sp.add_argument("--frames", type=int, default=2)
        sp.add_argument("--out", type=Path, required=True)
        if name == "vectors":
            sp.add_argument("--seed", type=int, default=1)
        else:
            sp.add_argument("--mem", type=Path, required=True)
    args = ap.parse_args(argv)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    if args.cmd == "vectors":
        rng = np.random.default_rng(args.seed)
        frames = test_frames(rng, args.frames, args.h, args.w, args.dw)
        write_hex(Path(f"{args.out}_in.hex"), frames, args.dw)
    else:
        frames = [read_mem(args.mem, args.h, args.w)] * args.frames
    exp = [MODES[args.mode](fr, args.dw) for fr in frames]
    write_hex(Path(f"{args.out}_exp.hex"), exp, args.dw)
    oh, ow = exp[0].shape
    print(f"{args.cmd}: mode={args.mode} {args.w}x{args.h}x{args.dw}b -> {ow}x{oh}, "
          f"{args.frames} frame(s) -> {args.out}_*.hex")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
