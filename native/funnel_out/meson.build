# yorishiro-funnel, the stage as a PipeWire video stream (D34). libfunnel (MIT, thirdparty/libfunnel) is
# compiled in. PipeWire 1.4+ client headers are needed (libfunnel's minimum); point PKG_CONFIG_PATH at a newer
# PipeWire when the distro's is older (build.sh does that for PIPEWIRE_PREFIX).
project('yorishiro-funnel', 'c', meson_version: '>=1.1', default_options: ['c_std=gnu11', 'warning_level=1'])

funnel_dir = '../../thirdparty/libfunnel'
deps = [
  dependency('libpipewire-0.3', version: '>=1.4'),
  dependency('gbm'),
  dependency('libdrm'),
  dependency('egl'),
  dependency('gl'),
  dependency('x11'),
]
executable('yorishiro-funnel',
  'yorishiro-funnel.c',
  funnel_dir / 'src/funnel.c',
  funnel_dir / 'src/egl.c',
  include_directories: include_directories(funnel_dir / 'include'),
  dependencies: deps)
