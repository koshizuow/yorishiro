# libfunnel Documentation {#mainpage}

libfunnel is a library to make creating PipeWire video streams easy, using zero-copy DMA-BUF frame sharing. "Spout2 / Syphon, but for Linux".

## Getting started

See the \ref overview for an overview of the API and the concepts behind libfunnel.

## API documentation

- @ref funnel.h "<funnel/funnel.h>" The core API used by all backends
- @ref funnel-gbm.h "<funnel/funnel-gbm.h>" Raw GBM buffer API
- @ref funnel-vk.h "<funnel/funnel-vk.h>" Vulkan API integration
- @ref funnel-egl.h "<funnel/funnel-egl.h>" EGL API integration
