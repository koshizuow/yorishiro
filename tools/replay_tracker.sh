#!/bin/sh
# Test stand-in for yorishiro-tracker: same CLI, but serve replays a recording instead of a camera.
# YORISHIRO_RECORDING picks the recording, otherwise the newest one under $YORISHIRO_DATA/recordings
# (default tracker/data/recordings).
T=$(cd "$(dirname "$0")/../tracker" && pwd)
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
  exec "$T/.venv/bin/yorishiro-tracker" "$@" --replay "${REC%/}" --loop
fi
exec "$T/.venv/bin/yorishiro-tracker" "$@"
