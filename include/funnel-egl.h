/** @file */
#pragma once

#include "funnel.h"
#include <EGL/egl.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @file
 * libfunnel EGL API integration
 *
 * See @ref test-egl.c for a usage example.
 */

/**
 * @example test-egl.c
 *
 * This is an example of how to use the EGL API integration with a
 * bare-bones X11 + EGL application.
 */

/**
 * Formats available for EGL integration
 */
enum funnel_egl_format {
    /** Unknown format */
    FUNNEL_EGL_FORMAT_UNKNOWN = 0,
    /** 8-bit RGB without alpha, sRGB (32bpp with padding) */
    FUNNEL_EGL_FORMAT_RGB888,
    /** 8-bit RGBA with premultiplied alpha, sRGB (32bpp) */
    FUNNEL_EGL_FORMAT_RGBA8888,
};

/**
 * Set up a stream for EGL integration.
 *
 * @sync-ext
 *
 * @param stream Stream @borrowed
 * @param display EGLDisplay to attach to the stream @borrowed-by{stream}
 * @return_err
 * @retval -EEXIST The API was already initialized once
 * @retval -EOPNOTSUPP Missing EGL extensions
 * @retval -EPROTONOSUPPORT GPU driver not supported (PipeWire version too old)
 * @retval -ENODEV
 *  * Could not locate DRM render node
 *  * GBM or EGL initialization failed
 */
int funnel_stream_init_egl(struct funnel_stream *stream, EGLDisplay display);

/**
 * Add a supported EGL format. Must be called in preference order (highest to
 * lowest).
 *
 * @sync-ext
 *
 * @param stream Stream @borrowed
 * @param format `enum funnel_egl_format` format
 * @return_err
 * @retval -EINVAL
 *  * Invalid argument
 *  * API is not EGL
 * @retval -ENOENT Format is not supported by the device or not usable
 */
int funnel_stream_egl_add_format(struct funnel_stream *stream,
                                 enum funnel_egl_format format);

/**
 * Get the EGLImage for a Funnel buffer.
 *
 * The EGLImage will only be valid until `buf` is returned or enqueued, or the
 * stream is destroyed.
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param[out] pimage EGLImage for the buffer @borrowed-from{buf}
 * @return_err
 * @retval -EINVAL
 *  * Invalid argument
 *  * API is not EGL
 */
int funnel_buffer_get_egl_image(struct funnel_buffer *buf, EGLImage *pimage);

/**
 * Get the EGL format for a Funnel buffer.
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param[out] pformat EGL format
 * @return_err
 * @retval -EINVAL
 *  * Invalid argument
 *  * API is not EGL
 */
int funnel_buffer_get_egl_format(struct funnel_buffer *buf,
                                 enum funnel_egl_format *pformat);

/**
 * Get the EGLSync for acquiring the buffer.
 *
 * The user must wait on this sync object before accessing
 * the buffer.
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param[out] psync EGLSync @owned
 * @return_err
 * @retval -EINVAL
 *  * Invalid argument
 *  * API is not EGL
 * @retval -EIO Unable to create an acquire EGLSync
 */
int funnel_buffer_get_acquire_egl_sync(struct funnel_buffer *buf,
                                       EGLSync *psync);

/**
 * Set the EGLSync for releasing the buffer.
 *
 * This sync object must be signaled when access to the buffer is complete.
 * The sync type must be EGL_SYNC_NATIVE_FENCE_ANDROID.
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param sync EGLSync @borrowed
 * @return_err
 * @retval -EINVAL
 *  * Invalid argument
 *  * API is not EGL
 * @retval -EIO Unable to set the release EGLSync (is the sync type correct?)
 */
int funnel_buffer_set_release_egl_sync(struct funnel_buffer *buf, EGLSync sync);

#ifdef __cplusplus
}
#endif
