#!/bin/bash
# Builds a Godot editor from the official source with debug symbols, for perf and gdb (the app runs on the
# official builds, this is not needed to run it). An optional patch is applied first.
#   tools/build_godot.sh <version or commit> <work dir> [patch] [-- scons options...]
#   e.g. tools/build_godot.sh 4.7.2-stable ../godot-build
# A version is a tag (4.7.2-stable); a pre-release is the commit its godot-builds release names, with
# GODOT_VERSION_STATUS set (e.g. beta2) so the build calls itself that.
# Needs clang, lld and Python 3; SCons and zstandard go into <work dir>/.venv (uv). Without wayland-scanner
# (Ubuntu: libwayland-bin) the build has X11 only. Takes about 35 to 45 minutes on 6 jobs of a 4 core i3.
# The editor lands in <work dir>/src-<version>/bin/ with its debug symbols beside it (for gdb and perf).
set -euo pipefail
VERSION=$1
WORK=$(realpath -m "$2")
PATCH=
if [ $# -ge 3 ] && [ "$3" != "--" ]; then PATCH=$(realpath "$3"); shift; fi
shift 2
[ "${1:-}" = "--" ] && shift
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
	[ -z "$PATCH" ] || git -C "$SRC" apply "$PATCH"
fi
if [ ! -x "$WORK/.venv/bin/scons" ]; then
	uv venv -q --python 3.12 "$WORK/.venv"
	uv pip install -q --python "$WORK/.venv/bin/python" scons zstandard
fi
cd "$SRC"
# LLVM like the official builds (the binary gets the .llvm suffix run.sh looks for)
nice -n 10 "$WORK/.venv/bin/scons" platform=linuxbsd target=editor use_llvm=yes linker=lld debug_symbols=yes \
	separate_debug_symbols=yes accesskit=no -j"$(( $(nproc) - 2 ))" "$@"
ls -la bin/
