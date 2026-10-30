#!/bin/sh
# Test stand-in for yorishiro-tracker: same CLI, but serve replays the golden recording instead of a camera.
T=$(cd "$(dirname "$0")/../tracker" && pwd)
if [ "$1" = "serve" ]; then
  exec "$T/.venv/bin/yorishiro-tracker" "$@" --replay "$T/data/recordings/20261029-105439" --loop
fi
exec "$T/.venv/bin/yorishiro-tracker" "$@"
