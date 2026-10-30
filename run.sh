#!/bin/sh
# Run the Yorishiro app from source. Everything it writes (models, settings, logs, caches)
# stays inside the repo under userdata/yorishiro, not in ~/.local/share.
# GODOT overrides the engine path. Extra arguments go to Godot, put app options after "--".
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
GODOT=${GODOT:-"$ROOT/../tools/godot/godot.linuxbsd.editor.x86_64.llvm"}
export XDG_DATA_HOME="$ROOT/userdata"
mkdir -p "$XDG_DATA_HOME/yorishiro/Live2DModels"
exec "$GODOT" --path "$ROOT/app" "$@"
