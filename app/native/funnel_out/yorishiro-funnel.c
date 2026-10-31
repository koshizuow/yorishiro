// yorishiro-funnel: publishes the Yorishiro stage as a PipeWire video stream with alpha (libfunnel, MIT),
// for OBS's PipeWire video source. The Linux counterpart of Spout2 (D34).
//
//   yorishiro-funnel <frame file> [stream name] [--parent-pid PID]
//
// The app writes the stage into the frame file (in /dev/shm): four little-endian uint32 (sequence, width,
// height, 0), then width*height*4 bytes RGBA, top row first, premultiplied alpha. The sequence is odd while
// the app is writing. Frames are copied through the CPU into a GL texture and blitted into libfunnel's
// DMA-BUF buffers; sharing Godot's texture directly is a later step.
//
// Exit codes: 0 the app stopped (parent gone or no frame for 5 s), 1 PipeWire or EGL failed (message on
// stderr), 3 the frame size changed (the app starts it again).
// Lines on stderr starting with "status:" are shown in the app.
#define _GNU_SOURCE
#include <funnel-egl.h>
#include <funnel.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <X11/Xlib.h>

#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>
#define EGL_EGLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>

static const uint8_t *map;
static size_t map_len;
static int map_fd = -1;
static pid_t parent_pid;

