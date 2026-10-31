#!/bin/bash
# Runs the app's automation checks one after another with the replay tracker (crema-d-60) and prints one
# line per check: ok, FAILED, or the measured values. Shots and logs go to $1 (default a temp dir).
# The profile is restored afterwards, the checks change settings on purpose.
#   tools/app_tests.sh [out dir]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$(mktemp -d /tmp/yorishiro-tests.XXXX)}
mkdir -p "$OUT"
export YORISHIRO_TRACKER=$ROOT/tools/replay_tracker.sh
PROFILE=$ROOT/userdata/yorishiro/default_profile.json
cp "$PROFILE" "$OUT/profile.bak"
HIYORI=$ROOT/userdata/yorishiro/Live2DModels/hiyori_free/hiyori_free_t08.model3.json
PRO=$ROOT/userdata/yorishiro/Live2DModels/hiyori_pro/hiyori_pro_t11.model3.json
fail=0

run() {  # name, model, app options...
  local name=$1 model=$2
  shift 2
  timeout 400 "$ROOT/run.sh" --disable-vsync -- --model="$model" "$@" --wait-frames=90 --quit > "$OUT/$name.log" 2>&1
  local code=$?
  local lines
  lines=$(grep -E "^\[automation\] (.*: ok|.*FAILED|eye test|cycle |gesture|hotkey|expression|playing)" "$OUT/$name.log" | grep -v "window screenshot")
  echo "== $name (exit $code)"
  echo "$lines" | sed 's/^\[automation\] /   /' | head -40
  grep -E "SCRIPT ERROR" -A2 "$OUT/$name.log" | head -6
  if [ $code -ne 0 ] || echo "$lines" | grep -q FAILED || grep -q "SCRIPT ERROR" "$OUT/$name.log"; then
    fail=$((fail + 1))
  fi
}

run gestures "$HIYORI" --gestures="$OUT/gest" --screenshot="$OUT/gestures.png"
run hotkeys "$HIYORI" --open-panel=hotkeys --hotkey-test="$OUT/hk" --screenshot-window="$OUT/hotkeys.png"
run sensitivity "$HIYORI" --open-panel=sensitivity --sensitivity-test=ParamAngleX --screenshot-window="$OUT/sens.png"
run calibration "$HIYORI" --open-panel=sensitivity --calibration-test --screenshot-window="$OUT/cal.png"
run eyes "$HIYORI" --eye-test --screenshot-window="$OUT/eyes.png"
run cycle "$HIYORI" --cycle-models="$OUT/cycle" --pose-frames=40 --screenshot-window="$OUT/cycle.png"
run pose3 "$PRO" --play-motion=hiyori_m06.motion3.json --screenshot="$OUT/pose3.png"
run subpage "$HIYORI" --open-panel=model --press=Settings --screenshot-window="$OUT/subpage.png"
run pipewire "$HIYORI" --open-panel=settings --press=PipeWireToggle --show=PipeWireToggle --screenshot-window="$OUT/pipewire.png"
cp "$OUT/profile.bak" "$PROFILE"
echo "== $fail failing, shots and logs in $OUT"
exit $((fail > 0))
