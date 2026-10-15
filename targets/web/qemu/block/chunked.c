/*
 * PowOS web: a disk streamed on demand.
 *
 * The disk is published as content-addressed chunks (targets/web/tools/chunk-disk.py):
 *   <url>/manifest.json         {"size": bytes, "blockSize": 262144, "hashBytes": 16, ...}
 *   <url>/index.bin             hashBytes per block, in disk order; all zeros = a block of zeros
 *   <url>/chunks/<hh>/<hash>    one block, zlib-compressed, named by its hash (immutable)
 *
 * A block is fetched the first time the guest reads it - the browser never downloads the image - and never
 * again: recent blocks are kept here, the rest by the browser's HTTP cache (chunks never change). Zero blocks
 * are never fetched. Writes stay in this session (copy-on-write per block).
 *
 * Fetches are synchronous XHRs: this runs on QEMU's worker thread (-sPROXY_TO_PTHREAD), where they're allowed
 * and only block the guest's I/O, never the page.
 *
 * Usage: -drive if=none,id=disk0,format=raw,file.driver=chunked,file.url=https://host/powos/disk
 *        -device virtio-blk-pci,drive=disk0
 *
 * TODO: keep written blocks (and fetched ones) in OPFS, so writes survive a reload and the second visit needs
 * no network at all.
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 */

#include "qemu/osdep.h"
#include "qapi/error.h"
#include "qapi/qmp/qdict.h"
#include "qapi/qmp/qjson.h"
#include "qapi/qmp/qnum.h"
#include "qemu/module.h"
#include "qemu/option.h"
#include "block/block-io.h"
#include "block/block_int.h"
#include "qemu/bswap.h"
#include "qemu/cutils.h"
#include <zlib.h>

#ifdef __EMSCRIPTEN__
#include <emscripten.h>

/* GET url into dst (at most cap bytes). Returns the length, or < 0 on failure. */
EM_JS(int, chunked_http_get, (const char *url, void *dst, int cap), {
    try {
        var x = new XMLHttpRequest();
        x.open('GET', UTF8ToString(url), false);
        x.responseType = 'arraybuffer';
        x.send();
        if (x.status !== 200) return -(x.status || 1);
        var b = new Uint8Array(x.response);
        if (b.length > cap) return -2;
        HEAPU8.set(b, dst);
        return b.length;
    } catch (e) {
        console.error('chunked: ' + UTF8ToString(url) + ': ' + e);
        return -1;
    }
});
/*
 * Read-ahead: start an asynchronous fetch of a chunk the guest will probably read next. Chunks are immutable
 * (Cache-Control: immutable), so it lands in the browser's HTTP cache and the later synchronous read is served
 * from there - many round trips become parallel downloads. Fire and forget; each URL once.
 */
EM_JS(void, chunked_prefetch, (const char *url), {
    var u = UTF8ToString(url);
    var seen = globalThis.__chunkedPrefetched || (globalThis.__chunkedPrefetched = new Set());
    if (seen.has(u)) return;
    seen.add(u);
    fetch(u).then(function (r) { return r.arrayBuffer(); }).catch(function () { seen.delete(u); });
});
#else
static void chunked_prefetch(const char *url)
{
}

/*
 * Native QEMU (the same source, built to make snapshots on the server): url= is a local directory holding the
 * published disk, read as files - the same bytes the browser streams.
 */
static int chunked_http_get(const char *url, void *dst, int cap)
{
    int fd = open(url, O_RDONLY);
    ssize_t n, total = 0;

    if (fd < 0) {
        return -errno;
    }
    while (total < cap && (n = read(fd, (uint8_t *)dst + total, cap - total)) > 0) {
        total += n;
    }
    if (total == cap && read(fd, &(uint8_t){0}, 1) > 0) {
        total = -2; /* bigger than the buffer */
    }
    close(fd);
    return total;
}
#endif

#define CACHE_BLOCKS 64 /* decompressed blocks kept here (16 MiB at 256 KiB) */

