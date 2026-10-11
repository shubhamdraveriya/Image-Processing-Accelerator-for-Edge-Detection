"""Checks of the hyperspectral front-end model against hand-worked cases."""
import numpy as np

from hs_golden import badpix, band_select, radiometric


def test_radiometric_unity_gain_is_offset_only():
    x = np.array([[[100, 5]]])
    dark = np.array([[10, 10]])
    gain = np.array([[1 << 14, 1 << 14]])
    assert radiometric(x, dark, gain, 12, 14).tolist() == [[[90, 0]]]   # 5 - 10 clamps to 0


def test_radiometric_rounding_and_saturation():
    x = np.array([[[3, 4000]]])
    dark = np.zeros((1, 2), dtype=np.int64)
    gain = np.array([[3 << 13, 2 << 14]])          # 1.5 and 2.0
    # 3 * 1.5 = 4.5 -> rounds half up to 5; 4000 * 2 saturates at 4095
    assert radiometric(x, dark, gain, 12, 14).tolist() == [[[5, 4095]]]


def test_badpix_nearest_left_same_band():
    x = np.array([[[1, 10], [2, 20], [3, 30], [4, 40]]])   # 1 line, 4 pixels, 2 bands
    bad = np.zeros((4, 2), dtype=bool)
    bad[0, 1] = True     # no left neighbour -> 0
    bad[2, 0] = True     # -> pixel 1 band 0
    bad[3, 0] = True     # -> still pixel 1 (pixel 2 was bad)
    out = badpix(x, bad)
    assert out[0, :, 0].tolist() == [1, 2, 2, 2]
    assert out[0, :, 1].tolist() == [0, 20, 30, 40]


def test_band_select():
    x = np.arange(12).reshape(1, 2, 6)
    mask = np.array([True, False, False, True, True, False])
    assert band_select(x, mask).tolist() == [[[0, 3, 4], [6, 9, 10]]]
