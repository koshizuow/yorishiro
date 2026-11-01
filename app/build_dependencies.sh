#!/usr/bin/env bash
set -e

PROJ_ROOT=$(pwd)

ARCH="$(uname -m)"
PLATFORM="$(uname -s)"

case "$PLATFORM" in
	Darwin)
		ARCH="${ARCH/arm64/aarch64}"
		TARGET="${target:-$ARCH-apple-darwin}"
		BUILD_KEYLOGGER=1
		;;
	Linux)
		TARGET="${target:-$ARCH-unknown-linux-gnu}"
		BUILD_VIRTUALCAMERA=1
		BUILD_KEYLOGGER=1
		;;
esac


## Our Rust addons share one Cargo workspace (the repo root, outputs in its target/). Both are built in one cargo
## call: building one alone resolves godot-rust with other features and compiles it again.
build_workspace () {
	cargo build --release -p katashiro-gd -p yorishiro-tracking-gd --features yorishiro-tracking-gd/ncnn --manifest-path $PROJ_ROOT/../Cargo.toml
}

## ncnn with Vulkan, the tracking core's GPU path: NCNN_DIR (an install prefix), else built once by
## tools/build_ncnn.sh into target/ncnn-install
if [ -z "$NCNN_DIR" ]; then
	export NCNN_DIR=$PROJ_ROOT/../target/ncnn-install
	[ -f "$NCNN_DIR/lib/libncnn.so.1" ] || $PROJ_ROOT/../tools/build_ncnn.sh "$NCNN_DIR"
fi

## Katashiro: our fork of Ayagami's Godot bindings (ayagami-gd), the Live2D renderer
build_katashiro () {
	echo -e "\n#### Preparing katashiro-gd\n\n"

	WORKDIR=$PROJ_ROOT/../crates/katashiro-gd
	ADDONDIR=$PROJ_ROOT/addons

	mkdir -p $ADDONDIR
	
	# release only: the .gdextension loads it for the editor too
	build_workspace || return 1
	cp $PROJ_ROOT/../target/release/libkatashiro_gd.so $WORKDIR/addons/katashiro/lib/libkatashiro_gd.release.x86_64.so
	cp -r $WORKDIR/addons/katashiro $ADDONDIR

	# MIT: Ayagami's copyright notice stays in the license with ours
	cp $WORKDIR/LICENSE.md $PROJ_ROOT/license/LICENSE.katashiro.md
	# the core crate, from ayagami: MIT or Apache-2.0, its copyright file and the MIT text
	cat $WORKDIR/../katashiro/COPYRIGHT - $WORKDIR/../katashiro/LICENSE-MIT <<< "" > $PROJ_ROOT/license/LICENSE.katashiro-core.md
	cp $WORKDIR/README.md $ADDONDIR/katashiro/README.md
	
	echo "*" > $ADDONDIR/katashiro/.gitignore
	
	# log completion
	find $ADDONDIR/katashiro -type f

	cd $PROJ_ROOT
}

## ONNX Runtime's official CPU build (MIT), which the core loads at run time
ORT_VERSION=1.31.1
ORT_SHA256=c849e36a1ef3e22d4ff217b9d1ce4a3cf5b9467b975610913ae959ad5b16bdc9

fetch_onnxruntime () {
	local lib=$1/libonnxruntime.so.$ORT_VERSION
	[ -f "$lib" ] && return 0
	local name=onnxruntime-linux-x64-$ORT_VERSION
	local dl=$PROJ_ROOT/../target/onnxruntime
	mkdir -p $dl
	if [ ! -f $dl/$name.tgz ]; then
		curl -sSLf -o $dl/$name.tgz.part https://github.com/microsoft/onnxruntime/releases/download/v$ORT_VERSION/$name.tgz || return 1
		mv $dl/$name.tgz.part $dl/$name.tgz
	fi
	echo "$ORT_SHA256  $dl/$name.tgz" | sha256sum -c --quiet || return 1
	tar xzf $dl/$name.tgz -C $dl $name/lib/libonnxruntime.so.$ORT_VERSION $name/LICENSE $name/ThirdPartyNotices.txt
	cp $dl/$name/lib/libonnxruntime.so.$ORT_VERSION $lib
	cat $dl/$name/LICENSE - $dl/$name/ThirdPartyNotices.txt <<< "" > $PROJ_ROOT/license/LICENSE.onnxruntime.md
}

## Yorishiro's tracking core as a Godot node (crates/tracking-gd), with ncnn (Vulkan) and ONNX Runtime (CPU) beside it
build_core () {
	echo -e "\n#### Preparing yorishiro-tracking\n\n"

	ADDON=$PROJ_ROOT/addons/yorishiro_tracking
	build_workspace || return 1
	mkdir -p $ADDON/lib
	cp $PROJ_ROOT/../target/release/libyorishiro_tracking_gd.so $ADDON/lib/libyorishiro_tracking_gd.x86_64.so
	fetch_onnxruntime $ADDON/lib || return 1
	cp -L $NCNN_DIR/lib/libncnn.so.1 $ADDON/lib/  # found through the node library's $ORIGIN rpath
	[ -f $NCNN_DIR/LICENSE.txt ] && cp $NCNN_DIR/LICENSE.txt $PROJ_ROOT/license/LICENSE.ncnn.md
	cat > $ADDON/yorishiro_tracking.gdextension <<'GDEXT'
[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = 4.7
reloadable = false

[libraries]
linux.debug.x86_64 = "res://addons/yorishiro_tracking/lib/libyorishiro_tracking_gd.x86_64.so"
linux.release.x86_64 = "res://addons/yorishiro_tracking/lib/libyorishiro_tracking_gd.x86_64.so"
GDEXT
	echo "*" > $ADDON/.gitignore
	find $ADDON -type f

	cd $PROJ_ROOT
}

build_virtualcamera () {
	echo -e "\n#### Preparing gd-virtualcamera\n\n"

	WORKDIR=$PROJ_ROOT/../thirdparty/gd-virtualcamera
	ADDONDIR=$PROJ_ROOT/addons

	mkdir -p $ADDONDIR
	
	cd $WORKDIR
	
	make package
	cp -r $WORKDIR/addons/virtualcamera $ADDONDIR

	cp LICENSE.md $PROJ_ROOT/license/LICENSE.gdvirtualcamera.md
	cp README.md $ADDONDIR/virtualcamera/README.md
	echo "*" > $ADDONDIR/virtualcamera/.gitignore
	
	# log completion
	find $ADDONDIR/virtualcamera -type f

	cd $PROJ_ROOT
}

build_keylogger() {
	echo -e "\n#### Preparing godot-keylogger\n\n"

	WORKDIR=$PROJ_ROOT/../thirdparty/godot-keylogger
	ADDONDIR=$PROJ_ROOT/addons

	mkdir -p $ADDONDIR
	
	cd $WORKDIR
	
	make package
	cp -r $WORKDIR/addons/keylogger $ADDONDIR

	cp LICENSE.md $PROJ_ROOT/license/LICENSE.keylogger.md
	cp README.md $ADDONDIR/keylogger/README.md
	echo "*" > $ADDONDIR/keylogger/.gitignore
	
	# log completion
	find $ADDONDIR/keylogger -type f

	cd $PROJ_ROOT
}


# fetch submodules if they haven't been already
# git submodule update --init --recursive

build_katashiro
build_core
if [ "$BUILD_VIRTUALCAMERA" = 1 ]; then
	build_virtualcamera
fi
if [ "$BUILD_KEYLOGGER" = 1 ]; then
	build_keylogger
fi