typedef struct {
    int64_t index;
    uint8_t *data;
    uint64_t used;
} CacheEntry;

typedef struct {
    char *url;
    char *save_overlay;   /* native: where close() writes the overlay of this session's writes */
    int64_t size;
    int64_t block_size;
    int hash_bytes;
    int64_t blocks;
    uint8_t *hashes;      /* index.bin */
    GHashTable *dirty;    /* block index -> written copy (g_malloc'd block) */
    CacheEntry cache[CACHE_BLOCKS];
    uint64_t tick;
    uint8_t *compressed;  /* fetch buffer */
    int64_t compressed_cap;
    uint64_t fetched_blocks, fetched_bytes;
} BDRVChunkedState;

static QemuOptsList runtime_opts = {
    .name = "chunked",
    .head = QTAILQ_HEAD_INITIALIZER(runtime_opts.head),
    .desc = {
        { .name = "url", .type = QEMU_OPT_STRING, .help = "base URL of the chunked disk" },
        { .name = "index", .type = QEMU_OPT_STRING,
          .help = "index (under url) to use instead of index.bin: a snapshot pins the disk it was made on" },
        { .name = "overlay", .type = QEMU_OPT_STRING,
          .help = "overlay (under url) of blocks a snapshot's machine had written: block index -> chunk hash" },
        { .name = "save-overlay", .type = QEMU_OPT_STRING,
          .help = "native: on close, write this session's writes as chunks (under url) + an overlay file here" },
        { /* end of list */ }
    },
};

static int64_t get_int(QDict *d, const char *key)
{
    QNum *n = qobject_to(QNum, qdict_get(d, key));
    int64_t v;
    return n && qnum_get_try_int(n, &v) ? v : -1;
}

static int chunked_file_open(BlockDriverState *bs, QDict *options, int flags, Error **errp)
{
    BDRVChunkedState *s = bs->opaque;
    QemuOpts *opts = qemu_opts_create(&runtime_opts, NULL, 0, &error_abort);
    g_autofree char *murl = NULL, *iurl = NULL, *mtext = NULL, *overlay = NULL, *index_name = NULL;
    QDict *m;
    int n;

    qemu_opts_absorb_qdict(opts, options, &error_abort);
    s->url = g_strdup(qemu_opt_get(opts, "url"));
    overlay = g_strdup(qemu_opt_get(opts, "overlay"));
    index_name = g_strdup(qemu_opt_get(opts, "index"));
    s->save_overlay = g_strdup(qemu_opt_get(opts, "save-overlay"));
    qemu_opts_del(opts);
    if (!s->url) {
        error_setg(errp, "chunked: url= is required");
        return -EINVAL;
    }

    murl = g_strdup_printf("%s/manifest.json", s->url);
    mtext = g_malloc0(64 * 1024);
    n = chunked_http_get(murl, mtext, 64 * 1024 - 1);
    if (n <= 0) {
        error_setg(errp, "chunked: can't fetch %s (%d)", murl, n);
        return -EIO;
    }
    m = qobject_to(QDict, qobject_from_json(mtext, NULL));
    if (!m) {
        error_setg(errp, "chunked: %s isn't a JSON object", murl);
        return -EINVAL;
    }
    s->size = get_int(m, "size");
    s->block_size = get_int(m, "blockSize");
    s->hash_bytes = get_int(m, "hashBytes");
    qobject_unref(m);
    if (s->size <= 0 || s->block_size <= 0 || s->hash_bytes <= 0 || s->hash_bytes > 64) {
        error_setg(errp, "chunked: bad manifest %s", murl);
        return -EINVAL;
    }
    s->blocks = DIV_ROUND_UP(s->size, s->block_size);

    /* A snapshot carries its own copy of the index it was made on (build-snapshot.sh), so publishing a rebuilt disk
     * (a new index.bin) never changes the disk under an already published snapshot. */
    iurl = g_strdup_printf("%s/%s", s->url, index_name ? index_name : "index.bin");
    s->hashes = g_malloc(s->blocks * s->hash_bytes);
    n = chunked_http_get(iurl, s->hashes, s->blocks * s->hash_bytes);
    if (n != s->blocks * s->hash_bytes) {
        error_setg(errp, "chunked: %s: got %d bytes, want %" PRId64, iurl, n, s->blocks * s->hash_bytes);
        return -EIO;
    }

    /*
     * A snapshot's overlay: the blocks its machine had written (they're in its RAM's page cache and file system
     * state), as (u64 little-endian block index, hash) records; their chunks live in the same store, so they
     * stream like the rest of the disk.
     */
    if (overlay) {
        int rec = 8 + s->hash_bytes, cap = 16 << 20;
        g_autofree char *ourl = g_strdup_printf("%s/%s", s->url, overlay);
        g_autofree uint8_t *o = g_malloc(cap);
        n = chunked_http_get(ourl, o, cap);
        if (n < 0 || n % rec) {
            error_setg(errp, "chunked: overlay %s: bad size %d", ourl, n);
            return -EIO;
        }
        for (int i = 0; i < n; i += rec) {
            uint64_t index = ldq_le_p(o + i);
            if (index >= s->blocks) {
                error_setg(errp, "chunked: overlay %s: block %" PRIu64 " out of range", ourl, index);
                return -EINVAL;
            }
            memcpy(s->hashes + index * s->hash_bytes, o + i + 8, s->hash_bytes);
        }
        fprintf(stderr, "chunked: overlay %s: %d blocks\n", overlay, n / rec);
    }

    s->dirty = g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, g_free);
    for (int i = 0; i < CACHE_BLOCKS; i++) {
        s->cache[i].index = -1;
        s->cache[i].data = g_malloc(s->block_size);
    }
    /* zlib output of incompressible data is a little bigger than its input. */
    s->compressed_cap = s->block_size + s->block_size / 64 + 1024;
    s->compressed = g_malloc(s->compressed_cap);
    bs->supported_write_flags = BDRV_REQ_FUA;
    fprintf(stderr, "chunked: %s: %" PRId64 " MB, %" PRId64 " blocks\n", s->url, s->size >> 20, s->blocks);
    return 0;
}

