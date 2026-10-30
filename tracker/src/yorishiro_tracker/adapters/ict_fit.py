"""Generic point-set -> ARKit 52 solver using ICT-FaceKit's ARKit-named expression shapes.

Any representation that can produce 3D points (MediaPipe landmarks, FLAME or BFM meshes)
plugs in by providing its neutral point set and 68-landmark indices.
"""

from dataclasses import dataclass

import numpy as np

from ..avatar.ict import REGIONS, IctHead

# ICT-FaceKit README, Multi-PIE 68 point indices.
ICT_68 = np.array([
    1225, 1888, 1052, 367, 1719, 1722, 2199, 1447, 966, 3661, 4390, 3927, 3924, 2608, 3272, 4088,
    3443, 268, 493, 1914, 2044, 1401, 3615, 4240, 4114, 2734, 2509, 978, 4527, 4942, 4857, 1140,
    2075, 1147, 4269, 3360, 1507, 1542, 1537, 1528, 1518, 1511, 3742, 3751, 3756, 3721, 3725,
    3732, 5708, 5695, 2081, 0, 4275, 6200, 6213, 6346, 6461, 5518, 5957, 5841, 5702, 5711, 5533,
    6216, 6207, 6470, 5517, 5966,
])


def similarity_transform(src: np.ndarray, dst: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    """Umeyama: scale, rotation, translation minimizing |s R src + t - dst|."""
    mu_s, mu_d = src.mean(0), dst.mean(0)
    xs, xd = src - mu_s, dst - mu_d
    u, sig, vt = np.linalg.svd(xd.T @ xs / len(src))
    d = np.eye(3)
    d[2, 2] = np.sign(np.linalg.det(u @ vt))
    r = u @ d @ vt
    s = float(np.trace(np.diag(sig) @ d) / xs.var(0).sum())
    return s, r, mu_d - s * r @ mu_s


def apply(s: float, r: np.ndarray, t: np.ndarray, pts: np.ndarray) -> np.ndarray:
    return s * pts @ r.T + t


@dataclass
class Correspondence:
    src_idx: np.ndarray  # (K,) indices into the source point set
    ict_idx: np.ndarray  # (K,) matching ICT vertex indices
    src_neutral_in_ict: np.ndarray  # (N, 3) source neutral points mapped into ICT space
    rms_68: float  # landmark fit error after alignment, ICT units (cm)


def build_correspondence(head: IctHead, src_neutral: np.ndarray, src_68: np.ndarray,
                         max_dist: float = 0.6) -> Correspondence:
    s, r, t = similarity_transform(src_neutral[src_68], head.neutral[ICT_68])
    src_in_ict = apply(s, r, t, src_neutral)
    rms = float(np.sqrt(((src_in_ict[src_68] - head.neutral[ICT_68]) ** 2).sum(1).mean()))
    lo, hi = REGIONS["face"]
    face = head.neutral[lo:hi]
    d2 = ((src_in_ict[:, None, :] - face[None]) ** 2).sum(-1)
    nearest = d2.argmin(1)
    ok = np.sqrt(d2[np.arange(len(src_in_ict)), nearest]) < max_dist
    return Correspondence(np.nonzero(ok)[0], nearest[ok] + lo, src_in_ict, rms)


class IctSolver:
    """Bounded least squares for ICT expression weights in [0, 1] (FISTA, warm-started)."""

    def __init__(self, head: IctHead, ict_idx: np.ndarray, active: np.ndarray, reg: float = 0.02):
        self.active = np.nonzero(active)[0]
        a = head.deltas[self.active][:, ict_idx, :].reshape(len(self.active), -1).T
        self.a = a
        self.h = a.T @ a + reg * np.eye(a.shape[1])
        self.step = 1.0 / np.linalg.eigvalsh(self.h).max()
        self.w = np.zeros(a.shape[1])
        self.n_shapes = head.deltas.shape[0]

    def solve(self, displacement: np.ndarray, iters: int = 60) -> np.ndarray:
        g = self.a.T @ displacement.reshape(-1)
        w = y = self.w.copy()
        tk = 1.0
        for _ in range(iters):
            w_next = np.clip(y - self.step * (self.h @ y - g), 0.0, 1.0)
            tk_next = (1 + np.sqrt(1 + 4 * tk * tk)) / 2
            y = w_next + (tk - 1) / tk_next * (w_next - w)
            w, tk = w_next, tk_next
        self.w = w
        full = np.zeros(self.n_shapes, dtype=np.float32)
        full[self.active] = w
        return full
