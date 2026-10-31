# API overview {#overview}

## Common concepts

Most libfunnel functions return an `int` result code. These result codes follow the same convention as PipeWire, the Linux kernel, and many other libraries, where a positive or zero value denotes success and a negative value denotes an `errno` error value. You should always check the return value for errors, as failure to do so may lead to bugs and undefined behavior. Common error codes are documented, but some functions may return other error codes (for example, forwarded from PipeWire).

To safely use the API, especially if you are creating multiple streams or using multithreading, you must follow the \ref usagerules.

## Creating a context

To use libfunnel, you will first create a funnel_ctx. This is your connection to the PipeWire daemon, and also spawns a background processing thread to handle PipeWire events.

You will typically have a single context for a single app, though you can have as many as you want (and they will be completely independent from each other).

If context creation fails, that means that libfunnel was unable to connect to PipeWire.

~~~{.c}
    struct funnel_ctx *ctx;

    ret = funnel_init(&ctx);
    assert(ret == 0);
~~~

## Creating a stream

Once you have a context, you can create a video stream. Streams must, at minimum, have some kind of user-friendly name. The name should uniquely identify the stream in some way within your app. 

Neither libfunnel nor PipeWire enforce name uniqueness, but using the same name multiple times will make it very difficult for users to identify and connect to a given stream, so this should be avoided.

~~~{.c}
    struct funnel_stream *stream;

    ret = funnel_stream_create(ctx, "Funnel Test", &stream);
    assert(ret == 0);
~~~

After creation, a stream is *unconfigured*. It must be further initialized, configured, and started before it can be used.

## API selection

After creating a stream, you must select which graphics API to use. This configures libfunnel to integrate with your graphics context, so it can create the right kind of buffers and objects that you can then use to render and send frames to the stream.

> [!note]
> Although many applications will use the same API context (Vulkan, EGL, etc.) for multiple streams, libfunnel supports using a separate context for each stream. For this reason, the API must be set for each stream you create.

See the \ref apis section for information on specific graphics APIs. Once you bind an API instance to a stream, this cannot be changed without destroying and re-creating the stream.

~~~{.c}
    ret = funnel_stream_init_egl(stream, egl_display);
    assert(ret == 0);
~~~

## Configuring the stream

Before the stream can be started, you must set certain properties on the stream. At minimum, you must set the frame dimensions:

~~~{.c}
    ret = funnel_stream_set_size(stream, width, height);
    assert(ret == 0);
~~~

You must also configure the supported pixel formats. How this is done depends on the chosen API, which is described in the \ref apis section. You should also read the \ref colorformats section to understand how to correctly render/format video frames (color formats, alpha, etc.). 

The formats are specified in priority order, from most preferred to least preferred. PipeWire will negotiate the best possible format based on what both sides support.

For example, for EGL, you might do:

~~~{.c}
    ret = funnel_stream_egl_add_format(stream, FUNNEL_EGL_FORMAT_RGBA8888);
    assert(ret == 0);
    ret = funnel_stream_egl_add_format(stream, FUNNEL_EGL_FORMAT_RGB888);
    assert(ret == 0);
~~~

Next, you should set the frame timing mode for the stream according to how you intend to submit frames to it. See funnel_mode for an explanation of the different modes.

In general, if you are adding stream output support to a graphical application that already renders frames at the screen refresh rate or on some other timer (and you intend to continue to do so), you should use #FUNNEL_ASYNC, which is also the default.

The other modes are intended for applications that can (optionally) synchronize to the frame rate of the consumer, to avoid dropped/duplicated frames. For example, if you are rendering video that will typically be sent to OBS for streaming, you could use #FUNNEL_DOUBLE_BUFFERED to synchronize to the OBS frame rate instead. In this case, you must *not* synchronize to the screen refresh rate too, to avoid double synchronization.

> [!warning]
> Synchronizing to the consumer in graphical apps has lots of subtleties to avoid locking up your UI, and the libfunnel API does not fully support this well. For now, if you are adding libfunnel to a graphical app, please use #FUNNEL_ASYNC.

