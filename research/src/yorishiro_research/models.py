import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
# the models folder the tracking core loads (models/README.md); downloads and conversion steps land there too
MODEL_DIR = REPO_ROOT / "models"

FACE_LANDMARKER_URL = (
    "https://storage.googleapis.com/mediapipe-models/face_landmarker/"
    "face_landmarker/float16/1/face_landmarker.task"
)
HAND_LANDMARKER_URL = (
    "https://storage.googleapis.com/mediapipe-models/hand_landmarker/"
    "hand_landmarker/float16/1/hand_landmarker.task"
)
CANONICAL_FACE_URL = (
    "https://raw.githubusercontent.com/google-ai-edge/mediapipe/master/"
    "mediapipe/modules/face_geometry/data/canonical_face_model.obj"
)


def _download(url: str, path: Path) -> Path:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".part")
        print(f"Downloading {url}")
        urllib.request.urlretrieve(url, tmp)
        tmp.rename(path)
    return path


def ensure_face_landmarker() -> Path:
    return _download(FACE_LANDMARKER_URL, MODEL_DIR / "face_landmarker.task")


def ensure_hand_landmarker() -> Path:
    return _download(HAND_LANDMARKER_URL, MODEL_DIR / "hand_landmarker.task")


def ensure_canonical_face_model() -> Path:
    return _download(CANONICAL_FACE_URL, MODEL_DIR / "canonical_face_model.obj")
