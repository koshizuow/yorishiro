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
	cargo build --release -p katashiro-gd -p yorishiro-tracking-gd -p yorishiro-pipewire-gd -p yorishiro-virtualcamera-gd --features yorishiro-tracking-gd/ncnn --manifest-path $PROJ_ROOT/../Cargo.toml
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

## Yorishiro's tracking core as a Godot node (crates/tracking-gd), with ncnn (Vulkan) beside it; the CPU path (tract)
## is built into the node
build_core () {
	echo -e "\n#### Preparing yorishiro-tracking\n\n"

	ADDON=$PROJ_ROOT/addons/yorishiro_tracking
	build_workspace || return 1
	mkdir -p $ADDON/lib
	cp $PROJ_ROOT/../target/release/libyorishiro_tracking_gd.so $ADDON/lib/libyorishiro_tracking_gd.x86_64.so
	cp -L $NCNN_DIR/lib/libncnn.so.1 $ADDON/lib/  # found through the node library's $ORIGIN rpath
	[ -f $NCNN_DIR/LICENSE.txt ] && cp $NCNN_DIR/LICENSE.txt $PROJ_ROOT/license/LICENSE.ncnn.md
	rm -f $ADDON/lib/libonnxruntime.so.*  # ONNX Runtime before tract (2026-11-18)
	cat > $ADDON/yorishiro_tracking.gdextension <<GDEXT
[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = 4.7
reloadable = false

[libraries]
linux.debug.x86_64 = "res://addons/yorishiro_tracking/lib/libyorishiro_tracking_gd.x86_64.so"
linux.release.x86_64 = "res://addons/yorishiro_tracking/lib/libyorishiro_tracking_gd.x86_64.so"

[dependencies]
linux.x86_64 = {
	"res://addons/yorishiro_tracking/lib/libncnn.so.1": ""
}
GDEXT
	echo "*" > $ADDON/.gitignore
	find $ADDON -type f

	cd $PROJ_ROOT
}

## Sending the stage to OBS over PipeWire (crates/pipewire-gd with libfunnel, needs libpipewire-0.3-dev 1.4+,
## libgbm-dev, libdrm-dev, libvulkan-dev)
build_pipewire () {
	echo -e "\n#### Preparing yorishiro-pipewire\n\n"

	ADDON=$PROJ_ROOT/addons/yorishiro_pipewire
	build_workspace || return 1
	mkdir -p $ADDON/lib
	cp $PROJ_ROOT/../target/release/libyorishiro_pipewire_gd.so $ADDON/lib/libyorishiro_pipewire_gd.x86_64.so
	cat > $ADDON/yorishiro_pipewire.gdextension <<'GDEXT'
[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = 4.7
reloadable = false

[libraries]
linux.debug.x86_64 = "res://addons/yorishiro_pipewire/lib/libyorishiro_pipewire_gd.x86_64.so"
linux.release.x86_64 = "res://addons/yorishiro_pipewire/lib/libyorishiro_pipewire_gd.x86_64.so"
GDEXT
	echo "*" > $ADDON/.gitignore
	find $ADDON -type f

	cd $PROJ_ROOT
}

build_virtualcamera () {
	echo -e "\n#### Preparing yorishiro-virtualcamera\n\n"

	ADDON=$PROJ_ROOT/addons/virtualcamera
	build_workspace || return 1
	mkdir -p $ADDON/lib
	cp $PROJ_ROOT/../target/release/libgd_virtualcamera.so $ADDON/lib/libgd_virtualcamera.release.so
	cat > $ADDON/virtualcamera.gdextension <<'GDEXT'
[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = 4.7
reloadable = false

[libraries]
linux.debug.x86_64 = "res://addons/virtualcamera/lib/libgd_virtualcamera.release.so"
linux.release.x86_64 = "res://addons/virtualcamera/lib/libgd_virtualcamera.release.so"
GDEXT
	cp $PROJ_ROOT/../crates/virtualcamera-gd/LICENSE.md $PROJ_ROOT/license/LICENSE.gdvirtualcamera.md
	echo "*" > $ADDON/.gitignore
	find $ADDON -type f

	cd $PROJ_ROOT
}

build_keylogger() {
	echo -e "\n#### Preparing godot-keylogger\n\n"

	WORKDIR=$PROJ_ROOT/../crates/keylogger-gd
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
build_pipewire
if [ "$BUILD_VIRTUALCAMERA" = 1 ]; then
	build_virtualcamera
fi
if [ "$BUILD_KEYLOGGER" = 1 ]; then
	build_keylogger
fi
