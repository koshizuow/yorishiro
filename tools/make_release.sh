#!/bin/bash
# Builds a Linux release of Yorishiro: the exported app with its native libraries, the tracking models, the
# licenses, as a folder, a tar.gz and an AppImage (D41).
#   tools/make_release.sh [version]          (default: git describe)
# Needs: the native addons built (app/build_dependencies.sh), the models in models/, and Godot's Linux release
# export template for this Godot version in <godot dir>/editor_data/export_templates/<version>.stable/
# (official, or built with scons target=template_release). GODOT picks the editor as run.sh does.
# Output in target/release/: yorishiro-<version>/ , yorishiro-<version>-linux-x86_64.tar.gz and
# Yorishiro-<version>-x86_64.AppImage. appimagetool is downloaded once into target/tools/.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:-$(git -C "$ROOT" describe --tags --always --dirty)}
GODOT=${GODOT:-$(ls -t "$ROOT"/../tools/godot/Godot_v* 2>/dev/null | head -1)}
OUT=$ROOT/target/release
NAME=yorishiro-$VERSION
DIR=$OUT/$NAME
APPIMAGETOOL_VERSION=1.9.0
APPIMAGETOOL_SHA256=46fdd785094c7f6e545b61afcfb0f3d98d8eab243f644b4b17698c01d06083d1

[ -x "$GODOT" ] || { echo "no Godot editor (GODOT)"; exit 1; }
ver=$("$GODOT" --version | sed 's/\.stable.*//')
template=$(dirname "$GODOT")/editor_data/export_templates/$ver.stable/linux_release.x86_64
[ -f "$template" ] || { echo "no release template at $template"; exit 1; }

rm -rf "${DIR:?}"
mkdir -p "$DIR"
"$GODOT" --headless --path "$ROOT/app" --export-release linux "$DIR/yorishiro.x86_64" > "$OUT/export.log" 2>&1 || { tail -20 "$OUT/export.log"; exit 1; }

# the Rust libraries are built with debug info (for perf and gdb): not in a release
strip --strip-unneeded "$DIR"/*.so* "$DIR/yorishiro.x86_64"

# the models the tracking core loads (models/SHA256SUMS lists them), not the conversion leftovers
mkdir -p "$DIR/models"
(cd "$ROOT/models" && sha256sum -c --quiet SHA256SUMS && cp --parents README.md SHA256SUMS $(awk '{print $2}' SHA256SUMS) "$DIR/models/") \
	|| { echo "models/ does not match models/SHA256SUMS"; exit 1; }

mkdir -p "$DIR/licenses"
cp "$ROOT/NOTICE" "$ROOT/README.md" "$DIR/"
cp "$ROOT/app/LICENSE.txt" "$DIR/licenses/LICENSE.app.txt"
cp "$ROOT/crates/tracking/LICENSE" "$DIR/licenses/LICENSE.tracking.txt"
cp "$ROOT"/app/license/* "$DIR/licenses/"

(cd "$OUT" && tar czf "$NAME-linux-x86_64.tar.gz" "$NAME")

# AppImage: the release folder as usr/bin, run from there so the app finds models/ beside it
tool=$ROOT/target/tools/appimagetool-$APPIMAGETOOL_VERSION-x86_64.AppImage
if [ ! -x "$tool" ]; then
	mkdir -p "$(dirname "$tool")"
	curl -sSLf -o "$tool.part" "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-x86_64.AppImage"
	echo "$APPIMAGETOOL_SHA256  $tool.part" | sha256sum -c --quiet
	chmod +x "$tool.part" && mv "$tool.part" "$tool"
fi
appdir=$OUT/Yorishiro.AppDir
rm -rf "${appdir:?}"
mkdir -p "$appdir/usr"
cp -a "$DIR" "$appdir/usr/bin"
cp "$ROOT/app/branding/icon.svg" "$appdir/yorishiro.svg"
cat > "$appdir/yorishiro.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Yorishiro
Comment=Live2D VTuber app with face tracking
Exec=yorishiro
Icon=yorishiro
Categories=AudioVideo;Video;
EOF
# as run.sh: Wayland when the session has it (display scale), FC_LANG=en (a CJK locale made Godot's per-frame font
# fallback take about 80 ms)
cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
export FC_LANG="${FC_LANG:-en}"
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
if [ -n "$WAYLAND_DISPLAY" ]; then set -- --display-driver wayland "$@"; fi
exec "$(dirname "$(readlink -f "$0")")/usr/bin/yorishiro.x86_64" "$@"
EOF
chmod +x "$appdir/AppRun"
ARCH=x86_64 "$tool" --appimage-extract-and-run -n "$appdir" "$OUT/Yorishiro-$VERSION-x86_64.AppImage" > "$OUT/appimage.log" 2>&1 \
	|| { tail -20 "$OUT/appimage.log"; exit 1; }
ls -la "$OUT" | grep -E "$NAME|AppImage"
