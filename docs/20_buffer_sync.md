# Buffer synchronization {#buffersync}

GPUs require access to shared buffers to be synchronize, to ensure that a frame is fully written to memory before it is read. Without synchronization, an application might read incomplete frames or even garbage data.

While it is possible to do this using CPU synchronization (this is how Spout2 works on Windows), this is inefficient because it prevents GPU parallelism and forces CPU-GPU synchronization. Linux has two synchronization mechanisms:

* **Implicit sync**: GPU shared buffers are "magically" synchronized by the kernel and GPU drivers, and the only thing applications have to do is ensure that all GPU write operations are submitted (not completed!) for a given buffer before the corresponding GPU read operations are submitted. This supports OpenGL, which historically did not really do synchronization.

* **Explicit sync**: Applications must manually handle synchronization, explicitly declaring which GPU synchronization points must be reached before certain commands are processed. To share this information between applications, the kernel provides primitives such as *sync objects* and *sync files*.

PipeWire supports both mechanisms, allowing applications to negotiate the preferred synchronization style. OpenGL supports both implicit and explicit synchronization, while Vulkan requires explicit synchronization.

What happens if you write an app using Vulkan, and you want to send video to an app using OpenGL that only supports explicit sync? Thanfully, this is possible. libfunnel can use some [dark magic](https://www.collabora.com/news-and-blog/blog/2022/06/09/bridging-the-synchronization-gap-on-linux/) to convert between explicit and explicit synchronization and handle it for you.

For this reason, libfunnel has two settings for synchronization: The *frontend synchronization mode* (the sync style *you* use with the API) and the *backend synchronization mode* (the sync style that other apps see when they connect to your app through PipeWire). These two modes are configured using the funnel_stream_set_sync() function. The first argument specifies the frontend sync mode, and the second argument specifies the backend sync mode. Each mode can have one of these values:

* \ref FUNNEL_SYNC_IMPLICIT
* \ref FUNNEL_SYNC_EXPLICIT
* \ref FUNNEL_SYNC_BOTH

## This is too complicated, just tell me what to do

If you use Vulkan, the default (<tt>FUNNEL_SYNC_EXPLICIT, FUNNEL_SYNC_BOTH</tt>) is fine. If you use OpenGL, use <tt>FUNNEL_SYNC_BOTH, FUNNEL_SYNC_BOTH</tt> for maximum compatibility, and make sure to \ref glsync "implement explicit sync". In both cases, if you think users might want to do one-to-many video connections, consider providing an option to force the second (backend) sync mode to <tt>FUNNEL_SYNC_IMPLICIT</tt> (this will not work on Nvidia drivers).

## Supported synchronization combinations

### <tt>FUNNEL_SYNC_IMPLICIT, FUNNEL_SYNC_IMPLICIT</tt>

Use implicit buffer sync only.

This will only advertise implicit sync on the PipeWire stream. The other end must support implicit sync.

### <tt>FUNNEL_SYNC_EXPLICIT, FUNNEL_SYNC_EXPLICIT</tt>

Use explicit buffer sync only.

This will only advertise explicit sync on the PipeWire stream. The other end must support explicit sync.

You must use the explicit sync APIs to synchronize buffer access.

### <tt>FUNNEL_SYNC_BOTH, FUNNEL_SYNC_BOTH</tt>

Support both implicit and explicit sync.

Advertise both implicit and explicit sync, and negotiate automatically depending on the capabilities of the other end. Explicit sync is preferred if available.

You must use the explicit sync APIs to synchronize buffer access if required (check with funnel_buffer_has_sync()).

### <tt>FUNNEL_SYNC_EXPLICIT, FUNNEL_SYNC_BOTH</tt>

Use explicit buffer sync in the API, with automatic conversion to implicit sync if required.

Advertise both implicit and explicit sync, and negotiate automatically depending on the capabilities of the other end. Explicit sync is preferred if available.

You must use the explicit sync APIs to synchronize buffer access (funnel_buffer_has_sync() will always return \c true).

### <tt>FUNNEL_SYNC_EXPLICIT, FUNNEL_SYNC_IMPLICIT</tt>

Like the previous case, but forces implicit sync on the PipeWire node. This is useful if the stream will be connected to more than one consumer, since that only works with implicit sync (currently).

### Degenerate combinations

* <tt>FUNNEL_SYNC_BOTH, FUNNEL_SYNC_IMPLICIT</tt>: Same as <tt>FUNNEL_SYNC_IMPLICIT, FUNNEL_SYNC_IMPLICIT</tt>
* <tt>FUNNEL_SYNC_BOTH, FUNNEL_SYNC_EXPLICIT</tt>: Same as <tt>FUNNEL_SYNC_EXPLICIT, FUNNEL_SYNC_EXPLICIT</tt>

### Unsupported combinations

Converting explicit sync to implicit sync is not supported at this time, so these combinations are not legal:

* <tt>FUNNEL_SYNC_IMPLICIT, FUNNEL_SYNC_BOTH</tt>
* <tt>FUNNEL_SYNC_IMPLICIT, FUNNEL_SYNC_EXPLICIT</tt>

## Restrictions

The Vulkan API requires explicit sync, so the frontend synchronization mode must be FUNNEL_SYNC_EXPLICIT if you use Vulkan.

The Nvidia proprietary drivers do not support implicit sync. Passing FUNNEL_SYNC_IMPLICIT as either mode will fail on those drivers, and FUNNEL_SYNC_BOTH will behave as FUNNEL_SYNC_EXPLICIT.

## Supporting explicit sync in OpenGL {#glsync}

To support explicit (and implicit) sync in OpenGL, add this code **before** issuing any OpenGL commands that draw or blit to the buffer image/texture:

    // Explicit sync support
    if (funnel_buffer_has_sync(buf)) {
        EGLSync acquire;
        funnel_buffer_get_acquire_egl_sync(buf, &acquire);
        eglWaitSync(egl_display, acquire, 0);
        eglDestroySync(egl_display, acquire);
    }

And add this code **after** you are done issuing draw/blit commands:

    if (funnel_buffer_has_sync(buf)) {
        // Explicit sync support
        EGLSync release = eglCreateSync(
            egl_display, EGL_SYNC_NATIVE_FENCE_ANDROID, NULL);
        funnel_buffer_set_release_egl_sync(buf, release);
        eglDestroySync(egl_display, release);
    } else {
        // Required for implicit sync
        glFlush();
    }
