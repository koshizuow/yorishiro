#!/bin/sh
# Builds yorishiro-funnel into build/. PIPEWIRE_PREFIX: a PipeWire 1.4+ install when the system's is older
# (this PC: Mint 22 ships 1.0.5, the client was built into /media/koshizu/Work/dev/external/pw16-prefix).
set -e
cd "$(dirname "$0")"
if [ -n "${PIPEWIRE_PREFIX:-}" ]; then
  export PKG_CONFIG_PATH="$PIPEWIRE_PREFIX/lib/x86_64-linux-gnu/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  LINK="-Dc_link_args=-Wl,-rpath,$PIPEWIRE_PREFIX/lib/x86_64-linux-gnu"
fi
[ -d build ] || meson setup build --buildtype=release ${LINK:-}
ninja -C build
