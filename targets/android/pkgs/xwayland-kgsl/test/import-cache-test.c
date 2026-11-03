/* PowOS: patch 0012's one-import-per-client-dma-buf table (xwayland-kgsl-import-cache.h), no X server or EGL.
 * Run: test/run.sh. */
#include <stdio.h>
#include "../xwayland-kgsl-import-cache.h"

static int fails;
#define EXPECT(cond) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); fails++; } } while (0)

static struct xwl_kgsl_import_key
key(uint64_t ino, uint32_t stride)
{
    struct xwl_kgsl_import_key k;
    const uint32_t strides[4] = { stride, 999, 999, 999 }, offsets[4] = { 0, 7, 7, 7 };

    /* Broforce's swapchain image: 9216-B pitch (2304 px), 2440 rows, one plane; unused planes must not count. */
    xwl_kgsl_import_key_make(&k, 0x0c, ino, 2304, 2440, 0x34325258, 1, strides, offsets, 0);
    return k;
}

int main(void)
{
    static struct xwl_kgsl_import_cache c;
    static int img[4];
    struct xwl_kgsl_import_key k[4];
    char line[256];
    const uint64_t t0 = 5000000;

    for (int i = 0; i < 4; i++)
        k[i] = key(1000 + i, 9216);

    /* 4 swapchain images imported once each (PixmapFromBuffers: miss, import, add). */
    for (int i = 0; i < 4; i++) {
        EXPECT(xwl_kgsl_import_cache_get(&c, &k[i], t0) == NULL);
        EXPECT(xwl_kgsl_import_cache_add(&c, &k[i], &img[i], t0) == 1);
    }
    EXPECT(xwl_kgsl_import_cache_live(&c) == 4);

    /* 30 s at ~40 presents/s: every present reuses its pixmap's import - no new import, no free. */
    for (int i = 0; i < 1200; i++)
        xwl_kgsl_import_cache_note_reuse(&c, t0 + i);
    EXPECT(c.imports == 4 && c.reuses == 1200 && c.frees == 0);

    /* A second pixmap of the same dma-buf (same inode, same shape) shares the import; another shape does not. */
    EXPECT(xwl_kgsl_import_cache_get(&c, &k[2], t0) == &img[2]);
    struct xwl_kgsl_import_key other = key(1002, 9280);
    EXPECT(xwl_kgsl_import_cache_get(&c, &other, t0) == NULL);
    /* The same dma-buf with different garbage in unused plane slots is the same key (key_make zeroes them). */
    struct xwl_kgsl_import_key again = key(1002, 9216);
    EXPECT(xwl_kgsl_import_key_eq(&again, &k[2]));

    /* Lifetime: the image goes only with its last pixmap. */
    EXPECT(xwl_kgsl_import_cache_put(&c, &img[2]) == 0);   /* one pixmap of img[2] left */
    EXPECT(xwl_kgsl_import_cache_live(&c) == 4);
    EXPECT(xwl_kgsl_import_cache_put(&c, &img[2]) == 1);   /* last: caller waits for the GPU, then destroys */
    EXPECT(xwl_kgsl_import_cache_live(&c) == 3);
    EXPECT(xwl_kgsl_import_cache_get(&c, &k[2], t0) == NULL); /* gone: a new pixmap of it imports again */
    EXPECT(xwl_kgsl_import_cache_put(&c, NULL) == 0);

    /* The 30 s line: imports / reuses / frees. */
    EXPECT(!xwl_kgsl_import_cache_line(&c, t0 + 29999999, line, sizeof(line)));
    EXPECT(xwl_kgsl_import_cache_line(&c, t0 + 30000000, line, sizeof(line)));
    EXPECT(strstr(line, "imports 4 / reuses 1201 / frees 1 (3 live, 0 uncached") != NULL);
    EXPECT(c.imports == 0 && c.reuses == 0 && c.frees == 0 && c.period_start_us == t0 + 30000000);
    EXPECT(!xwl_kgsl_import_cache_line(&c, t0 + 90000000, line, sizeof(line)));  /* nothing happened: no line */

    /* A full table: the import still works, uncached; _put says -1 (the caller destroys it) and counts the free. */
    static int many[XWL_KGSL_IMPORT_CACHE_SIZE + 1];
    for (int i = 3; i < XWL_KGSL_IMPORT_CACHE_SIZE; i++) {
        struct xwl_kgsl_import_key ki = key(5000 + i, 9216);
        EXPECT(xwl_kgsl_import_cache_add(&c, &ki, &many[i], t0) == 1);
    }
    struct xwl_kgsl_import_key kf = key(9999, 9216);
    EXPECT(xwl_kgsl_import_cache_add(&c, &kf, &many[XWL_KGSL_IMPORT_CACHE_SIZE], t0) == 0);
    EXPECT(c.uncached == 1);
    EXPECT(xwl_kgsl_import_cache_put(&c, &many[XWL_KGSL_IMPORT_CACHE_SIZE]) == -1);

    if (fails)
        return 1;
    printf("import-cache-test: ok (%s)", line);
    return 0;
}
