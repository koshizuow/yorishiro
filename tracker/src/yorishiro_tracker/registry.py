"""Tracker plugin registry. Third-party packages register via the `yorishiro.trackers` entry point group."""

import inspect
from importlib import import_module
from importlib.metadata import entry_points

from .trackers.base import Tracker

BUILTIN_TRACKERS = {
    "mediapipe": "yorishiro_tracker.trackers.mediapipe_ref:MediaPipeTracker",
    "mediapipe-fit": "yorishiro_tracker.trackers.mediapipe_fit:MediaPipeFitTracker",
    "facemesh": "yorishiro_tracker.trackers.facemesh_gpu:FaceMeshGpuTracker",
    "facemesh-gpu": "yorishiro_tracker.trackers.facemesh_gpu:FaceMeshGpuTracker",  # old name
    "smirk": "yorishiro_tracker.trackers.smirk_tracker:SmirkTracker",
}


def available_trackers() -> dict[str, str]:
    found = dict(BUILTIN_TRACKERS)
    for ep in entry_points(group="yorishiro.trackers"):
        found[ep.name] = ep.value
    return found


def create_tracker(name: str, runtime: str | None = None) -> Tracker:
    trackers = available_trackers()
    if name not in trackers:
        raise SystemExit(f"unknown tracker {name!r}, available: {', '.join(sorted(trackers))}")
    cls = _load(trackers[name])
    if runtime is not None and "runtime" in inspect.signature(cls).parameters:
        return cls(runtime=runtime)
    return cls()


def describe_trackers() -> list[dict]:
    """Static info for UIs, without instantiating models. Aliases pointing at the same class are skipped."""
    out, seen = [], set()
    for name, target in sorted(available_trackers().items()):
        if target in seen:
            continue
        seen.add(target)
        try:
            cls = _load(target)
        except Exception as e:  # a broken plugin must not hide the others
            out.append({"name": name, "error": str(e)})
            continue
        info = cls.info
        out.append({"name": name, "description": info.description, "license": info.license,
                    "commercial_use": info.commercial_use,
                    "runtimes": "runtime" in inspect.signature(cls).parameters})
    return out


def _load(target: str) -> type[Tracker]:
    module, attr = target.split(":")
    return getattr(import_module(module), attr)
