#!/bin/bash
# Builds the Godot editor Yorishiro runs on: an official Godot source with the custom blend modes patch
# (godotengine/godot#116686, which Ayagami needs) applied, instead of waiting for AyagamiDev's build.
#   tools/build_godot.sh <version or commit> <patch> <work dir> [scons options...]
#   e.g. tools/build_godot.sh 4.7.2-stable app/thirdparty/ayagami/patches/custom_blend_modes-4_7_1.patch ../godot-build
# A version is a tag (4.7.2-stable); a pre-release is the commit its godot-builds release names, with
# GODOT_VERSION_STATUS set (e.g. beta2) so the build calls itself that.
# Needs gcc or clang and Python 3; SCons and zstandard go into <work dir>/.venv (uv). Without wayland-scanner
# (Ubuntu: libwayland-bin) the build has X11 only. Takes about 35 to 45 minutes on 6 jobs of a 4 core i3.
# The editor lands in <work dir>/src-<version>/bin/ with its debug symbols beside it (for gdb and perf).
set -euo pipefail
VERSION=$1
PATCH=$(realpath "$2")
WORK=$(realpath -m "$3")
shift 3
SRC="$WORK/src-$VERSION"
mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
	git init -q "$SRC"
	git -C "$SRC" remote add origin https://github.com/godotengine/godot.git
	if [[ "$VERSION" =~ ^[0-9a-f]{40}$ ]]; then
		git -C "$SRC" fetch -q --depth 1 origin "$VERSION"
	else
		git -C "$SRC" fetch -q --depth 1 origin "refs/tags/$VERSION:refs/tags/$VERSION"
	fi
	git -C "$SRC" checkout -q FETCH_HEAD 2>/dev/null || git -C "$SRC" checkout -q "$VERSION"
	git -C "$SRC" apply "$PATCH"
fi
if [ ! -x "$WORK/.venv/bin/scons" ]; then
	uv venv -q --python 3.12 "$WORK/.venv"
	uv pip install -q --python "$WORK/.venv/bin/python" scons zstandard
fi
cd "$SRC"
nice -n 10 "$WORK/.venv/bin/scons" platform=linuxbsd target=editor debug_symbols=yes separate_debug_symbols=yes \
	accesskit=no -j"$(( $(nproc) - 2 ))" "$@"
ls -la bin/
