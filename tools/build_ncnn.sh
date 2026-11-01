#!/bin/sh
# Builds ncnn (BSD-3-Clause) with Vulkan for the tracking core, the GPU path on any graphics card.
#   tools/build_ncnn.sh [install dir]   (default target/ncnn-install; the source goes to target/ncnn-src)
# SIMPLEOMP: ncnn's own small OpenMP, so there is no libgomp to ship and no workers spinning between frames.
# SIMPLEVK: Vulkan is loaded at run time, no Vulkan SDK needed to build. Needs cmake, ninja and git; takes
# about 10 minutes on a 4 core i3.
set -eu
VERSION=20261020
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=$(realpath -m "${1:-$ROOT/target/ncnn-install}")
SRC=$ROOT/target/ncnn-src
if [ ! -d "$SRC/.git" ]; then
	git clone -q --depth 1 --branch "$VERSION" https://github.com/Tencent/ncnn.git "$SRC"
	git -C "$SRC" submodule update -q --init --depth 1 glslang
fi
cmake -S "$SRC" -B "$SRC/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
	-DNCNN_VULKAN=ON -DNCNN_SIMPLEVK=ON -DNCNN_SHARED_LIB=ON -DNCNN_OPENMP=ON -DNCNN_SIMPLEOMP=ON \
	-DNCNN_BUILD_TOOLS=OFF -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF > /dev/null
nice -n 10 cmake --build "$SRC/build" -j"$(( $(nproc) > 2 ? $(nproc) - 1 : 1 ))"
cmake --install "$SRC/build" > /dev/null
cp "$SRC/LICENSE.txt" "$PREFIX/LICENSE.txt"
echo "ncnn $VERSION in $PREFIX"
