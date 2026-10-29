"""Tracker plugin registry. Third-party packages register via the `facecap.trackers` entry point group."""

from importlib import import_module
from importlib.metadata import entry_points

from .trackers.base import Tracker

BUILTIN_TRACKERS = {
    "mediapipe": "facecap.trackers.mediapipe_ref:MediaPipeTracker",
    "mediapipe-fit": "facecap.trackers.mediapipe_fit:MediaPipeFitTracker",
    "facemesh-gpu": "facecap.trackers.facemesh_gpu:FaceMeshGpuTracker",
    "smirk": "facecap.trackers.smirk_tracker:SmirkTracker",
}


def available_trackers() -> dict[str, str]:
    found = dict(BUILTIN_TRACKERS)
    for ep in entry_points(group="facecap.trackers"):
        found[ep.name] = ep.value
    return found


def create_tracker(name: str) -> Tracker:
    trackers = available_trackers()
    if name not in trackers:
        raise SystemExit(f"unknown tracker {name!r}, available: {', '.join(sorted(trackers))}")
    module, attr = trackers[name].split(":")
    return getattr(import_module(module), attr)()