/*
 * Native, when making a snapshot (targets/web/build-snapshot.sh): the blocks this session wrote, as chunks in the
 * disk's store (named by SHA-256 truncated to hashBytes - names only have to be unique) + the overlay file that
 * maps block index -> chunk. All-zero blocks get the zero hash (read back as zeros, never stored).
 */
static void chunked_save_overlay(BDRVChunkedState *s)
{
    g_autoptr(GByteArray) recs = g_byte_array_new();
    g_autofree uint8_t *cbuf = g_malloc(compressBound(s->block_size));
    GHashTableIter it;
    gpointer k, v;
    int n = 0, stored = 0;

    g_hash_table_iter_init(&it, s->dirty);
    while (g_hash_table_iter_next(&it, &k, &v)) {
        int64_t index = *(int64_t *)k;
        const uint8_t *data = v;
        uint8_t hash[64] = { 0 }, idx[8];

        if (!buffer_is_zero(data, s->block_size)) {
            g_autofree char *hex = g_compute_checksum_for_data(G_CHECKSUM_SHA256, data, s->block_size);
            g_autofree char *dir = g_strdup_printf("%s/chunks/%.2s", s->url, hex);
            g_autofree char *path = g_strdup_printf("%s/%.*s", dir, s->hash_bytes * 2, hex);
            for (int i = 0; i < s->hash_bytes; i++) {
                sscanf(hex + 2 * i, "%2hhx", &hash[i]);
            }
            if (access(path, F_OK) != 0) {
                uLongf clen = compressBound(s->block_size);
                if (compress2(cbuf, &clen, data, s->block_size, 6) != Z_OK) {
                    fprintf(stderr, "chunked: compressing block %" PRId64 " failed\n", index);
                    continue;
                }
                g_mkdir_with_parents(dir, 0755);
                if (!g_file_set_contents(path, (const char *)cbuf, clen, NULL)) {
                    fprintf(stderr, "chunked: writing %s failed\n", path);
                    continue;
                }
                stored++;
            }
        }
        stq_le_p(idx, index);
        g_byte_array_append(recs, idx, 8);
        g_byte_array_append(recs, hash, s->hash_bytes);
        n++;
    }
    if (!g_file_set_contents(s->save_overlay, (const char *)recs->data, recs->len, NULL)) {
        fprintf(stderr, "chunked: writing overlay %s failed\n", s->save_overlay);
        return;
    }
    fprintf(stderr, "chunked: saved overlay %s: %d blocks (%d new chunks)\n", s->save_overlay, n, stored);
}