~~~{.c}
    ret = funnel_stream_set_mode(stream, FUNNEL_ASYNC);
    assert(ret == 0);
~~~

You might also want to configure the buffer synchronization mode. See the \ref buffersync section for mode details.

TL;DR if you use OpenGL and you want to support Nvidia users, do this:

~~~{.c}
    ret = funnel_stream_set_sync(stream, FUNNEL_SYNC_BOTH, FUNNEL_SYNC_BOTH);
    assert(ret == 0);
~~~

You may also optionally set the frame rate of the stream. In #FUNNEL_ASYNC mode, this is mostly just informational. In the other modes, this affects the negotiated frame rate, and if the consumer is not driving the frame rate itself, will affect the actual rate at which frames are produced.

The frame rate has three values: The default rate, the minimum rate, and the maximum rate.

~~~{.c}
    ret =
        funnel_stream_set_rate(stream, FUNNEL_RATE_VARIABLE,
                               FUNNEL_RATE_VARIABLE, FUNNEL_FRACTION(1000, 1));
    assert(ret == 0);
~~~

Finally, call funnel_stream_configure() to apply the stream configuration. The first time you do this, the actual PipeWire stream will be created.

~~~{.c}
    ret = funnel_stream_configure(stream);
    assert(ret == 0);
~~~

## The streaming loop

Once you have configured your stream, you can start it and begin delivering frames to it. To start the stream, call:

~~~{.c}
    ret = funnel_stream_start(stream);
    assert(ret == 0);
~~~

Note that this only starts the stream *from the point of view of your application*. The stream will not actually be running and delivering frames until it is connected to by a consumer, the stream configuration is negotiated, and the consumer itself starts the stream. This is transparent to your application, and libfunnel will take care of handling stream state changes behind the scenes.

Once a stream is started, for every frame, you must *dequeue* a buffer from the stream, then *render* (or copy) to it, and finally *enqueue* the buffer to deliver it to the stream. This is your core streaming loop:

~~~{.c}
    while (keep_streaming) {
        struct funnel_buffer *buf;

        // Dequeue an empty buffer to render to
        ret = funnel_stream_dequeue(stream);
        assert(ret >= 0);
        if (ret != 1) {
            // No buffer is available
            continue;
        }
            
        // Render to the buffer here!

        // Enqueue the rendered buffer
        ret = funnel_stream_enqueue(stream, buf);
        assert(ret >= 0);
    }
~~~