static void fail(const char *what, int ret) {
    fprintf(stderr, "status: error: %s failed (%d%s%s)\n", what, ret, ret < 0 ? ", " : "",
            ret < 0 ? strerror(-ret) : "");
    exit(1);
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int parent_alive(void) {
    return parent_pid <= 0 || kill(parent_pid, 0) == 0 || errno != ESRCH;
}

static uint32_t header(int i) {
    return __atomic_load_n((const uint32_t *)map + i, __ATOMIC_ACQUIRE);
}

// maps the file again when the app has grown it
static int remap(size_t need) {
    struct stat st;
    if (fstat(map_fd, &st) || (size_t)st.st_size < need)
        return -1;
    if (map && map_len == (size_t)st.st_size)
        return 0;
    if (map)
        munmap((void *)map, map_len);
    map_len = st.st_size;
    map = mmap(NULL, map_len, PROT_READ, MAP_SHARED, map_fd, 0);
    if (map == MAP_FAILED) {
        map = NULL;
        return -1;
    }
    return 0;
}

// waits for a complete frame newer than *last and copies it to dst.
// 0 got one, -1 no frame for 5 s or the app is gone, 3 the size changed
static int next_frame(uint32_t *last, uint8_t *dst, uint32_t width, uint32_t height) {
    size_t bytes = (size_t)width * height * 4;
    double start = now();
    while (now() - start < 5.0 && parent_alive()) {
        uint32_t s1 = header(0);
        if (s1 % 2 == 0 && s1 != *last && remap(16) == 0) {
            if (header(1) != width || header(2) != height)
                return 3;
            if (remap(16 + bytes) == 0) {
                memcpy(dst, map + 16, bytes);
                if (header(0) == s1) {
                    *last = s1;
                    return 0;
                }
            }
        }
        usleep(1000);
    }
    return -1;
}

// any EGL display that can import DMA-BUFs: X11 when there is one, otherwise a GPU device (NVIDIA) or
// Mesa's surfaceless platform (Wayland sessions)
static EGLDisplay open_display(void) {
    if (getenv("DISPLAY")) {
        Display *x11 = XOpenDisplay(NULL);
        if (x11) {
            EGLDisplay dpy = eglGetDisplay((EGLNativeDisplayType)x11);
            if (dpy != EGL_NO_DISPLAY && eglInitialize(dpy, NULL, NULL))
                return dpy;
        }
    }
    PFNEGLQUERYDEVICESEXTPROC query_devices = (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    if (query_devices) {
        EGLDeviceEXT devices[8];
        EGLint n = 0;
        if (query_devices(8, devices, &n) && n > 0) {
            EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, devices[0], NULL);
            if (dpy != EGL_NO_DISPLAY && eglInitialize(dpy, NULL, NULL))
                return dpy;
        }
    }
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    if (dpy != EGL_NO_DISPLAY && eglInitialize(dpy, NULL, NULL))
        return dpy;
    return EGL_NO_DISPLAY;
}

int main(int argc, char **argv) {
    const char *path = NULL, *name = "Yorishiro";
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--parent-pid") && i + 1 < argc)
            parent_pid = atoi(argv[++i]);
        else if (!path)
            path = argv[i];
        else
            name = argv[i];
    }
    if (!path) {
        fprintf(stderr, "usage: yorishiro-funnel <frame file> [stream name] [--parent-pid PID]\n");
        return 2;
    }

    double t0 = now();
    while ((map_fd = open(path, O_RDONLY)) < 0 || remap(16) || header(0) < 2) {
        if (map_fd >= 0)
            close(map_fd);
        map_fd = -1;
        map = NULL;
        if (now() - t0 > 30 || !parent_alive()) {
            if (!parent_alive())
                unlink(path);
            return 0;
        }
        usleep(100000);
    }
    uint32_t width = header(1), height = header(2);
    if (width == 0 || height == 0 || width > 8192 || height > 8192)
        fail("reading the frame size", -EINVAL);
    uint8_t *frame = malloc((size_t)width * height * 4);

    EGLDisplay dpy = open_display();
    if (dpy == EGL_NO_DISPLAY)
        fail("opening an EGL display", 0);
    eglBindAPI(EGL_OPENGL_API);
    EGLint cfg_attrs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_NONE};
    EGLConfig cfg;
    EGLint n;
    EGLContext egl_ctx = EGL_NO_CONTEXT;
    if (eglChooseConfig(dpy, cfg_attrs, &cfg, 1, &n) && n > 0)
        egl_ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, NULL);
    else  // configless contexts (EGL_KHR_no_config_context) on displays without configs
        egl_ctx = eglCreateContext(dpy, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, NULL);
    if (egl_ctx == EGL_NO_CONTEXT || !eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, egl_ctx))
        fail("creating a GL context", 0);

    struct funnel_ctx *ctx;
    struct funnel_stream *stream;
    int ret;
    if ((ret = funnel_new(&ctx)))
        fail("starting libfunnel", ret);
    funnel_set_app_name(ctx, "Yorishiro");
    funnel_set_app_id(ctx, "yorishiro");
    if ((ret = funnel_connect(ctx)))
        fail("connecting to PipeWire", ret);
    if ((ret = funnel_stream_create(ctx, name, &stream)) || (ret = funnel_stream_init_egl(stream, dpy)) ||
        (ret = funnel_stream_set_size(stream, width, height)) ||
        (ret = funnel_stream_set_mode(stream, FUNNEL_ASYNC)) ||
        (ret = funnel_stream_set_sync(stream, FUNNEL_SYNC_BOTH, FUNNEL_SYNC_BOTH)) ||
        (ret = funnel_stream_set_rate(stream, FUNNEL_FRACTION(60, 1), FUNNEL_RATE_VARIABLE,
                                      FUNNEL_FRACTION(1000, 1))) ||
        (ret = funnel_stream_egl_add_format(stream, FUNNEL_EGL_FORMAT_RGBA8888)) ||
        (ret = funnel_stream_configure(stream)) || (ret = funnel_stream_start(stream)))
        fail("setting up the PipeWire stream", ret);
    fprintf(stderr, "status: streaming %ux%u as \"%s\"\n", width, height, name);

    GLuint src_tex, src_fb, dst_fb;
    glGenTextures(1, &src_tex);
    glBindTexture(GL_TEXTURE_2D, src_tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &src_fb);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, src_fb);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, src_tex, 0);
    glGenFramebuffers(1, &dst_fb);

    uint32_t last = 0;
    int consumer = 0;
    while ((ret = next_frame(&last, frame, width, height)) == 0) {
        struct funnel_buffer *buf;
        if ((ret = funnel_stream_dequeue(stream, &buf)) < 0)
            fail("getting a PipeWire buffer", ret);
        if (!buf)
            continue;  // no consumer yet, or it has not given a buffer back
        if (!consumer) {
            consumer = 1;
            fprintf(stderr, "status: OBS (or another app) is receiving\n");
        }
        glBindTexture(GL_TEXTURE_2D, src_tex);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, frame);

        EGLImage image;
        if ((ret = funnel_buffer_get_egl_image(buf, &image)))
            fail("mapping the PipeWire buffer", ret);
        if (funnel_buffer_has_sync(buf)) {
            EGLSync acquire;
            if ((ret = funnel_buffer_get_acquire_egl_sync(buf, &acquire)))
                fail("buffer acquire sync", ret);
            eglWaitSync(dpy, acquire, 0);
            eglDestroySync(dpy, acquire);
        }
        GLuint dst_tex;
        glGenTextures(1, &dst_tex);
        glBindTexture(GL_TEXTURE_2D, dst_tex);
        glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, image);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst_fb);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, dst_tex, 0);
        // the frame and the funnel buffer both hold the top row first, no flip
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
        glDeleteTextures(1, &dst_tex);
        if (funnel_buffer_has_sync(buf)) {
            EGLSync release = eglCreateSync(dpy, EGL_SYNC_NATIVE_FENCE_ANDROID, NULL);
            if ((ret = funnel_buffer_set_release_egl_sync(buf, release)))
                fail("buffer release sync", ret);
            eglDestroySync(dpy, release);
        }
        glFlush();
        if ((ret = funnel_stream_enqueue(stream, buf)) < 0)
            fail("sending the PipeWire buffer", ret);
    }
    funnel_stream_stop(stream);
    funnel_stream_destroy(stream);
    funnel_shutdown(ctx);
    if (!parent_alive())
        unlink(path);  // the app was killed before it could remove its frame file
    return ret == 3 ? 3 : 0;
}