static void chunked_close(BlockDriverState *bs)
{
    BDRVChunkedState *s = bs->opaque;
    if (s->save_overlay) {
        chunked_save_overlay(s);
    }
    g_free(s->save_overlay);
    for (int i = 0; i < CACHE_BLOCKS; i++) {
        g_free(s->cache[i].data);
    }
    g_hash_table_destroy(s->dirty);
    g_free(s->hashes);
    g_free(s->compressed);
    g_free(s->url);
}

static int64_t coroutine_fn chunked_co_getlength(BlockDriverState *bs)
{
    BDRVChunkedState *s = bs->opaque;
    return s->size;
}

static bool is_zero_hash(const uint8_t *h, int n)
{
    for (int i = 0; i < n; i++) {
        if (h[i]) {
            return false;
        }
    }
    return true;
}

/* The block's current bytes: written copy, cached, zeros (NULL), or fetched now. Sets *err on failure. */
#define READAHEAD_BLOCKS 8 /* chunks prefetched after each fetch (ext4 lays files out mostly sequentially) */

/* The chunk URL of a block (g_free it). */
static char *chunk_url(BDRVChunkedState *s, const uint8_t *h)
{
    char hex[129];
    for (int i = 0; i < s->hash_bytes; i++) {
        sprintf(hex + 2 * i, "%02x", h[i]);
    }
    return g_strdup_printf("%s/chunks/%.2s/%s", s->url, hex, hex);
}

static const uint8_t *block_data(BDRVChunkedState *s, int64_t index, int *err)
{
    const uint8_t *h = s->hashes + index * s->hash_bytes;
    uint8_t *w = g_hash_table_lookup(s->dirty, &index);
    CacheEntry *victim = &s->cache[0];
    g_autofree char *url = NULL;
    uLongf len;
    int n;

    *err = 0;
    if (w) {
        return w;
    }
    if (is_zero_hash(h, s->hash_bytes)) {
        return NULL;
    }
    for (int i = 0; i < CACHE_BLOCKS; i++) {
        if (s->cache[i].index == index) {
            s->cache[i].used = ++s->tick;
            return s->cache[i].data;
        }
        if (s->cache[i].used < victim->used) {
            victim = &s->cache[i];
        }
    }

    url = chunk_url(s, h);
    n = chunked_http_get(url, s->compressed, s->compressed_cap);
    if (n <= 0) {
        fprintf(stderr, "chunked: fetching block %" PRId64 " (%s) failed: %d\n", index, url, n);
        *err = -EIO;
        return NULL;
    }
    len = s->block_size;
    if (uncompress(victim->data, &len, s->compressed, n) != Z_OK || len != s->block_size) {
        fprintf(stderr, "chunked: block %" PRId64 " (%s) is corrupt\n", index, url);
        *err = -EIO;
        return NULL;
    }
    victim->index = index;
    victim->used = ++s->tick;
    /* Read-ahead: the next stored blocks (not zero, not overwritten here) start downloading in parallel. */
    for (int64_t next = index + 1; next <= index + READAHEAD_BLOCKS && next < s->blocks; next++) {
        const uint8_t *nh = s->hashes + next * s->hash_bytes;
        if (!is_zero_hash(nh, s->hash_bytes) && !g_hash_table_contains(s->dirty, &next)) {
            g_autofree char *nurl = chunk_url(s, nh);
            chunked_prefetch(nurl);
        }
    }
    s->fetched_blocks++;
    s->fetched_bytes += n;
    if (s->fetched_blocks % 64 == 0) {
        fprintf(stderr, "chunked: fetched %" PRIu64 " blocks, %.1f MB over the network\n",
                s->fetched_blocks, s->fetched_bytes / 1e6);
    }
    return victim->data;
}

