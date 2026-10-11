#!/usr/bin/env python3
"""End-to-end golden model of rtl/payload/payload_top.sv.

Chains the block models exactly as the hardware does:

  raw sensor frame (NY, NX, NB)
    -> hs_golden.frontend    dark/gain correction, bad pixels, band selection
    -> ccsds123.compress     one standard CCSDS 123.0-B-2 file per frame
    -> analytics_golden      NDVI, cloud mask, edges, frame summary

  payload_golden.py vectors --d 12 --nx 24 --ny 12 --nb 24 --nz 12 \
                            --frames 2 --seed 1 --out build/vec/case
      writes <out>_in.hex (raw BIP samples), _cfg.txt (AXI4-Lite writes:
      "byte-address data"), _comp.hex + _comp_meta.txt (compressed bytes,
      bytes per frame), _prod.hex, _edge.hex, _sum.txt and _regs.txt
      (expected payload register values after the run)
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analytics_golden as an  # noqa: E402
import ccsds123 as cc  # noqa: E402
import hs_golden as hs  # noqa: E402

PL_BASE = 0x1000_0000


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["vectors"])
    ap.add_argument("--d", type=int, default=12)
    ap.add_argument("--nx", type=int, default=24)
    ap.add_argument("--ny", type=int, default=12)
    ap.add_argument("--nb", type=int, default=24, help="sensor bands")
    ap.add_argument("--nz", type=int, default=12, help="bands kept")
    ap.add_argument("--p", type=int, default=3)
    ap.add_argument("--gf", type=int, default=14)
    ap.add_argument("--frames", type=int, default=2)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args(argv)
    rng = np.random.default_rng(a.seed)
    maxv = (1 << a.d) - 1

    # calibration tables and band selection
    dark = rng.integers(0, maxv // 32, size=(a.nx, a.nb))
    gain = rng.integers(int(0.9 * (1 << a.gf)), int(1.1 * (1 << a.gf)), size=(a.nx, a.nb))
    bad = rng.random((a.nx, a.nb)) < 0.02
    keep = np.unique(np.round(np.linspace(0, a.nb - 1, a.nz)).astype(int))
    assert len(keep) == a.nz, "nz must be <= nb"
    mask = np.zeros(a.nb, dtype=bool)
    mask[keep] = True

    # analytics bands: nearest kept band to blue / red / NIR
    raw_bands = an.default_bands(a.nb)
    sel = {k: int(np.argmin(np.abs(keep - v))) for k, v in raw_bands.items()}
    cfg = dict(sel, bright=int(0.6 * maxv), white=24, veg=170, edge=40, cloud_max=32)

    pr = cc.Params(nx=a.nx, ny=a.ny, nz=a.nz, d=a.d, p=min(a.p, a.nz - 1) if a.nz > 1 else 0)
    pr.check()

    raws, comps, res = [], [], []
    for f in range(a.frames):
        sc = an.scene(rng, a.ny, a.nx, a.nb, a.d, cloud_cover=[1.0, 0.0][f % 2])
        raw = np.clip(sc + dark[None, :, :], 0, maxv)
        fe = hs.frontend(raw, dark, gain, bad, mask, a.d, a.gf)
        raws.append(raw)
        comps.append(cc.compress(fe, pr))
        res.append(an.analyse(fe, cfg))

    a.out.parent.mkdir(parents=True, exist_ok=True)
    dig = (a.d + 3) // 4
    with Path(f"{a.out}_in.hex").open("w") as fo:
        for r in raws:
            fo.writelines(f"{int(v):0{dig}x}\n" for v in r.reshape(-1))
    with Path(f"{a.out}_comp.hex").open("w") as fo:
        for c in comps:
            fo.writelines(f"{b:02x}\n" for b in c)
    Path(f"{a.out}_comp_meta.txt").write_text(" ".join(str(len(c)) for c in comps) + "\n")
    with Path(f"{a.out}_prod.hex").open("w") as fp, Path(f"{a.out}_edge.hex").open("w") as fe_:
        for r in res:
            fp.writelines(f"{int(v):04x}\n" for v in r["prod"].reshape(-1))
            fe_.writelines(f"{int(v):02x}\n" for v in r["edge"].reshape(-1))
    Path(f"{a.out}_sum.txt").write_text("".join(f"{r['cloud']} {r['veg']} {r['edges']} {r['keep']}\n" for r in res))

    with Path(f"{a.out}_cfg.txt").open("w") as f:
        for w in range((a.nb + 31) // 32):
            word = sum(1 << (i - 32 * w) for i in range(32 * w, min(32 * w + 32, a.nb)) if mask[i])
            f.write(f"{hs.REG_BAND_MASK + 4 * w:08x} {word:08x}\n")
        for i in range(a.nx * a.nb):
            p, b = divmod(i, a.nb)
            f.write(f"{hs.REGION_DARK + 4 * i:08x} {int(dark[p, b]):08x}\n")
            f.write(f"{hs.REGION_GAIN + 4 * i:08x} {int(gain[p, b]):08x}\n")
            f.write(f"{hs.REGION_BADPIX + 4 * i:08x} {int(bad[p, b]):08x}\n")
        f.write(f"{PL_BASE + 0x10:08x} {(cfg['blue'] << 16) | (cfg['nir'] << 8) | cfg['red']:08x}\n")
        f.write(f"{PL_BASE + 0x14:08x} {cfg['bright']:08x}\n")
        f.write(f"{PL_BASE + 0x18:08x} {(cfg['edge'] << 16) | (cfg['veg'] << 8) | cfg['white']:08x}\n")
        f.write(f"{PL_BASE + 0x1C:08x} {cfg['cloud_max']:08x}\n")

    last = res[-1]
    regs = {
        0x20: last["cloud"], 0x24: last["veg"], 0x28: last["edges"], 0x2C: last["keep"],
        0x30: a.frames, 0x34: sum(r["keep"] for r in res), 0x38: a.frames,
        0x3C: sum(len(c) for c in comps), 0x40: 0, 0x44: 0, 0x48: 0, 0x4C: 0,
    }
    Path(f"{a.out}_regs.txt").write_text("".join(f"{PL_BASE + k:08x} {v:08x}\n" for k, v in regs.items()))

    raw_bytes = a.nx * a.ny * a.nz * a.d / 8
    for i, (c, r) in enumerate(zip(comps, res)):
        print(f"frame {i}: {len(c)} bytes compressed ({raw_bytes / len(c):.2f}:1), cloud {r['cloud']}, "
              f"vegetation {r['veg']}, edges {r['edges']}, keep {r['keep']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
