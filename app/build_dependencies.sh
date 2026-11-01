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
	FEATURES=""
	if [ -n "$NCNN_DIR" ]; then
		FEATURES="--features yorishiro-core-gd/ncnn"
	fi
	cargo build --release -p katashiro-gd -p yorishiro-core-gd $FEATURES --manifest-path $PROJ_ROOT/../Cargo.toml
}

## Katashiro: our fork of Ayagami's Godot bindings (ayagami-gd), the Live2D renderer
build_katashiro () {
	echo -e "\n#### Preparing katashiro-gd\n\n"

	WORKDIR=$PROJ_ROOT/thirdparty/katashiro
	ADDONDIR=$PROJ_ROOT/addons

	mkdir -p $ADDONDIR
	
	# release only: the .gdextension loads it for the editor too
	build_workspace || return 1
	cp $PROJ_ROOT/../target/release/libkatashiro_gd.so $WORKDIR/addons/katashiro/lib/libkatashiro_gd.release.x86_64.so
	cp -r $WORKDIR/addons/katashiro $ADDONDIR

	# MIT: Ayagami's copyright notice stays in the license with ours
	cp $WORKDIR/LICENSE.md $PROJ_ROOT/license/LICENSE.katashiro.md
	# the core crate, from ayagami: MIT or Apache-2.0, its copyright file and the MIT text
	cat $WORKDIR/core/COPYRIGHT - $WORKDIR/core/LICENSE-MIT <<< "" > $PROJ_ROOT/license/LICENSE.katashiro-core.md
	cp $WORKDIR/README.md $ADDONDIR/katashiro/README.md
	
	echo "*" > $ADDONDIR/katashiro/.gitignore
	
	# log completion
	find $ADDONDIR/katashiro -type f

	cd $PROJ_ROOT
}

## Yorishiro's tracking core as a Godot node (core/gd, Phase B4). With NCNN_DIR set (ncnn built with Vulkan and NCNN_SIMPLEOMP, so no libgomp to ship and no spinning workers),
## the landmark model can also run on ncnn; ONNX Runtime is loaded at run time from the tracker's venv.
build_core () {
	echo -e "\n#### Preparing yorishiro-core\n\n"

	ADDON=$PROJ_ROOT/addons/yorishiro_core
	build_workspace || return 1
	mkdir -p $ADDON/lib
	cp $PROJ_ROOT/../target/release/libyorishiro_core_gd.so $ADDON/lib/libyorishiro_core_gd.x86_64.so
	if [ -n "$NCNN_DIR" ]; then
		cp -L $NCNN_DIR/lib/libncnn.so.1 $ADDON/lib/  # found through the node library's $ORIGIN rpath
	fi
	cat > $ADDON/yorishiro_core.gdextension <<'GDEXT'
[configuration]
entry_symbol = "gdext_rust_init"
compatibility_minimum = 4.7
reloadable = false

[libraries]
linux.debug.x86_64 = "res://addons/yorishiro_core/lib/libyorishiro_core_gd.x86_64.so"
linux.release.x86_64 = "res://addons/yorishiro_core/lib/libyorishiro_core_gd.x86_64.so"
GDEXT
	echo "*" > $ADDON/.gitignore
	find $ADDON -type f

	cd $PROJ_ROOT
}

build_virtualcamera () {
	echo -e "\n#### Preparing gd-virtualcamera\n\n"

	WORKDIR=$PROJ_ROOT/thirdparty/gd-virtualcamera
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

	WORKDIR=$PROJ_ROOT/thirdparty/godot-keylogger
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
