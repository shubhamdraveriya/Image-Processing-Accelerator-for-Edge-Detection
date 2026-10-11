"""Sanity checks of the golden model against a direct per-pixel definition."""
import numpy as np

from edge_golden import avg_pool2x2, edge_pipeline, sobel_valid

KX = np.array([[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]])
KY = np.array([[1, 2, 1], [0, 0, 0], [-1, -2, -1]])


def ref_sobel(img, dw):
    h, w = img.shape
    out = np.zeros((h - 2, w - 2), dtype=np.int64)
    for r in range(h - 2):
        for c in range(w - 2):
            win = img[r:r + 3, c:c + 3]
            out[r, c] = min(abs((win * KX).sum()) + abs((win * KY).sum()), (1 << dw) - 1)
    return out


def test_sobel_matches_reference():
    rng = np.random.default_rng(0)
    for dw, (h, w) in [(8, (7, 9)), (10, (12, 6)), (12, (5, 5))]:
        img = rng.integers(0, 1 << dw, size=(h, w))
        assert np.array_equal(sobel_valid(img, dw), ref_sobel(img, dw))


def test_flat_image_has_no_edges():
    img = np.full((8, 8), 100)
    assert not sobel_valid(img, 8).any()


def test_hard_edge_saturates():
    img = np.zeros((6, 6), dtype=np.int64)
    img[:, 3:] = 255
    assert sobel_valid(img, 8).max() == 255


def test_pool():
    img = np.array([[170, 170, 0, 0], [50, 50, 0, 0]])
    assert avg_pool2x2(img).tolist() == [[110, 0]]
    assert avg_pool2x2(np.array([[1, 1], [1, 0]])).tolist() == [[0]]   # floor


def test_pipeline_shape():
    assert edge_pipeline(np.zeros((64, 64)), 8).shape == (31, 31)