Notice how the funnel_stream_dequeue() and funnel_stream_enqueue() functions return a flag, **0** or **1** (or negative on error). If funnel_stream_dequeue() returns **0**, that means that no buffer is available and you should skip the current frame (for example, render it to the screen only, or don't render it at all if your app has no display). If funnel_stream_enqueue() returns **0**, that means that the stream state changed (reconfigured, stopped, etc.) and the buffer was automatically discarded behind the scenes instead of enqueued. You don't have to do anything special for automatically discarded frames, this value is just informational. This design means that you largely do not need to worry about what happens to a stream, you can just keep asking for buffers and libfunnel will return one when one is available.

If you want to know what state the stream is in, you can call the funnel_stream_get_state() function. This should only be considered as a hint, since the stream state can change at any time! You can safely choose to skip frames if the stream is not running without calling funnel_stream_dequeue(), but since the stream may stop at any time, there is no guarantee that a frame will always be successfully dequeued if the stream is running.

Once funnel_stream_dequeue() returns a buffer, you **must** return it to libfunnel. If you are unable to render a frame to be enqueued, you **must** call funnel_stream_return() to return an unused buffer back to libfunnel. This will effectively "drop a frame" in the stream. Currently, you may only have one buffer dequeued at a time.

To stop a stream, call funnel_stream_stop():

~~~{.c}
    ret = funnel_stream_stop(stream);
    assert(ret == 0);
~~~

> [!note]
> A stopped stream cannot have any frames dequeued from it (funnel_stream_dequeue() will return an error code). This only applies when the stream is stopped *from the point of view of your application*.

If your stream is set to one of the synchronous modes (not #FUNNEL_ASYNC), then calling the stream queue functions (funnel_stream_enqueue() or funnel_stream_dequeue(), depending on the stream state and mode) will **block execution**. To unblock these calls from another thread, you can either stop the stream (funnel_stream_stop()), or request to skip a frame with funnel_stream_skip_frame(). Note that this function is a little bit of a misnomer: it will skip a frame from the point of view of your app (it will unblock the dequeue call), but it will not skip a frame in the stream itself.

## Stream reconfiguration {#reconfig}

What happens if you want to change the stream configuration at runtime, such as the dimensions? You can do this by triggering a reconfiguration:

~~~{.c}
    ret = funnel_stream_set_size(stream, new_width, new_height);
    assert(ret == 0);
    ret = funnel_stream_configure(stream);
    assert(ret == 0);
~~~

You can change all stream parameters dynamically this way. This can even be done from a different thread to the thread that is running the streaming loop (however, only a single thread can be actively modifying stream configuration settings at a time and you can't destroy a stream while other threads are using it, see \ref usagerules).

Stream configuration changes happen asynchronously, **even if you do everything from a single thread**. This means that even if you change the buffer dimensions or format, you might still get some buffers with the old settings! It's important to check the actual buffer parameters before rendering to it, like this:

~~~{.c}
    // Get the real buffer dimensions
    uint32_t actual_width, actual_height;
    funnel_buffer_get_size(buf, &actual_width, &actual_height);
~~~

If the dimensions aren't what you expect and you can't or don't want to render to such a buffer, then you should return it with funnel_stream_return() and continue on to the next loop cycle, until you start getting buffers with the newly configured dimensions.

## Cleanup and shutdown

To shut down and destroy a stream, call funnel_stream_destroy(). If you are using multiple threads, it's important to ensure that no other threads are using the stream before destroying it (for example, by joining those threads or otherwise synchronizing with them). If a buffer was dequeued and not yet enqueued, it must be returned with funnel_stream_return() before destroying the owning stream.

Once you have destroyed all your streams, you should shut down the libfunnel context with funnel_shutdown(). This will disconnect from PipeWire.

## Rendering buffers

Once you have dequeued a funnel_buffer, you can obtain the API-specific handles you need to render or copy to it. To learn more about the expected pixel/color format and how to correctly handle transparency, see the \ref colorformats section. To learn about how to synchronize GPU operations correctly, see the \ref buffersync section.

TODO: Document API-specific rendering flows more explicitly. See \ref apis for links to the header files and example code for now.

## API integration {#apis}

Libfunnel integrates with different graphics APIs.

### GBM

This is the "raw" low-level API that is used internally by libfunnel to implement integration with the higher-level APIs. You could use this to add support for a non-OpenGL and non-Vulkan API, or to do things like send frames directly from a hardware video capture device to a PipeWire stream without passing through a real GPU.

The GBM API is documented in the funnel-gbm.h header file.

> [!note]
> Libfunnel requires driver GBM support regardless of the actualy API in use. For Nvidia proprietary driver users, this means that the `nvidia-drm` module must be loaded with the `modeset=1` option.

### EGL

EGL is the modern integration layer for OpenGL on Linux. You can use EGL with X11, Wayland, headless (surfaceless), or with other integrations such as raw DRM devices.

The libfunnel EGL API is documented in the funnel-egl.h header file. See @ref test-egl.c for example usage.

### GLX

GLX is the legacy OpenGL integration API for X11 on Linux. **libfunnel does not currently support GLX**. If you are using GLX, you must migrate to EGL to use libfunnel. GLX/EGL is only used to set up the OpenGL context, so this will not affect most of your rendering code, only the initialization portion.

### Vulkan

Vulkan is a modern low-level cross-platform graphics API.

The libfunnel Vulkan API is documented in the funnel-vk.h header file. See @ref test-vk.c for example usage.
