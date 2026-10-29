# Source this to run facecap with --runtime npu inside a Ryzen AI 1.8 venv on Ubuntu with distro XRT
# (libxrt-npu2). Needs RLIMIT_MEMLOCK unlimited, check with `ulimit -l`.
#   source ~/ryzen-ai-venv/bin/activate && source tools/ryzen_ai_env.sh

: "${XRT_SHIM:=$HOME/.cache/facecap/xrt-shim}"
: "${UV_PY312_LIB:=$(python -c 'import sys; print(sys.base_prefix)')/lib}"

# VitisAI EP loads $XILINX_XRT/lib/libxrt_core.so.2, distro XRT lives in the multiarch dir.
mkdir -p "$XRT_SHIM/lib"
for f in /usr/lib/x86_64-linux-gnu/libxrt*.so* /usr/lib/x86_64-linux-gnu/libxdp*.so*; do
    ln -sf "$f" "$XRT_SHIM/lib/$(basename "$f")"
done
export XILINX_XRT="$XRT_SHIM"
# Ryzen AI's onnxruntime .so requests an executable stack, glibc >= 2.41 refuses it by default.
export GLIBC_TUNABLES=glibc.rtld.execstack=2
# The bundled libxrt_coreutil 2.19 lacks symbols the distro libxrt_core 2.25 needs.
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libxrt_coreutil.so.2
# libflexmlrt links libpython3.12.so, which a uv-managed venv does not put on the search path.
export LD_LIBRARY_PATH="$UV_PY312_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
