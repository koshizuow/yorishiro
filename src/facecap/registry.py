"""Tracker plugin registry. Third-party packages register via the `facecap.trackers` entry point group."""

import inspect
from importlib import import_module
from importlib.metadata import entry_points

from .trackers.base import Tracker

BUILTIN_TRACKERS = {
    "mediapipe": "facecap.trackers.mediapipe_ref:MediaPipeTracker",
    "mediapipe-fit": "facecap.trackers.mediapipe_fit:MediaPipeFitTracker",
    "facemesh": "facecap.trackers.facemesh_gpu:FaceMeshGpuTracker",
    "facemesh-gpu": "facecap.trackers.facemesh_gpu:FaceMeshGpuTracker",  # old name
    "smirk": "facecap.trackers.smirk_tracker:SmirkTracker",
}


def available_trackers() -> dict[str, str]:
    found = dict(BUILTIN_TRACKERS)
    for ep in entry_points(group="facecap.trackers"):
        found[ep.name] = ep.value
    return found


def create_tracker(name: str, runtime: str | None = None) -> Tracker:
    trackers = available_trackers()
    if name not in trackers:
        raise SystemExit(f"unknown tracker {name!r}, available: {', '.join(sorted(trackers))}")
    module, attr = trackers[name].split(":")
    cls = getattr(import_module(module), attr)
    if runtime is not None and "runtime" in inspect.signature(cls).parameters:
        return cls(runtime=runtime)
    return cls()
