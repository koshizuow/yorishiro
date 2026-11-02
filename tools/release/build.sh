#!/bin/bash
# Builds the Linux release inside the release environment (tools/release/Containerfile, or any Ubuntu 24.04 with
# the same packages): the native addons, the export with the official Godot, then tools/make_release.sh.
#   tools/release/build.sh <version>
# MODELS_DIR: the tracking models, checked against models/SHA256SUMS and copied into models/ (default models/)
# CACHE_DIR: Godot, ncnn and the other downloads kept between builds (default target/release-cache)
# OUT_DIR: where the AppImage, the tar.gz and SHA256SUMS go (default target/release)
# Does not start containers itself: tools/release/podman_build.sh runs it in one.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=${1:?usage: build.sh <version>}
MODELS=${MODELS_DIR:-$ROOT/models}
CACHE=${CACHE_DIR:-$ROOT/target/release-cache}
OUT=${OUT_DIR:-$ROOT/target/release}
GODOT_VERSION=4.7.2
GODOT_ZIP_SHA512=9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65
GODOT_TPZ_SHA512=ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079
GLIBC_MAX=2.39

echo "== models"
(cd "$MODELS" && sha256sum -c --quiet "$ROOT/models/SHA256SUMS") || { echo "the models do not match models/SHA256SUMS"; exit 1; }
if [ "$(realpath "$MODELS")" != "$ROOT/models" ]; then
	(cd "$MODELS" && cp --parents $(awk '{print $2}' "$ROOT/models/SHA256SUMS") "$ROOT/models/")
fi

# the official Godot editor and Linux release template, self-contained (_sc_) so the template sits beside it
echo "== Godot $GODOT_VERSION"
g=$CACHE/godot-$GODOT_VERSION
base=https://github.com/godotengine/godot-builds/releases/download/$GODOT_VERSION-stable
export GODOT=$g/Godot_v$GODOT_VERSION-stable_linux.x86_64
template=$g/editor_data/export_templates/$GODOT_VERSION.stable/linux_release.x86_64
mkdir -p "$g" "$CACHE/dl"
if [ ! -x "$GODOT" ]; then
	zip=$CACHE/dl/godot.zip
	curl -sSLf -o "$zip" "$base/Godot_v$GODOT_VERSION-stable_linux.x86_64.zip"
	echo "$GODOT_ZIP_SHA512  $zip" | sha512sum -c --quiet
	unzip -q -o "$zip" -d "$g" && rm "$zip"
	touch "$g/_sc_"
fi
if [ ! -f "$template" ]; then
	tpz=$CACHE/dl/templates.tpz  # 1.3 GB with every platform, only the Linux release template is kept
	curl -sSLf -o "$tpz" "$base/Godot_v$GODOT_VERSION-stable_export_templates.tpz"
	echo "$GODOT_TPZ_SHA512  $tpz" | sha512sum -c --quiet
	mkdir -p "$(dirname "$template")"
	unzip -p "$tpz" templates/linux_release.x86_64 > "$template.part" && chmod +x "$template.part" && mv "$template.part" "$template"
	rm "$tpz"
fi

echo "== native addons"
# make_release.sh strips the debug info anyway, without it rustc needs much less memory and time
export CARGO_PROFILE_RELEASE_DEBUG=0
export NCNN_DIR=$CACHE/ncnn-install
[ -f "$NCNN_DIR/lib/libncnn.so.1" ] || "$ROOT/tools/build_ncnn.sh" "$NCNN_DIR"
(cd "$ROOT/app" && ./build_dependencies.sh > "$CACHE/addons.log" 2>&1) || { tail -30 "$CACHE/addons.log"; exit 1; }

echo "== export"
# the first import logs missing caches, the second must be clean
"$GODOT" --headless --path "$ROOT/app" --import > /dev/null 2>&1 || true
"$GODOT" --headless --path "$ROOT/app" --import > "$CACHE/import.log" 2>&1 || { tail -30 "$CACHE/import.log"; exit 1; }
"$ROOT/tools/make_release.sh" "$VERSION"

echo "== glibc"
dir=$ROOT/target/release/yorishiro-$VERSION
need=$(find "$dir" -type f \( -name '*.so*' -o -name '*.x86_64' \) -exec objdump -T {} + 2>/dev/null \
	| grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)
echo "needs glibc $need (at most $GLIBC_MAX)"
[ "$(printf '%s\n%s\n' "$need" "$GLIBC_MAX" | sort -V | tail -1)" = "$GLIBC_MAX" ] || { echo "too new for Ubuntu 24.04"; exit 1; }

mkdir -p "$OUT"
files="yorishiro-$VERSION-linux-x86_64.tar.gz Yorishiro-$VERSION-x86_64.AppImage"
for f in $files; do
	[ "$(realpath "$OUT")" = "$ROOT/target/release" ] || cp "$ROOT/target/release/$f" "$OUT/"
done
(cd "$OUT" && sha256sum $files > "SHA256SUMS-$VERSION" && cat "SHA256SUMS-$VERSION")
