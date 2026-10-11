#!/usr/bin/env python3
"""Bit-exact golden model for the onboard analytics RTL (rtl/analytics/).

From a band-interleaved-by-pixel (BIP) hyperspectral frame the hardware
computes, per pixel:

  ndvi8 = floor(256 * NIR / (NIR + RED)), saturated to 255; 128 if both are 0.
          This is NDVI = (NIR - RED) / (NIR + RED) mapped from [-1, 1] to
          [0, 255] (ndvi8 = 128 * (NDVI + 1)), with one divider and no sign.
  cloud = BLUE >= bright  and  |ndvi8 - 128| <= white
          (clouds are bright and spectrally flat, so NDVI is near 0)
  veg   = not cloud and ndvi8 >= veg_t

and the product word {cloud, veg, 000000, ndvi8} (16 bits). The NDVI image
also runs through the Phase 1 Sobel core (valid region, |Gx| + |Gy|), so
field and coastline boundaries show up as edges.

Per frame it reports the number of cloud, vegetation and edge pixels
(edge magnitude >= edge_t) and a keep flag:

  keep = cloud * 256 <= cloud_max * NX * NY

which lets the payload drop or deprioritise cloudy frames before downlink.

  analytics_golden.py vectors --d 12 --nx 32 --ny 24 --nb 16 --frames 2 \
                              --seed 1 --out build/vec/case
      writes <out>_in.hex (BIP samples), _prod.hex, _edge.hex, _sum.txt
      (cloud veg edge keep per frame) and _cfg.txt (one configuration line
      per frame: red nir blue bright white veg edge cloud_max)

  --random       random samples, uniform on even frames and low contrast on
                 odd ones (implies --vary-cfg)
  --vary-cfg     a different random band choice and set of thresholds for
                 every frame (exercises the per-frame configuration hand-over
                 in the pipeline)
  --cloud-max auto
                 put the keep decision exactly on its boundary: even frames
                 get cloud_max * NX * NY == cloud * 256 (kept), odd frames
                 one step below (dropped); needs NX * NY == 256
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from edge_golden import sobel_valid  # noqa: E402


def ndvi8(nir: np.ndarray, red: np.ndarray) -> np.ndarray:
    n = nir.astype(np.int64)
    r = red.astype(np.int64)
    den = n + r
    q = np.where(den == 0, 128, (n << 8) // np.maximum(den, 1))
    return np.minimum(q, 255)


def analyse(frame: np.ndarray, cfg: dict) -> dict:
    """frame: (NY, NX, NB) samples. Returns the products of one frame."""
    ny, nx, _ = frame.shape
    red = frame[:, :, cfg["red"]]
    nir = frame[:, :, cfg["nir"]]
    blue = frame[:, :, cfg["blue"]]
    nd = ndvi8(nir, red)
    cloud = (blue >= cfg["bright"]) & (np.abs(nd - 128) <= cfg["white"])
    veg = ~cloud & (nd >= cfg["veg"])
    prod = (cloud.astype(np.int64) << 15) | (veg.astype(np.int64) << 14) | nd
    edge = sobel_valid(nd, 8)
    n_cloud = int(cloud.sum())
    return dict(
        prod=prod, edge=edge, cloud=n_cloud, veg=int(veg.sum()),
        edges=int((edge >= cfg["edge"]).sum()),
        keep=int(n_cloud * 256 <= cfg["cloud_max"] * nx * ny),
    )


def default_bands(nb: int) -> dict:
    """Band indices for a sensor sampling 400-1000 nm evenly."""
    pick = lambda nm: int(round((nm - 400) / 600 * (nb - 1)))
    return dict(blue=pick(480), red=pick(660), nir=pick(860))


def scene(rng, ny, nx, nb, d, cloud_cover):
    """Fields of crops and soil, a river, and cloud blobs."""
    maxv = (1 << d) - 1
    wl = np.linspace(400, 1000, nb)
    edge = 1 / (1 + np.exp(-(wl - 710) / 15))          # vegetation red edge
    spectra = {
        "water": 0.08 - 0.06 * (wl - 400) / 600,
        "crop": 0.05 + 0.04 * np.exp(-((wl - 550) / 30) ** 2) + 0.45 * edge,
        "soil": 0.15 + 0.20 * (wl - 400) / 600,
        "cloud": 0.85 + 0.03 * np.sin(wl / 90),
    }
    yy, xx = np.mgrid[0:ny, 0:nx]
    cls = np.where(((xx // 6) + (yy // 5)) % 3 == 0, "soil", "crop").astype(object)
    river = np.abs(xx - (nx * 0.6 + 3 * np.sin(yy / 4))) < 1.5
    cls[river] = "water"
    for _ in range(3):
        cy, cx, rad = rng.integers(0, ny), rng.integers(0, nx), rng.integers(2, 6)
        if rng.random() < cloud_cover:
            cls[(yy - cy) ** 2 + (xx - cx) ** 2 < rad ** 2] = "cloud"
    cube = np.stack([[spectra[c] for c in row] for row in cls]) * maxv
    cube += rng.normal(0, maxv * 0.01, size=cube.shape)
    cube = np.clip(np.rint(cube), 0, maxv).astype(np.int64)
    cube[0, 0, :] = 0                                    # NIR + RED = 0
    cube[-1, -1, :] = maxv                               # saturation
    return cube


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["vectors"])
    ap.add_argument("--d", type=int, default=12)
    ap.add_argument("--nx", type=int, default=32)
    ap.add_argument("--ny", type=int, default=24)
    ap.add_argument("--nb", type=int, default=16)
    ap.add_argument("--frames", type=int, default=2)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cloud-max", default="32", help="max cloud fraction to keep, x/256, or 'auto'")
    ap.add_argument("--random", action="store_true", help="uniform random samples instead of a scene")
    ap.add_argument("--vary-cfg", action="store_true", help="new random configuration every frame")
    ap.add_argument("--out", type=Path, default=Path("build/analytics/case"))
    a = ap.parse_args(argv)
    rng = np.random.default_rng(a.seed)
    maxv = (1 << a.d) - 1
    base = dict(default_bands(a.nb), bright=int(0.6 * maxv), white=24, veg=170, edge=40,
                cloud_max=0 if a.cloud_max == "auto" else int(a.cloud_max))
    frames, cfgs = [], []
    for f in range(a.frames):
        cfg = dict(base)
        if a.random:
            if f % 2 == 0:
                fr = rng.integers(0, maxv + 1, size=(a.ny, a.nx, a.nb))
            else:                                        # low contrast: mid-range edge magnitudes
                lvl = rng.integers(maxv // 4, maxv // 2, size=(a.ny, a.nx, 1))
                fr = lvl + rng.integers(-(maxv // 12), maxv // 12 + 1, size=(a.ny, a.nx, a.nb))
            fr[0, 0, :] = maxv                           # flat and bright: cloud if blue is read right
            fr[-1, -1, :] = 0                            # NIR + RED = 0
            frames.append(fr)
        else:
            frames.append(scene(rng, a.ny, a.nx, a.nb, a.d, cloud_cover=[1.0, 0.0][f % 2]))
        if a.random or a.vary_cfg:
            # red and NIR differ (else NDVI is flat); band 0 arrives with the
            # frame's first sample, where the band tap switches to the new
            # selection, so red, NIR and blue take it in turn
            red, nir = (int(v) for v in rng.permutation(a.nb)[:2]) if a.nb > 1 else (0, 0)
            blue = int(rng.integers(0, a.nb))
            if f % 3 == 0 and nir == 0:
                red, nir = 0, red
            elif f % 3 == 0:
                red = 0
            elif f % 3 == 1 and red == 0:
                red, nir = nir, 0
            elif f % 3 == 1:
                nir = 0
            else:
                blue = 0
            cfg.update(red=red, nir=nir, blue=blue, bright=int(rng.integers(maxv // 4, 3 * maxv // 4)),
                       white=int(rng.integers(16, 97)), veg=int(rng.integers(130, 201)),
                       edge=int(rng.integers(10, 251)), cloud_max=int(rng.integers(0, 257)))
        if a.cloud_max == "auto":
            assert a.nx * a.ny == 256, "--cloud-max auto needs NX * NY == 256"
            cloud = analyse(frames[-1], cfg)["cloud"]
            cfg["cloud_max"] = cloud if f % 2 == 0 or cloud == 0 else cloud - 1
        cfgs.append(cfg)
    res = [analyse(fr, c) for fr, c in zip(frames, cfgs)]
    a.out.parent.mkdir(parents=True, exist_ok=True)
    dig = (a.d + 3) // 4
    with Path(f"{a.out}_in.hex").open("w") as fi:
        for fr in frames:
            fi.writelines(f"{int(v):0{dig}x}\n" for v in fr.reshape(-1))
    with Path(f"{a.out}_prod.hex").open("w") as fp, Path(f"{a.out}_edge.hex").open("w") as fe:
        for r in res:
            fp.writelines(f"{int(v):04x}\n" for v in r["prod"].reshape(-1))
            fe.writelines(f"{int(v):02x}\n" for v in r["edge"].reshape(-1))
    Path(f"{a.out}_sum.txt").write_text("".join(f"{r['cloud']} {r['veg']} {r['edges']} {r['keep']}\n" for r in res))
    keys = ("red", "nir", "blue", "bright", "white", "veg", "edge", "cloud_max")
    Path(f"{a.out}_cfg.txt").write_text("".join(" ".join(str(c[k]) for k in keys) + "\n" for c in cfgs))
    for i, r in enumerate(res):
        npix = a.nx * a.ny
        print(f"frame {i}: cloud {r['cloud']}/{npix}, vegetation {r['veg']}, edges {r['edges']}, keep {r['keep']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