static int coroutine_fn chunked_co_preadv(BlockDriverState *bs, int64_t offset, int64_t bytes,
                                          QEMUIOVector *qiov, BdrvRequestFlags flags)
{
    BDRVChunkedState *s = bs->opaque;
    int64_t done = 0;

    while (done < bytes) {
        int64_t pos = offset + done;
        int64_t index = pos / s->block_size;
        int64_t in = pos % s->block_size;
        int64_t n = MIN(bytes - done, s->block_size - in);
        int err;
        const uint8_t *d;

        if (index >= s->blocks) {
            qemu_iovec_memset(qiov, done, 0, bytes - done);
            break;
        }
        d = block_data(s, index, &err);
        if (err) {
            return err;
        }
        if (d) {
            qemu_iovec_from_buf(qiov, done, d + in, n);
        } else {
            qemu_iovec_memset(qiov, done, 0, n);
        }
        done += n;
    }
    return 0;
}

static int coroutine_fn chunked_co_pwritev(BlockDriverState *bs, int64_t offset, int64_t bytes,
                                           QEMUIOVector *qiov, BdrvRequestFlags flags)
{
    BDRVChunkedState *s = bs->opaque;
    int64_t done = 0;

    while (done < bytes) {
        int64_t pos = offset + done;
        int64_t index = pos / s->block_size;
        int64_t in = pos % s->block_size;
        int64_t n = MIN(bytes - done, s->block_size - in);
        uint8_t *w;

        if (index >= s->blocks) {
            return -ENOSPC;
        }
        w = g_hash_table_lookup(s->dirty, &index);
        if (!w) {
            int err;
            const uint8_t *d;
            int64_t *key = g_new(int64_t, 1);

            /* A partial write keeps the rest of the block: read it first (unless the write covers it all). */
            w = g_malloc0(s->block_size);
            if (n < s->block_size) {
                d = block_data(s, index, &err);
                if (err) {
                    g_free(w);
                    g_free(key);
                    return err;
                }
                if (d) {
                    memcpy(w, d, s->block_size);
                }
            }
            *key = index;
            g_hash_table_insert(s->dirty, key, w);
        }
        qemu_iovec_to_buf(qiov, done, w + in, n);
        done += n;
    }
    return 0;
}

static int coroutine_fn chunked_co_flush(BlockDriverState *bs)
{
    return 0;
}

static int chunked_reopen_prepare(BDRVReopenState *reopen_state, BlockReopenQueue *queue, Error **errp)
{
    return 0;
}

static const char *const chunked_strong_runtime_opts[] = {
    "url",
    "index",
    "overlay",
    NULL
};

static BlockDriver bdrv_chunked = {
    .format_name            = "chunked",
    .protocol_name          = "chunked",
    .instance_size          = sizeof(BDRVChunkedState),

    .bdrv_file_open         = chunked_file_open,
    .bdrv_close             = chunked_close,
    .bdrv_co_getlength      = chunked_co_getlength,

    .bdrv_co_preadv         = chunked_co_preadv,
    .bdrv_co_pwritev        = chunked_co_pwritev,
    .bdrv_co_flush_to_disk  = chunked_co_flush,
    .bdrv_reopen_prepare    = chunked_reopen_prepare,

    .strong_runtime_opts    = chunked_strong_runtime_opts,
};

static void bdrv_chunked_init(void)
{
    bdrv_register(&bdrv_chunked);
}

block_init(bdrv_chunked_init);
