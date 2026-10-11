"""Unit tests for the CCSDS 123.0-B-2 reference model (model/ccsds123.py).

The byte-exact comparison with the independent NTNU model is a separate step
(scripts/check_ccsds123_ntnu.py, `make ntnu-check`); these tests check the
model on its own: lossless round trips, header fields, residual mapping.
"""
import itertools

import numpy as np
import pytest

import ccsds123 as m


def _params(**kw):
    base = dict(nx=12, ny=6, nz=8, d=12, p=3)
    base.update(kw)
    pr = m.Params(**base)
    pr.check()
    return pr


CONFIGS = [
    dict(),
    dict(full=False),
    dict(local_sum=m.LS_WIDE_COLUMN),
    dict(full=False, local_sum=m.LS_WIDE_COLUMN, p=0),
    dict(d=16, p=15, nz=17, omega=19, k_init=14),
    dict(d=2, p=1, k_init=0, u_max=8),
    dict(d=10, omega=16, r=32, v_min=-6, v_max=9, t_inc_log2=4),
    dict(u_max=8, gamma_star=4, k_init=0),
    dict(gamma0=8, gamma_star=11),
    dict(nx=1, full=False, local_sum=m.LS_WIDE_COLUMN),
    dict(ny=1),
    dict(nz=1, p=0),
]


@pytest.mark.parametrize("cfg,kind", list(itertools.product(CONFIGS, ["scene", "random", "extremes"])))
def test_round_trip(cfg, kind):
    pr = _params(**cfg)
    img = m.test_image(np.random.default_rng(7), pr, kind)
    data = m.compress(img, pr)
    assert np.array_equal(m.decompress(data), img)


def test_header_round_trip():
    pr = _params(full=False, local_sum=m.LS_WIDE_COLUMN, p=7, omega=15, r=48, v_min=-3, v_max=5,
                 t_inc_log2=9, u_max=32, gamma_star=9, gamma0=4, k_init=5)
    hdr = int(m.header_bits(pr), 2).to_bytes(19, "big")
    back, n = m.parse_header(hdr)
    assert n == 19
    assert back == pr


def test_map_unmap_exhaustive():
    d = 5
    smax = (1 << d) - 1
    for st in range(0, 2 * smax + 1):
        seen = set()
        for s in range(smax + 1):
            dl = m.map_residual(s, st, smax)
            assert 0 <= dl <= smax
            assert m.unmap_residual(dl, st, smax) == s
            seen.add(dl)
        assert len(seen) == smax + 1          # the mapping is a bijection


def test_compresses_smooth_scene():
    pr = _params(nx=32, ny=16, nz=24, d=14, p=4)
    img = m.test_image(np.random.default_rng(1), pr, "scene")
    assert len(m.compress(img, pr)) * 8 < 0.75 * img.size * pr.d   # ~1.5:1 with the model noise


def test_rejects_invalid_parameters():
    with pytest.raises(AssertionError):
        _params(nx=1)                          # full prediction needs Nx > 1
    with pytest.raises(AssertionError):
        _params(d=16, omega=19, r=32)          # R < D + Omega + 2
