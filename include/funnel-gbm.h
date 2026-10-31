/** @file */
#pragma once

#include "funnel.h"
#include <gbm.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @file
 * libfunnel low-level GBM API integration
 *
 * See @ref test-egl.c for a usage example.
 */

/**
 * Set up a stream for GBM integration.
 *
 * @sync-ext
 *
 * @param stream Stream @borrowed
 * @param gbm_fd File descriptor of the GBM device @borrowed
 * @return_err
 * @retval -EEXIST The API was already initialized once
 * @retval -EINVAL Failed to create GBM device
 * @retval -EPROTONOSUPPORT GPU driver not supported (PipeWire version too old)
 * @retval -EOPNOTSUPP The GBM device does not have the required features
 */
int funnel_stream_init_gbm(struct funnel_stream *stream, int gbm_fd);

/**
 * Add a supported GBM format. Must be called in preference order (highest to
 * lowest).
 *
 * @sync-ext
 *
 * @param stream Stream @borrowed
 * @param format DRM format (FOURCC)
 * @param modifiers Pointer to a list of modifiers @borrowed
 * @param num_modifiers Number of modifiers passed
 * @return_err
 * @retval -EINVAL Invalid argument
 * @retval -EOPNOTSUPP Format is not supported by libfunnel
 */
int funnel_stream_gbm_add_format(struct funnel_stream *stream, uint32_t format,
                                 uint64_t *modifiers, size_t num_modifiers);

/**
 * Set the GBM BO allocation flags.
 *
 * @param stream Stream @borrowed
 * @param flags BO flags
 * @return_err
 * @retval -EINVAL Invalid argument
 */
int funnel_stream_gbm_set_flags(struct funnel_stream *stream, uint32_t flags);

/**
 * Get the GBM buffer object for a Funnel buffer.
 *
 * The BO will only be valid until `buf` is returned or enqueued, or the
 * stream is destroyed.
 *
 * NOTE: To ensure cross-GPU compatibility, LINEAR buffers might have
 * a width that does not correspond to the user-configured size. Use
 * funnel_buffer_get_size() to retrieve the intended texture dimensions,
 * instead of gbm_bo_get_width() and gbm_bo_get_height().
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param[out] pbo GBM BO for the buffer @borrowed-from{buf}
 * @return_err
 */
int funnel_buffer_get_gbm_bo(struct funnel_buffer *buf, struct gbm_bo **pbo);

/**
 * Get the sync object and point for acquiring the buffer.
 *
 * The user must wait on this timeline sync object point before accessing
 * the buffer.
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param[out] phandle Acquire DRM sync object handle @borrowed-from{buf}
 * @param[out] ppoint Acquire DRM sync object point
 * @return_err
 * @retval -EINVAL
 *  * Buffer does not require sync
 *  * Sync file APIs were already already used
 */
int funnel_buffer_get_acquire_sync_object(struct funnel_buffer *buf,
                                          uint32_t *phandle, uint64_t *ppoint);

/**
 * Get the sync object and point for releasing the buffer.
 *
 * The user must signal this timeline sync object after
 * access to the buffer is complete.
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param[out] phandle Release DRM sync object handle @borrowed-from{buf}
 * @param[out] ppoint Release DRM sync object point
 * @return_err
 * @retval -EINVAL
 *  * Buffer does not require sync
 *  * Sync file APIs were already already used
 */
int funnel_buffer_get_release_sync_object(struct funnel_buffer *buf,
                                          uint32_t *phandle, uint64_t *ppoint);

/**
 * Get the sync object and point for acquiring the buffer.
 *
 * The user must wait on this sync file before accessing
 * the buffer.
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param[out] pfd Sync file fd for buffer acquisition @owned
 * @return_err
 * @retval -EINVAL
 *  * Invalid argument
 *  * Buffer does not require sync
 *  * Sync object APIs were already already used
 */
int funnel_buffer_get_acquire_sync_file(struct funnel_buffer *buf, int *pfd);

/**
 * Set the sync file for releasing the buffer.
 *
 * This sync file must be signaled when access to the buffer is complete.
 *
 * @sync-ext
 *
 * @param buf Buffer @borrowed
 * @param fd DRM sync file signaled on release @borrowed
 * @return_err
 * @retval -EINVAL
 *  * Invalid argument
 *  * Buffer does not require sync
 *  * Sync object APIs were already already used
 */
int funnel_buffer_set_release_sync_file(struct funnel_buffer *buf, int fd);

#ifdef __cplusplus
}
#endif
