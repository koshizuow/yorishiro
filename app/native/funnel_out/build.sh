#!/bin/sh
# Builds yorishiro-funnel into build/ (needs libpipewire-0.3-dev 1.4+). PIPEWIRE_PREFIX: a PipeWire 1.4+ install
# when the system's is older (Mint 22 ships 1.0.5; the development PC runs 1.6 from ppa:savoury1/pipewire).
set -e
cd "$(dirname "$0")"
if [ -n "${PIPEWIRE_PREFIX:-}" ]; then
  export PKG_CONFIG_PATH="$PIPEWIRE_PREFIX/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  LINK="-Dc_link_args=-Wl,-rpath,$PIPEWIRE_PREFIX/lib/x86_64-linux-gnu"
fi
[ -d build ] || meson setup build --buildtype=release ${LINK:-}
ninja -C build
