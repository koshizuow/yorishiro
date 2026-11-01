"""models/core/fit.npz for the tracking core: everything the landmark -> ARKit fit needs that is computed once
from ICT-FaceKit and MediaPipe's canonical face (the correspondence, the solvers' matrices, the mirror order
of the landmarks). The core reads it instead of redoing that setup, so it needs neither ICT-FaceKit nor Python.

    uv run python tools/export_fit.py

(The golden outputs the core's tests compare against, testdata/core-golden, were written by the Python
tracker's tools/export_core.py; it and the Python tracker are in git history before the research/ rename.)
"""

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
from yorishiro_research.adapters import mediapipe_points as mpp  # noqa: E402
from yorishiro_research.adapters.mediapipe_points import MediaPipePointFitter  # noqa: E402
from yorishiro_research.avatar.ict import ICT_SHAPES, ensure_ict_facekit  # noqa: E402
from yorishiro_research.mediapipe_ncnn.landmarks import mirror_index  # noqa: E402
from yorishiro_research.models import MODEL_DIR  # noqa: E402


def solver_arrays(prefix: str, solver) -> dict:
    return {f"{prefix}_a": solver.a, f"{prefix}_h": solver.h, f"{prefix}_step": np.float64(solver.step),
            f"{prefix}_active": solver.active.astype(np.int64)}


def export_fit(fitter: MediaPipePointFitter, out: Path) -> None:
    data = {
        "reference": fitter.reference,
        "src_idx": fitter.src_idx.astype(np.int64),
        "ict_idx": fitter.ict_idx.astype(np.int64),
        "arkit_of_shape": np.array(fitter.arkit_of_shape, np.int64),
        "n_shapes": np.int64(len(ICT_SHAPES)),
        "rigid": mpp.MP_RIGID.astype(np.int64),
        "flip_mirror": mirror_index(mpp.load_canonical()).astype(np.int64),
        **solver_arrays("main", fitter.solver),
    }
    for i, (rows, taken, solver) in enumerate(fitter.regions):
        data[f"region{i}_rows"] = rows.astype(np.int64)
        data[f"region{i}_taken"] = taken.astype(np.uint8)
        data.update(solver_arrays(f"region{i}", solver))
    data["n_regions"] = np.int64(len(fitter.regions))
    out.parent.mkdir(parents=True, exist_ok=True)
    # row-major everywhere: the core reads arrays in C order (the solver's matrix is a transpose)
    np.savez(out, **{k: np.ascontiguousarray(v) for k, v in data.items()})
    print(f"wrote {out} ({sum(v.nbytes for v in data.values()) / 1e6:.1f} MB)")


if __name__ == "__main__":
    export_fit(MediaPipePointFitter(ensure_ict_facekit()), MODEL_DIR / "core" / "fit.npz")
