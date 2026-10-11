#!/usr/bin/env python3
"""Cross-check model/ccsds123.py against the independent NTNU CCSDS 123.0-B-2
high-level model (https://github.com/NTNU-SmallSat-Lab/ccsds123_issue_2_verification_model,
MIT licence), which its authors verified against the official CCSDS test
vectors. For each configuration both models compress the same image with the
same header, and the complete compressed files (header + body + padding)
must be identical byte for byte.

  python3 scripts/check_ccsds123_ntnu.py --ntnu <path to a clone of the NTNU repo>
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
import ccsds123 as m  # noqa: E402

NTNU_COMMIT = "9fabb0371ebf93d72a0f83ca053e9cdb2c63e3c6"

# (name, Params overrides, image kind)
CASES = [
    ("full_neighbor_P3",       dict(nx=12, ny=6, nz=8, d=12, p=3), "scene"),
    ("reduced_neighbor_P3",    dict(nx=12, ny=6, nz=8, d=12, p=3, full=False), "scene"),
    ("full_column_P5",         dict(nx=10, ny=5, nz=9, d=12, p=5, local_sum=m.LS_WIDE_COLUMN), "scene"),
    ("reduced_column_P0",      dict(nx=9, ny=4, nz=5, d=10, p=0, full=False, local_sum=m.LS_WIDE_COLUMN), "random"),
    ("full_P15_d16_om19",      dict(nx=6, ny=4, nz=17, d=16, p=15, omega=19, r=64), "scene"),
    ("full_P1_extremes",       dict(nx=7, ny=5, nz=4, d=8, p=1, omega=4, r=32), "extremes"),
    ("random_umax8_rescale",   dict(nx=16, ny=8, nz=3, d=14, p=2, u_max=8, gamma_star=4, gamma0=1,
                                    k_init=0, v_min=-6, v_max=9, t_inc_log2=4), "random"),
    ("r_wrap_d16",             dict(nx=8, ny=6, nz=6, d=16, p=4, omega=14, r=32,
                                    k_init=14, gamma0=8, gamma_star=11), "extremes"),
    ("single_column_nx1",      dict(nx=1, ny=9, nz=5, d=12, p=3, full=False, local_sum=m.LS_WIDE_COLUMN), "scene"),
    ("realistic_32x16x24",     dict(nx=32, ny=16, nz=24, d=14, p=4), "scene"),
    ("single_line_ny1",        dict(nx=20, ny=1, nz=4, d=12, p=2, full=False), "scene"),
]


def run_case(ntnu: Path, name: str, over: dict, kind: str, seed: int) -> bool:
    pr = m.Params(**over)
    try:
        pr.check()
    except AssertionError:
        print(f"skip  {name} (invalid parameters)")
        return True
    img = m.test_image(np.random.default_rng(seed), pr, kind)
    ours = m.compress(img, pr)
    with tempfile.TemporaryDirectory() as td:
        work = Path(td) / "ntnu"
        shutil.copytree(ntnu, work, ignore=shutil.ignore_patterns(".git", "output"))
        (work / "output").mkdir()
        # NTNU parses the geometry from the file name, so the name must not contain 'x'
        raw = m.write_raw(work / "raw_images" / "img", img, pr).relative_to(work)
        hdr = work / "header.bin"
        hdr.write_bytes(int(m.header_bits(pr), 2).to_bytes(19, "big"))
        p = subprocess.run([sys.executable, "ccsds123_0_b_2_high_level_model.py", str(raw), "--header", str(hdr)],
                           cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if p.returncode != 0:
            print(f"FAIL  {name}: NTNU model error\n{p.stdout[-2000:]}")
            return False
        theirs = (work / "output" / "z-output-bitstream.bin").read_bytes()
    ok = ours == theirs
    first = next((i for i, (a, b) in enumerate(zip(ours, theirs)) if a != b), min(len(ours), len(theirs)))
    print(f"{'PASS' if ok else 'FAIL'}  {name:<24} {len(ours):6d} bytes"
          + ("" if ok else f"  (ntnu {len(theirs)} bytes, first difference at byte {first})"))
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ntnu", type=Path, required=True)
    ap.add_argument("-k", default="")
    a = ap.parse_args()
    res = [run_case(a.ntnu, n, o, k, i + 1) for i, (n, o, k) in enumerate(CASES) if a.k in n]
    print(f"\n{sum(res)}/{len(res)} configurations bit-identical to the NTNU model")
    return 0 if all(res) else 1


if __name__ == "__main__":
    sys.exit(main())
