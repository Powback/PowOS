/*
 * PowOS: one GPU import per client dma-buf (patch 0012) - which imported EGLImage belongs to which client dma-buf,
 * how many DRI3 pixmaps share it, and the 30 s "imports / reuses / frees" counts. No X server, no EGL (the image is
 * an opaque pointer), so test/import-cache-test.c runs it.
 *
 * Why: Broforce on KGSL (2026-11-03 22:32, kgsl tracefs): Xwayland re-imported the game's 4 swapchain dma-bufs
 * ~40x/s (1219 GPUOBJ_IMPORT + 1239 GPUOBJ_FREE in 30 s, a new GPU address each time): lfdevs's 0003 re-created the
 * DRI3 pixmap's EGLImage before every Present copy and destroyed the old one at once. freedreno-kgsl submits carry
 * no memobj list, so the kernel does not know a bo is in use: the old mapping could be unmapped while the previous
 * copy still read it (partial cache lines = the 16-of-48-px black columns in Xwayland's own copy).
 * Now an import lives as long as the client's pixmaps of that dma-buf: keyed by the dma-buf's identity (st_dev +
 * st_ino of its fd: one inode per dma-buf, held alive by the import itself) plus the import's shape, reused on every
 * present, released when the last pixmap of it goes (the caller waits for the GPU before destroying it).
 * Included by xwayland-glamor-gbm.c (patch 0012) and test/import-cache-test.c.
 */
#ifndef XWAYLAND_KGSL_IMPORT_CACHE_H
#define XWAYLAND_KGSL_IMPORT_CACHE_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define XWL_KGSL_IMPORT_CACHE_SIZE 64
#define XWL_KGSL_IMPORT_CACHE_PERIOD_US (30ull * 1000 * 1000)

/* What makes two imports the same GPU import: the same dma-buf (plane 0's inode) seen with the same shape. */
struct xwl_kgsl_import_key {
    uint64_t dev, ino;
    uint32_t width, height, format, num_fds;
    uint32_t strides[4], offsets[4];
    uint64_t modifier;
};

struct xwl_kgsl_import_entry {
    struct xwl_kgsl_import_key key;
    void *image;        /* NULL: free slot */
    unsigned refs;      /* DRI3 pixmaps using it */
};

struct xwl_kgsl_import_cache {
    struct xwl_kgsl_import_entry e[XWL_KGSL_IMPORT_CACHE_SIZE];
    uint64_t period_start_us;   /* 0: not started */
    unsigned imports, reuses, frees, uncached;
};

static inline int
xwl_kgsl_import_key_eq(const struct xwl_kgsl_import_key *a, const struct xwl_kgsl_import_key *b)
{
    return memcmp(a, b, sizeof(*a)) == 0;
}

/* The key from plane 0's fstat (dev, ino) and the import's shape; unused planes are zero so keys compare whole. */
static inline void
xwl_kgsl_import_key_make(struct xwl_kgsl_import_key *k, uint64_t dev, uint64_t ino, uint32_t width,
                         uint32_t height, uint32_t format, uint32_t num_fds, const uint32_t *strides,
                         const uint32_t *offsets, uint64_t modifier)
{
    uint32_t i;

    memset(k, 0, sizeof(*k));
    k->dev = dev;
    k->ino = ino;
    k->width = width;
    k->height = height;
    k->format = format;
    k->num_fds = num_fds > 4 ? 4 : num_fds;
    for (i = 0; i < k->num_fds; i++) {
        k->strides[i] = strides[i];
        k->offsets[i] = offsets[i];
    }
    k->modifier = modifier;
}

static inline void
xwl_kgsl_import_cache_start(struct xwl_kgsl_import_cache *c, uint64_t now_us)
{
    if (!c->period_start_us)
        c->period_start_us = now_us ? now_us : 1;
}

/* The live import of this dma-buf (one more pixmap holds it: counted as a reuse), or NULL: import it, then _add. */
static inline void *
xwl_kgsl_import_cache_get(struct xwl_kgsl_import_cache *c, const struct xwl_kgsl_import_key *k, uint64_t now_us)
{
    int i;

    xwl_kgsl_import_cache_start(c, now_us);
    for (i = 0; i < XWL_KGSL_IMPORT_CACHE_SIZE; i++) {
        if (c->e[i].image && xwl_kgsl_import_key_eq(&c->e[i].key, k)) {
            c->e[i].refs++;
            c->reuses++;
            return c->e[i].image;
        }
    }
    return NULL;
}

/* A new import, held by one pixmap. 1: cached; 0: the table is full - the caller owns the image alone (still counted
 * as an import, and as a free when it goes: _put returns -1 for it and the caller destroys it). */
static inline int
xwl_kgsl_import_cache_add(struct xwl_kgsl_import_cache *c, const struct xwl_kgsl_import_key *k, void *image,
                          uint64_t now_us)
{
    int i;

    xwl_kgsl_import_cache_start(c, now_us);
    c->imports++;
    for (i = 0; i < XWL_KGSL_IMPORT_CACHE_SIZE; i++) {
        if (!c->e[i].image) {
            c->e[i].key = *k;
            c->e[i].image = image;
            c->e[i].refs = 1;
            return 1;
        }
    }
    c->uncached++;
    return 0;
}

/* A present that used the pixmap's existing import instead of importing again. */
static inline void
xwl_kgsl_import_cache_note_reuse(struct xwl_kgsl_import_cache *c, uint64_t now_us)
{
    xwl_kgsl_import_cache_start(c, now_us);
    c->reuses++;
}

/* A pixmap lets go of its image. 1: that was the last one - the caller destroys the image (after the GPU work
 * reading it has retired), counted as a free; 0: other pixmaps still hold it; -1: not in the table (an uncached
 * import: the caller destroys it, counted as a free). */
static inline int
xwl_kgsl_import_cache_put(struct xwl_kgsl_import_cache *c, void *image)
{
    int i;

    if (!image)
        return 0;
    for (i = 0; i < XWL_KGSL_IMPORT_CACHE_SIZE; i++) {
        if (c->e[i].image == image) {
            if (--c->e[i].refs)
                return 0;
            memset(&c->e[i], 0, sizeof(c->e[i]));
            c->frees++;
            return 1;
        }
    }
    c->frees++;
    return -1;
}

static inline unsigned
xwl_kgsl_import_cache_live(const struct xwl_kgsl_import_cache *c)
{
    unsigned i, n = 0;

    for (i = 0; i < XWL_KGSL_IMPORT_CACHE_SIZE; i++)
        n += c->e[i].image != NULL;
    return n;
}

/* The period's line into buf once 30 s have gone by with any activity (then a new period starts); 0 = not yet. */
static inline int
xwl_kgsl_import_cache_line(struct xwl_kgsl_import_cache *c, uint64_t now_us, char *buf, size_t len)
{
    if (!c->period_start_us || now_us - c->period_start_us < XWL_KGSL_IMPORT_CACHE_PERIOD_US ||
        !(c->imports + c->reuses + c->frees))
        return 0;
    snprintf(buf, len,
             "Xwayland KGSL: last %us: client dma-buf imports %u / reuses %u / frees %u (%u live, %u uncached: "
             "table full)\n",
             (unsigned) ((now_us - c->period_start_us) / 1000000), c->imports, c->reuses, c->frees,
             xwl_kgsl_import_cache_live(c), c->uncached);
    c->imports = c->reuses = c->frees = c->uncached = 0;
    c->period_start_us = now_us;
    return 1;
}

#endif
