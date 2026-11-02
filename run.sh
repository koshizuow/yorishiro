#!/bin/sh
# Run the Yorishiro app from source. Everything it writes (models, settings, logs, caches)
# stays inside the repo under userdata/yorishiro, not in ~/.local/share.
# GODOT overrides the engine path. Extra arguments go to Godot, put app options after "--".
set -e
ROOT=$(cd "$(dirname "$0")" && pwd)
# Default: the newest official Godot editor in ../tools/godot/, else a build from tools/build_godot.sh there
GODOT=${GODOT:-$(ls "$ROOT"/../tools/godot/Godot_v*_linux.x86_64 2>/dev/null | sort -V | tail -1)}
GODOT=${GODOT:-"$ROOT/../tools/godot/godot.linuxbsd.editor.x86_64.llvm"}
# YORISHIRO_USERDATA: another data folder, so tests do not change (or depend on) the development settings
export XDG_DATA_HOME="${YORISHIRO_USERDATA:-$ROOT/userdata}"
# Under a zh_TW locale with many fonts installed, Godot's per-frame system font fallback lookup
# took about 80 ms in fontconfig (app at 10 fps on the i3 desktop). The fontconfig language only
# orders candidates, fallback still goes by the characters, so CJK text keeps rendering.
export FC_LANG=${FC_LANG:-en}
mkdir -p "$XDG_DATA_HOME/yorishiro/Live2DModels"
# --instance=N: another copy of the app (several people on one computer), with its own settings folder. The model, item
# and background libraries stay the first copy's. lib/instance.gd has the rest.
# Without the option a copy takes the lowest free number, held by a lock while it runs, so opening the app twice works.
instance_setup() {
	base=${XDG_DATA_HOME:-$HOME/.local/share}
	mkdir -p "$base/yorishiro-instances"
	wanted=$1
	[ "$wanted" -gt 0 ] 2>/dev/null || { wanted=0; set -- 1; }
	if command -v flock > /dev/null; then
		while :; do
			exec 9> "$base/yorishiro-instances/$1.lock"
			if flock -n 9 || [ "$wanted" -gt 0 ]; then break; fi
			exec 9>&-
			set -- $(($1 + 1))
		done
	fi
	[ "$1" -gt 1 ] || return 0
	export YORISHIRO_INSTANCE=$1 XDG_DATA_HOME="$base/yorishiro-instances/$1"
	mkdir -p "$XDG_DATA_HOME/yorishiro" "$base/yorishiro/Live2DModels" "$base/yorishiro/Items" "$base/yorishiro/Backgrounds"
	for shared in Live2DModels Items Backgrounds; do
		ln -sfn "$base/yorishiro/$shared" "$XDG_DATA_HOME/yorishiro/$shared"
	done
}
n=0
for arg in "$@"; do
	case "$arg" in --instance=*) n=${arg#--instance=} ;; *) set -- "$@" "$arg" ;; esac
	shift
done
instance_setup "$n"
# Wayland when the session has it: Godot's default is X11, which under XWayland never gets the display scale.
# Chosen here rather than in project.godot, where an X11 session would log errors before falling back.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then set -- --display-driver wayland "$@"; fi
exec "$GODOT" --path "$ROOT/app" "$@"
