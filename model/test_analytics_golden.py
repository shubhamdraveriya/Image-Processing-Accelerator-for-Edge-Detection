"""Unit tests for model/analytics_golden.py."""
import numpy as np

import analytics_golden as a


def test_ndvi8_matches_float_ndvi():
    rng = np.random.default_rng(0)
    nir = rng.integers(0, 4096, 5000)
    red = rng.integers(0, 4096, 5000)
    nd = a.ndvi8(nir, red)
    ok = (nir + red) > 0
    ref = 128 * ((nir - red) / np.maximum(nir + red, 1) + 1)     # NDVI mapped to [0, 256]
    # floor of the exact value; float rounding can only matter at integers
    assert np.all(np.abs(nd[ok] - np.minimum(np.floor(ref[ok]), 255)) <= 1)
    assert np.mean(nd[ok] == np.minimum(np.floor(ref[ok]), 255)) > 0.99
    assert np.all(nd[~ok] == 128)


def test_ndvi8_end_points():
    assert a.ndvi8(np.array([0]), np.array([0]))[0] == 128     # undefined -> neutral
    assert a.ndvi8(np.array([100]), np.array([0]))[0] == 255   # NDVI = +1 saturates
    assert a.ndvi8(np.array([0]), np.array([100]))[0] == 0     # NDVI = -1
    assert a.ndvi8(np.array([50]), np.array([50]))[0] == 128   # NDVI = 0


def test_scene_classes():
    pr = dict(a.default_bands(16), bright=int(0.6 * 4095), white=24, veg=170, edge=40, cloud_max=32)
    cube = a.scene(np.random.default_rng(3), 24, 32, 16, 12, cloud_cover=1.0)
    r = a.analyse(cube, pr)
    cloud = (r["prod"] >> 15) & 1
    veg = (r["prod"] >> 14) & 1
    assert r["cloud"] == cloud.sum() > 0
    assert not np.any(cloud & veg)                  # a pixel is never both
    assert r["veg"] > 0.3 * cube.shape[0] * cube.shape[1]
    assert r["edge"].shape == (22, 30)


def test_keep_threshold():
    pr = dict(red=0, nir=1, blue=2, bright=0, white=255, veg=255, edge=0, cloud_max=128)
    cube = np.zeros((4, 4, 3), dtype=np.int64)
    cube[:2, :, :] = 100                            # top half: flat and bright -> cloud
    cube[2:, :, 1] = 100                            # bottom half: NIR only -> ndvi8 255
    cube[2:, :, 2] = 0
    pr["bright"] = 50
    r = a.analyse(cube, pr)
    assert r["cloud"] == 8 and r["keep"] == 1       # 8 / 16 = 128 / 256: kept
    pr["cloud_max"] = 127
    assert a.analyse(cube, pr)["keep"] == 0


def test_vectors_per_frame_cfg_and_keep_boundary(tmp_path):
    out = tmp_path / "v"
    assert a.main(["vectors", "--random", "--nx", "4", "--ny", "3", "--nb", "4", "--frames", "6",
                   "--out", str(out)]) == 0
    cfgs = [list(map(int, l.split())) for l in (tmp_path / "v_cfg.txt").read_text().splitlines()]
    assert len(cfgs) == 6 and len({tuple(c) for c in cfgs}) == 6     # a new configuration every frame
    for f, c in enumerate(cfgs):
        assert c[f % 3] == 0 and c[0] != c[1]                        # band 0 rotates; red != NIR
    assert a.main(["vectors", "--cloud-max", "auto", "--nx", "16", "--ny", "16", "--nb", "8",
                   "--frames", "4", "--out", str(out)]) == 0
    keep = [int(l.split()[3]) for l in (tmp_path / "v_sum.txt").read_text().splitlines()]
    assert keep == [1, 0, 1, 0]
