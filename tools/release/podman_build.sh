#!/bin/bash
# Builds a release in the release container with podman, then checks the AppImage on a stock Ubuntu 24.04.
#   MODELS_DIR=<models> tools/release/podman_build.sh <ref> [version]
# <ref>: a tag, a commit or origin/<branch> of REPO (default the GitHub repository). Only committed code is
# built: the ref is checked out in BUILD_DIR/src (default ~/yorishiro-build) and everything untracked except
# the build caches (target/) is removed first. The output goes to BUILD_DIR/out. Nothing is uploaded.
# CARGO_BUILD_JOBS limits the compile jobs and MEMORY (e.g. 1500m) caps the build container on machines with
# little memory.
set -euo pipefail
REF=${1:?usage: podman_build.sh <ref> [version]}
BUILD_DIR=${BUILD_DIR:-$HOME/yorishiro-build}
REPO=${REPO:-https://github.com/koshizuow/yorishiro.git}
MODELS=$(realpath "${MODELS_DIR:?MODELS_DIR: the tracking models listed in models/SHA256SUMS}")
IMAGE=yorishiro-release
src=$BUILD_DIR/src
out=$BUILD_DIR/out

[ -d "$src/.git" ] || git clone -q "$REPO" "$src"
git -C "$src" fetch -q --tags --force "$REPO" "+refs/heads/*:refs/remotes/origin/*"
git -C "$src" checkout -q --detach "$REF"
git -C "$src" submodule update -q --init
git -C "$src" clean -q -ffdx -e target/
git -C "$src" submodule foreach -q git clean -q -ffdx -e target/
VERSION=${2:-$(git -C "$src" describe --tags --always)}
echo "== $REF ($(git -C "$src" rev-parse --short HEAD)) as $VERSION"

podman build -q -t "$IMAGE" "$src/tools/release" > /dev/null
mkdir -p "$BUILD_DIR/cache/cargo-registry" "$out"
podman run --rm ${MEMORY:+--memory=$MEMORY} \
	-v "$src:/build/src" -v "$MODELS:/build/models:ro" -v "$BUILD_DIR/cache:/build/cache" \
	-v "$BUILD_DIR/cache/cargo-registry:/opt/cargo/registry" -v "$out:/build/out" \
	-e MODELS_DIR=/build/models -e CACHE_DIR=/build/cache -e OUT_DIR=/build/out \
	${CARGO_BUILD_JOBS:+-e CARGO_BUILD_JOBS=$CARGO_BUILD_JOBS} \
	"$IMAGE" /build/src/tools/release/build.sh "$VERSION"

# a stock Ubuntu 24.04 (PipeWire 1.0): every addon loads except the PipeWire output, which needs 1.4
echo "== stock Ubuntu 24.04"
log=$out/check-$VERSION.log
podman run --rm -v "$out:/out:ro" -e APPIMAGE_EXTRACT_AND_RUN=1 docker.io/library/ubuntu:24.04 \
	sh -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends libpipewire-0.3-0t64 libvulkan1 libgbm1 libinput10 libfontconfig1 > /dev/null 2>&1
		cd /tmp && /out/Yorishiro-$VERSION-x86_64.AppImage --headless --quit" > "$log" 2>&1 || true
failed=$(grep -o 'res://addons/[a-z_]*' <(grep -i "can't open dynamic library\|GDExtension dynamic library not found" "$log") | sort -u | tr "\n" " " || true)
echo "addons that did not load: ${failed:-none}"
[ "$failed" = "res://addons/yorishiro_pipewire " ] || { echo "expected only the PipeWire output to fail, see $log"; exit 1; }
echo "ok, release files in $out"
