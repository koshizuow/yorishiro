#!/bin/sh
# Run the Yorishiro app from source. Everything it writes (models, settings, logs, caches)
# stays inside the repo under userdata/yorishiro, not in ~/.local/share.
# GODOT overrides the engine path. Extra arguments go to Godot, put app options after "--".
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
GODOT=${GODOT:-"$ROOT/../tools/godot/godot.linuxbsd.editor.x86_64.llvm"}
# YORISHIRO_USERDATA: another data folder, so tests do not change (or depend on) the development settings
export XDG_DATA_HOME="${YORISHIRO_USERDATA:-$ROOT/userdata}"
# Under a zh_TW locale with many fonts installed, Godot's per-frame system font fallback lookup
# took about 80 ms in fontconfig (app at 10 fps on the i3 desktop). The fontconfig language only
# orders candidates, fallback still goes by the characters, so CJK text keeps rendering.
export FC_LANG=${FC_LANG:-en}
mkdir -p "$XDG_DATA_HOME/yorishiro/Live2DModels"
exec "$GODOT" --path "$ROOT/app" "$@"
