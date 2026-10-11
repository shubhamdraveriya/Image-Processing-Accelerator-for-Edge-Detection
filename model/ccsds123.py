#!/usr/bin/env python3
"""CCSDS 123.0-B-2 lossless compressor and decompressor (reference model).

This is the bit-exact reference for rtl/ccsds123/. It covers the
configuration the hardware implements:

  * lossless (quantizer fidelity control = lossless), unsigned samples, D <= 16
  * full or reduced prediction mode, P = 0..15 spectral bands
  * wide neighbour-oriented or wide column-oriented local sums
  * default weight initialisation, weight exponent offsets all zero
  * sample-adaptive entropy coder, band-interleaved (BIP, M = Nz) order
  * output word size B = 1 byte, no supplementary tables

It is written from the standard (CCSDS 123.0-B-2, sections 4 and 5) and is
cross-checked bit for bit against the independent NTNU high-level model
(scripts/check_ccsds123_ntnu.py), which its authors verified against the
official CCSDS test vectors.

Images are numpy arrays shaped (Ny, Nx, Nz) (BIP: band fastest).
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

LS_WIDE_NEIGHBOR = 0
LS_WIDE_COLUMN = 2


@dataclass
class Params:
    nx: int
    ny: int
    nz: int
    d: int = 16                  # dynamic range D (bits), 2..16
    p: int = 3                   # number of spectral bands used for prediction
    full: bool = True            # full (True) or reduced (False) prediction mode
    local_sum: int = LS_WIDE_NEIGHBOR
    omega: int = 13              # weight component resolution, 4..19
    r: int = 64                  # register size R, max(32, D+Omega+2)..64
    v_min: int = -1              # weight update scaling exponent initial parameter
    v_max: int = 3               # ... final parameter
    t_inc_log2: int = 6          # log2 of the change interval t_inc, 4..11
    u_max: int = 18              # unary length limit, 8..32
    gamma_star: int = 6          # rescaling counter size, max(4, gamma0+1)..11
    gamma0: int = 1              # initial count exponent, 1..8
    k_init: int = 3              # accumulator initialisation constant K, 0..min(D-2, 14)

    def check(self) -> None:
        assert 2 <= self.d <= 16
        assert 0 <= self.p <= 15
        assert self.local_sum in (LS_WIDE_NEIGHBOR, LS_WIDE_COLUMN)
        assert 4 <= self.omega <= 19
        assert max(32, self.d + self.omega + 2) <= self.r <= 64
        assert -6 <= self.v_min <= self.v_max <= 9
        assert 4 <= self.t_inc_log2 <= 11
        assert 8 <= self.u_max <= 32
        assert 1 <= self.gamma0 <= 8 and max(4, self.gamma0 + 1) <= self.gamma_star <= 11
        assert 0 <= self.k_init <= min(self.d - 2, 14)
        assert 1 <= self.nx <= 65535 and 1 <= self.ny <= 65535 and 1 <= self.nz <= 65535
        # Nx = 1: full prediction is not allowed (4.3.1) and neighbour-oriented
        # sums would need x+1; use reduced mode with column-oriented sums.
        assert self.nx > 1 or (not self.full and self.local_sum == LS_WIDE_COLUMN)

    @property
    def cz(self) -> int:
        return self.p + (3 if self.full else 0)


# ----------------------------------------------------------------- header

def _bits(v: int, n: int) -> str:
    assert 0 <= v < (1 << n), (v, n)
    return format(v, f"0{n}b")


def header_bits(pr: Params) -> str:
    """Image + predictor + entropy coder metadata for this configuration."""
    b = ""
    # essential subpart (12 bytes)
    b += _bits(0, 8)                       # user-defined data
    b += _bits(pr.nx % 65536, 16)
    b += _bits(pr.ny % 65536, 16)
    b += _bits(pr.nz % 65536, 16)
    b += "0"                               # unsigned samples
    b += "0"                               # reserved
    b += "0"                               # large dynamic range flag (D <= 16)
    b += _bits(pr.d % 16, 4)
    b += "0"                               # band-interleaved encoding order
    b += _bits(pr.nz % 65536, 16)          # sub-frame interleaving depth M = Nz (BIP)
    b += "00"                              # reserved
    b += _bits(1, 3)                       # output word size B = 1 byte
    b += _bits(0, 2)                       # sample-adaptive entropy coder
    b += "0"                               # reserved
    b += _bits(0, 2)                       # lossless
    b += "00"                              # reserved
    b += _bits(0, 4)                       # no supplementary information tables
    # predictor primary structure (5 bytes)
    b += "0"                               # reserved
    b += "0"                               # sample representative subpart not included
    b += _bits(pr.p, 4)
    b += "0" if pr.full else "1"
    b += "0"                               # weight exponent offsets all zero
    b += _bits(pr.local_sum, 2)
    b += _bits(pr.r % 64, 6)
    b += _bits(pr.omega - 4, 4)
    b += _bits(pr.t_inc_log2 - 4, 4)
    b += _bits(pr.v_min + 6, 4)
    b += _bits(pr.v_max + 6, 4)
    b += "0"                               # weight exponent offset table not included
    b += "0"                               # default weight initialisation
    b += "0"                               # weight init table not included
    b += _bits(0, 5)                       # weight init resolution (0 for default)
    # sample-adaptive entropy coder structure (2 bytes)
    b += _bits(pr.u_max % 32, 5)
    b += _bits(pr.gamma_star - 4, 3)
    b += _bits(pr.gamma0 % 8, 3)
    b += _bits(pr.k_init, 4)
    b += "0"                               # accumulator init table not included
    assert len(b) == 19 * 8
    return b


def parse_header(data: bytes) -> tuple[Params, int]:
    bits = "".join(format(x, "08b") for x in data[:19])
    f = lambda a, n: int(bits[a:a + n], 2)
    pr = Params(nx=f(8, 16) or 65536, ny=f(24, 16) or 65536, nz=f(40, 16) or 65536)
    pr.d = f(59, 4) or 16
    assert f(56, 1) == 0 and f(58, 1) == 0 and f(63, 1) == 0, "unsupported image type"
    assert f(85, 2) == 0 and f(88, 2) == 0 and f(92, 4) == 0, "unsupported coder/quantizer"
    o = 96
    assert f(o + 1, 1) == 0
    pr.p = f(o + 2, 4)
    pr.full = f(o + 6, 1) == 0
    assert f(o + 7, 1) == 0
    pr.local_sum = f(o + 8, 2)
    pr.r = f(o + 10, 6) or 64
    pr.omega = f(o + 16, 4) + 4
    pr.t_inc_log2 = f(o + 20, 4) + 4
    pr.v_min = f(o + 24, 4) - 6
    pr.v_max = f(o + 28, 4) - 6
    assert f(o + 33, 1) == 0, "custom weight init unsupported"
    o = 136
    pr.u_max = f(o, 5) or 32
    pr.gamma_star = f(o + 5, 3) + 4
    pr.gamma0 = f(o + 8, 3) or 8
    pr.k_init = f(o + 11, 4)
    assert pr.k_init != 15, "accumulator init table unsupported"
    return pr, 19


# -------------------------------------------------------------- predictor

def _mod_r(x: int, r: int) -> int:
    return ((x + (1 << (r - 1))) % (1 << r)) - (1 << (r - 1))


def _clip(x: int, lo: int, hi: int) -> int:
    return lo if x < lo else hi if x > hi else x


class _State:
    """Per-band adaptive state shared by the encoder and the decoder."""

    def __init__(self, pr: Params):
        self.pr = pr
        self.smax = (1 << pr.d) - 1
        self.smid = 1 << (pr.d - 1)
        self.wmin = -(1 << (pr.omega + 2))
        self.wmax = (1 << (pr.omega + 2)) - 1
        self.w = np.zeros((pr.nz, pr.cz), dtype=object)
        self.dc = np.zeros((pr.ny, pr.nx, pr.nz), dtype=object)    # central local differences
        # sample-adaptive coder
        self.cnt_max = (1 << pr.gamma_star) - 1
        k2 = pr.k_init
        k1 = k2 if k2 <= 30 - pr.d else 2 * k2 + pr.d - 30
        self.gamma1 = 1 << pr.gamma0
        self.acc1 = ((3 * (1 << (k1 + 6)) - 49) * self.gamma1) >> 7
        self.acc = [0] * pr.nz
        self.gamma = 0

    def default_weights(self) -> list[int]:
        pr = self.pr
        w = [0] * pr.cz
        o = 3 if pr.full else 0
        if pr.p > 0:
            w[o] = (7 * (1 << pr.omega)) >> 3
            for i in range(1, pr.p):
                w[o + i] = w[o + i - 1] >> 3
        return w

    def rho(self, t: int) -> int:
        pr = self.pr
        if t < pr.nx:
            v = pr.v_min
        else:
            v = min(pr.v_min + ((t - pr.nx) >> pr.t_inc_log2), pr.v_max)
        return v + pr.d - pr.omega

    def local_sum(self, s, y, x, z) -> int:
        pr = self.pr
        if pr.local_sum == LS_WIDE_COLUMN:
            return 4 * s[y - 1, x, z] if y > 0 else 4 * s[y, x - 1, z]
        if y == 0:
            return 4 * s[y, x - 1, z]
        if x == 0:
            return 2 * (s[y - 1, x, z] + s[y - 1, x + 1, z])
        if x == pr.nx - 1:
            return s[y, x - 1, z] + s[y - 1, x - 1, z] + 2 * s[y - 1, x, z]
        return s[y, x - 1, z] + s[y - 1, x - 1, z] + s[y - 1, x, z] + s[y - 1, x + 1, z]

    def predict(self, s, y, x, z):
        """Return (s_tilde, U) for sample (y, x, z). s must hold all samples
        that precede (y, x, z) in BIP order."""
        pr = self.pr
        t = y * pr.nx + x
        if t == 0:
            st = 2 * s[y, x, z - 1] if (pr.p > 0 and z > 0) else 2 * self.smid
            return st, None
        sigma = self.local_sum(s, y, x, z)
        u = []
        if pr.full:
            if y > 0:
                n = 4 * s[y - 1, x, z] - sigma
                w_ = 4 * s[y, x - 1, z] - sigma if x > 0 else 4 * s[y - 1, x, z] - sigma
                nw = 4 * s[y - 1, x - 1, z] - sigma if x > 0 else 4 * s[y - 1, x, z] - sigma
                u += [n, w_, nw]
            else:
                u += [0, 0, 0]
        for i in range(1, pr.p + 1):
            u.append(self.dc[y, x, z - i] if z - i >= 0 else 0)
        if t == 1:
            self.w[z] = self.default_weights()
        dhat = sum(int(a) * int(b) for a, b in zip(self.w[z], u))
        om = pr.omega
        sb = _mod_r(dhat + (1 << om) * (sigma - 4 * self.smid), pr.r)
        sb = _clip(sb + (1 << (om + 2)) * self.smid + (1 << (om + 1)),
                   0, (1 << (om + 2)) * self.smax + (1 << (om + 1)))
        self._sigma = sigma
        return sb >> (om + 1), u

    def central_diff(self, s, y, x, z):
        if y * self.pr.nx + x > 0:
            self.dc[y, x, z] = 4 * s[y, x, z] - self._sigma

    def update_weights(self, t, z, st, u, sval):
        if u is None:
            return
        e = 2 * sval - st
        sg = 1 if e >= 0 else -1
        rho = self.rho(t)
        new = []
        for wi, ui in zip(self.w[z], u):
            v = sg * int(ui)
            v = (v >> rho) if rho >= 0 else (v << -rho)
            new.append(_clip(int(wi) + ((v + 1) >> 1), self.wmin, self.wmax))
        self.w[z] = new

    # ---- sample-adaptive coder state
    def begin_pixel(self, t):
        if t == 1:
            self.gamma = self.gamma1
            self.acc = [self.acc1] * self.pr.nz
        elif t > 1:
            self.rescale = self.gamma == self.cnt_max
            self.gamma = (self.gamma + 1) >> 1 if self.rescale else self.gamma + 1

    def k_param(self, z) -> int:
        g, a = self.gamma, self.acc[z]
        thr = a + ((49 * g) >> 7)
        if 2 * g > thr:
            return 0
        k = 0
        while k < self.pr.d - 2 and (g << (k + 1)) <= thr:
            k += 1
        return k

    def update_acc(self, z, delta):
        # Sigma(t+1) from Sigma(t) and delta(t); rescale if Gamma(t) is at its limit
        a = self.acc[z] + delta
        self.acc[z] = (a + 1) >> 1 if self.gamma == self.cnt_max else a


def map_residual(sval: int, st: int, smax: int) -> int:
    sh = st >> 1
    dlt = sval - sh
    theta = min(sh, smax - sh)
    if abs(dlt) > theta:
        return abs(dlt) + theta
    term = dlt if st % 2 == 0 else -dlt
    return 2 * abs(dlt) if 0 <= term <= theta else 2 * abs(dlt) - 1


def unmap_residual(delta: int, st: int, smax: int) -> int:
    sh = st >> 1
    theta = min(sh, smax - sh)
    if delta > 2 * theta:
        mag = delta - theta
        return sh + mag if sh + mag <= smax and theta == sh else sh - mag
    if delta == 0:
        return sh
    mag = (delta + 1) >> 1
    sgn_even = 1 if delta % 2 == 0 else -1          # +mag when even delta and s~ even
    sgn = sgn_even if st % 2 == 0 else -sgn_even
    return sh + sgn * mag


# ------------------------------------------------------------------ codec

def mapped_residuals(img: np.ndarray, pr: Params) -> np.ndarray:
    """delta(y, x, z) for the whole image (the predictor output)."""
    pr.check()
    s = img.astype(np.int64).astype(object)   # Python ints: no overflow
    st_ = _State(pr)
    out = np.zeros(s.shape, dtype=np.int64)
    for y in range(pr.ny):
        for x in range(pr.nx):
            t = y * pr.nx + x
            for z in range(pr.nz):
                st, u = st_.predict(s, y, x, z)
                st_.central_diff(s, y, x, z)
                out[y, x, z] = map_residual(int(s[y, x, z]), st, st_.smax)
                st_.update_weights(t, z, st, u, int(s[y, x, z]))
    return out


def encode_body(img: np.ndarray, pr: Params) -> str:
    """Body bitstring (no header, no padding)."""
    deltas = mapped_residuals(img, pr)
    st_ = _State(pr)
    out = []
    for y in range(pr.ny):
        for x in range(pr.nx):
            t = y * pr.nx + x
            st_.begin_pixel(t)
            for z in range(pr.nz):
                dl = int(deltas[y, x, z])
                if t == 0:
                    out.append(_bits(dl, pr.d))
                    continue
                k = st_.k_param(z)
                u = dl >> k
                if u < pr.u_max:
                    out.append("0" * u + "1" + (format(dl & ((1 << k) - 1), f"0{k}b") if k else ""))
                else:
                    out.append("0" * pr.u_max + _bits(dl, pr.d))
                st_.update_acc(z, dl)
    return "".join(out)


def compress(img: np.ndarray, pr: Params) -> bytes:
    bits = header_bits(pr) + encode_body(img, pr)
    bits += "0" * ((-len(bits)) % 8)
    return int(bits, 2).to_bytes(len(bits) // 8, "big") if bits else b""


def decompress(data: bytes) -> np.ndarray:
    pr, hlen = parse_header(data)
    pr.check()
    bits = "".join(format(x, "08b") for x in data[hlen:])
    pos = 0
    s = np.zeros((pr.ny, pr.nx, pr.nz), dtype=object)
    st_ = _State(pr)
    for y in range(pr.ny):
        for x in range(pr.nx):
            t = y * pr.nx + x
            st_.begin_pixel(t)
            for z in range(pr.nz):
                if t == 0:
                    dl = int(bits[pos:pos + pr.d], 2)
                    pos += pr.d
                else:
                    k = st_.k_param(z)
                    u = 0
                    while u < pr.u_max and bits[pos] == "0":
                        u += 1
                        pos += 1
                    if u == pr.u_max:
                        dl = int(bits[pos:pos + pr.d], 2)
                        pos += pr.d
                    else:
                        pos += 1
                        low = int(bits[pos:pos + k], 2) if k else 0
                        pos += k
                        dl = (u << k) | low
                    st_.update_acc(z, dl)
                st, u_vec = st_.predict(s, y, x, z)
                s[y, x, z] = int(unmap_residual(dl, st, st_.smax))
                st_.central_diff(s, y, x, z)
                st_.update_weights(t, z, st, u_vec, int(s[y, x, z]))
    return s.astype(np.int64)


# ------------------------------------------------------------------- CLI

def test_image(rng, pr: Params, kind: str) -> np.ndarray:
    smax = (1 << pr.d) - 1
    ny, nx, nz = pr.ny, pr.nx, pr.nz
    if kind == "random":
        return rng.integers(0, smax + 1, size=(ny, nx, nz))
    if kind == "extremes":
        return rng.choice([0, smax], size=(ny, nx, nz))
    # smooth spectra with spatial structure and noise: the realistic case
    yy, xx, zz = np.mgrid[0:ny, 0:nx, 0:nz]
    base = 0.45 + 0.25 * np.sin(xx / 3.0 + yy / 5.0) * np.cos(zz / 7.0) + 0.1 * zz / max(nz, 1)
    img = base * smax + rng.normal(0, smax * 0.004, size=base.shape)
    return np.clip(np.rint(img), 0, smax).astype(np.int64)


def write_raw(path: Path, img: np.ndarray, pr: Params) -> Path:
    """Write <name>-u16be-ZxYxX.raw (BSQ, big endian) as the CCSDS test data does."""
    p = path.parent / f"{path.name}-u16be-{pr.nz}x{pr.ny}x{pr.nx}.raw"
    img.transpose(2, 0, 1).astype(">u2").tofile(p)
    return p


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["vectors", "roundtrip"])
    ap.add_argument("--nx", type=int, default=16)
    ap.add_argument("--ny", type=int, default=8)
    ap.add_argument("--nz", type=int, default=10)
    ap.add_argument("--d", type=int, default=12)
    ap.add_argument("--p", type=int, default=3)
    ap.add_argument("--reduced", action="store_true")
    ap.add_argument("--column", action="store_true", help="wide column-oriented local sums")
    ap.add_argument("--omega", type=int, default=13)
    ap.add_argument("--r", type=int, default=64)
    ap.add_argument("--vmin", type=int, default=-1)
    ap.add_argument("--vmax", type=int, default=3)
    ap.add_argument("--tinc", type=int, default=6, help="log2 t_inc")
    ap.add_argument("--umax", type=int, default=18)
    ap.add_argument("--gstar", type=int, default=6)
    ap.add_argument("--g0", type=int, default=1)
    ap.add_argument("--k", type=int, default=3)
    ap.add_argument("--image", choices=["scene", "random", "extremes"], default="scene")
    ap.add_argument("--frames", type=int, default=1)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--header", action="store_true", help="expected output starts each image with the header")
    ap.add_argument("--out", type=Path, default=Path("build/ccsds/case"))
    a = ap.parse_args(argv)
    pr = Params(nx=a.nx, ny=a.ny, nz=a.nz, d=a.d, p=a.p, full=not a.reduced,
                local_sum=LS_WIDE_COLUMN if a.column else LS_WIDE_NEIGHBOR, omega=a.omega, r=a.r,
                v_min=a.vmin, v_max=a.vmax, t_inc_log2=a.tinc, u_max=a.umax, gamma_star=a.gstar,
                gamma0=a.g0, k_init=a.k)
    pr.check()
    rng = np.random.default_rng(a.seed)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    imgs = [test_image(rng, pr, a.image) for _ in range(a.frames)]
    if a.cmd == "roundtrip":
        for img in imgs:
            data = compress(img, pr)
            back = decompress(data)
            assert np.array_equal(back, img), "round trip mismatch"
            print(f"round trip ok: {img.nbytes // 8 * pr.d // 8} -> {len(data)} bytes "
                  f"({pr.d * img.size / 8 / len(data):.2f}:1)")
        return 0
    # vectors for the RTL testbench: samples in, mapped residuals (predictor
    # output), output bytes per image (optional header, body padded to a byte)
    digits = (pr.d + 3) // 4
    with Path(f"{a.out}_in.hex").open("w") as fi, Path(f"{a.out}_exp.hex").open("w") as fe, \
            Path(f"{a.out}_delta.hex").open("w") as fd:
        nbytes = []
        for img in imgs:
            for v in img.reshape(-1):
                fi.write(f"{int(v):0{digits}x}\n")
            for v in mapped_residuals(img, pr).reshape(-1):
                fd.write(f"{int(v):0{digits}x}\n")
            body = encode_body(img, pr)
            body += "0" * ((-len(body)) % 8)
            if a.header:
                body = header_bits(pr) + body
            for i in range(0, len(body), 8):
                fe.write(f"{int(body[i:i + 8], 2):02x}\n")
            nbytes.append(len(body) // 8)
    Path(f"{a.out}_meta.txt").write_text(" ".join(f"{n}" for n in nbytes) + "\n")
    Path(f"{a.out}_header.bin").write_bytes(int(header_bits(pr), 2).to_bytes(19, "big"))
    for i, img in enumerate(imgs):
        write_raw(Path(f"{a.out}_img{i}"), img, pr)
    raw = sum(img.size for img in imgs) * pr.d / 8
    print(f"ccsds123 vectors: {pr.nx}x{pr.ny}x{pr.nz} D={pr.d} P={pr.p} {'full' if pr.full else 'reduced'} "
          f"{'column' if pr.local_sum else 'neighbor'}, {a.frames} image(s), output bytes {nbytes} "
          f"(ratio {raw / sum(nbytes):.2f}:1) -> {a.out}_*")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
