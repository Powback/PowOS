/*
 * PowOS: why a KGSL DRI3 dma-buf import can fail, from the import parameters alone (no EGL), and a small
 * table so a failing import is logged once per distinct buffer shape instead of ~90 times a second.
 *
 * The rules mirror the importer, the KGSL Mesa build's freedreno gallium driver (lfdevs mesa-for-android-container
 * @ ef25369b, fd_resource_from_handle -> fd6 layout):
 *   - src/freedreno/fdl/fd6_layout.c: a linear image with an explicit (imported) layout keeps the client's pitch only
 *     if it is a multiple of 64 bytes (pitchalign 0 + 6 for cpp <= 4; cpp 8/16 need 64 << (cpp_shift - 2)); otherwise
 *     the layout fails and EGL reports EGL_BAD_ALLOC.
 *   - src/gallium/drivers/freedreno/freedreno_resource.c: the bo must hold offset + pitch * height bytes, and the
 *     pitch must cover width * cpp.
 * Included by xwayland-glamor-gbm.c (patch 0010) and by test/import-check-test.c (the same file, no X server).
 */
#ifndef XWAYLAND_KGSL_IMPORT_CHECK_H
#define XWAYLAND_KGSL_IMPORT_CHECK_H

#include <stdint.h>
#include <string.h>

#define XWL_KGSL_LINEAR_PITCH_ALIGN 64u

/* Byte alignment freedreno needs for an imported linear pitch of cpp bytes per pixel. */
static inline uint32_t
xwl_kgsl_linear_pitch_align(uint32_t cpp)
{
    if (cpp > 4 && (cpp & (cpp - 1)) == 0)
        return XWL_KGSL_LINEAR_PITCH_ALIGN * (cpp / 4);
    return XWL_KGSL_LINEAR_PITCH_ALIGN;
}

/* The import rule this buffer breaks, or NULL when its parameters look importable (then the failure is in the
 * KGSL bo import itself: the kernel refused the dma-buf). fd_size < 0: unknown (lseek failed). */
static inline const char *
xwl_kgsl_import_check(uint32_t width, uint32_t height, uint32_t cpp, uint32_t stride, uint32_t offset,
                      int64_t fd_size)
{
    if (stride < (uint64_t) width * cpp)
        return "stride shorter than width*cpp";
    if (stride % xwl_kgsl_linear_pitch_align(cpp))
        return "stride not 64-byte aligned (freedreno linear import)";
    if (fd_size >= 0 && (uint64_t) offset + (uint64_t) stride * height > (uint64_t) fd_size)
        return "dma-buf smaller than offset+stride*height";
    return NULL;
}

struct xwl_kgsl_import_shape {
    uint32_t width, height, stride, offset;
    int64_t fd_size;
    uint64_t count;
};

#define XWL_KGSL_IMPORT_SHAPES 8

struct xwl_kgsl_import_log {
    struct xwl_kgsl_import_shape shapes[XWL_KGSL_IMPORT_SHAPES];
    unsigned int used, next;
};

/* Counts one failure of this shape and returns how many there have been (1 = first). A full table recycles its
 * oldest slot, so a new shape is always logged. */
static inline uint64_t
xwl_kgsl_import_log_note(struct xwl_kgsl_import_log *log, uint32_t width, uint32_t height, uint32_t stride,
                         uint32_t offset, int64_t fd_size)
{
    struct xwl_kgsl_import_shape *s;
    unsigned int i;

    for (i = 0; i < log->used; i++) {
        s = &log->shapes[i];
        if (s->width == width && s->height == height && s->stride == stride && s->offset == offset &&
            s->fd_size == fd_size)
            return ++s->count;
    }
    if (log->used < XWL_KGSL_IMPORT_SHAPES)
        s = &log->shapes[log->used++];
    else {
        s = &log->shapes[log->next];
        log->next = (log->next + 1) % XWL_KGSL_IMPORT_SHAPES;
    }
    *s = (struct xwl_kgsl_import_shape) { width, height, stride, offset, fd_size, 1 };
    return 1;
}

/* Log the first failure of a shape, then every 1000th (with the running count). */
static inline int
xwl_kgsl_import_log_should_print(uint64_t count)
{
    return count == 1 || count % 1000 == 0;
}

#endif /* XWAYLAND_KGSL_IMPORT_CHECK_H */
