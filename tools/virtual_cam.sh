#!/bin/sh
# Development webcam: loops a recording (or any video file) into a v4l2loopback device, so the real
# camera path (V4L2 capture in the tracking core, the app's camera picker) runs without a webcam.
# Needs the v4l2loopback module loaded once per boot (sudo, user runs):
#   sudo modprobe v4l2loopback devices=1 video_nr=10 card_label="Yorishiro Dev Cam" exclusive_caps=1
# Usage: tools/virtual_cam.sh [recording dir | video file]   (VIRTUAL_CAM overrides /dev/video10)
# The source defaults to YORISHIRO_RECORDING, otherwise the last recording by name in the test data
# (YORISHIRO_TESTDATA, default ../testdata).
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV=${VIRTUAL_CAM:-/dev/video10}
SRC=${1:-${YORISHIRO_RECORDING:-}}
if [ -z "$SRC" ]; then
  for d in "${YORISHIRO_TESTDATA:-$ROOT/../testdata}"/recordings/*/; do
    [ -f "$d/meta.json" ] && SRC=$d
  done
fi
if [ ! -e "$DEV" ]; then
  echo "virtual_cam: $DEV missing, load v4l2loopback first (see the top of this script)" >&2
  exit 2
fi
if [ -z "$SRC" ] || [ ! -e "$SRC" ]; then
  echo "virtual_cam: no source, pass a recording dir or a video file" >&2
  exit 2
fi
if [ -d "$SRC" ]; then
  # recordings are numbered JPEG frames at about 16 fps (meta.json timestamps)
  set -- -framerate 16 -i "${SRC%/}/frames/%05d.jpg"
else
  set -- -i "$SRC"
fi
# YUYV 1280x720 is a format the core's V4L2 capture accepts from a loopback device
exec ffmpeg -nostdin -hide_banner -loglevel warning -stream_loop -1 -re "$@" \
  -vf scale=1280:720 -pix_fmt yuyv422 -f v4l2 "$DEV"
