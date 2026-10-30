#!/bin/sh
# Test stand-in for yorishiro-tracker: same CLI, but serve replays a recording instead of a camera.
# YORISHIRO_RECORDING picks the recording, otherwise the newest one under $YORISHIRO_DATA/recordings
# (default tracker/data/recordings).
T=$(cd "$(dirname "$0")/../tracker" && pwd)
# same env choice as the app: the NVIDIA one when it exists
V=$T/.venv; [ -x "$T/.venv-nvidia/bin/yorishiro-tracker" ] && V=$T/.venv-nvidia
if [ "$1" = "serve" ]; then
  REC=${YORISHIRO_RECORDING:-}
  if [ -z "$REC" ]; then
    # glob order is name order, recordings are named by timestamp
    for d in "${YORISHIRO_DATA:-$T/data}"/recordings/*/; do
      [ -f "$d/meta.json" ] && REC=$d
    done
  fi
  if [ -z "$REC" ] || [ ! -f "$REC/meta.json" ]; then
    echo "replay_tracker: no recording found, set YORISHIRO_RECORDING or YORISHIRO_DATA" >&2
    exit 2
  fi
  exec "$V/bin/yorishiro-tracker" "$@" --replay "${REC%/}" --loop
fi
exec "$V/bin/yorishiro-tracker" "$@"
