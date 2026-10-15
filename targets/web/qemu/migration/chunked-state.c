/*
 * PowOS web: the incoming migration (the snapshot the browser resumes) streamed on demand, like the disk.
 *
 *   -incoming file:chunked:<base>/snapshots/<id>/state.index
 *
 * The state file is split by tools/chunk-disk.py into the disk's content-addressed chunks (<base>/chunks/<hh>/<hash>,
 * 256 KiB, zlib) plus a per-snapshot index (16-byte hash per block, zeros for a block of zeros) and state.json
 * ("size"). Reading it here instead of from a file preloaded into Emscripten's MEMFS means: no copy of the whole
 * state in the wasm heap next to guest RAM (it no longer fits once the guest has 1.5 GB), zero blocks are never
 * downloaded, unchanged chunks stay cached across snapshots, and loading overlaps the download (read-ahead).
 *
 * Natively (build-qemu-native.sh) <base> is a local directory and chunks are read as files.
 */
#include "qemu/osdep.h"
#include "qapi/error.h"
#include "io/channel.h"
#include "qom/object.h"
#include "qemu/main-loop.h"
#include "block/aio.h"
#include "chunked-state.h"
#include "channel.h"
#include <zlib.h>

#define BLOCK (256 * 1024)
#define HASH_BYTES 16
#define READAHEAD 24 /* blocks fetched ahead of the reader: 6 MiB in flight */

#ifdef __EMSCRIPTEN__
#include <emscripten.h>

EM_JS(int, state_http_get, (const char *url, void *dst, int cap), {
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
        console.error('chunked-state: ' + UTF8ToString(url) + ': ' + e);
        return -1;
    }
});

/* Same scheme as block/chunked.c: start the fetch now, the synchronous read later is served by the HTTP cache. */
EM_JS(void, state_prefetch, (const char *url), {
    var u = UTF8ToString(url);
    var seen = globalThis.__chunkedPrefetched || (globalThis.__chunkedPrefetched = new Set());
    if (seen.has(u)) return;
    seen.add(u);
    fetch(u).then(function (r) { return r.arrayBuffer(); }).catch(function () { seen.delete(u); });
});
#else
static void state_prefetch(const char *url)
{
}

static int state_http_get(const char *url, void *dst, int cap)
{
    int fd = open(url, O_RDONLY);
    ssize_t n, total = 0;

    if (fd < 0) {
        return -errno;
    }
    while (total < cap && (n = read(fd, (uint8_t *)dst + total, cap - total)) > 0) {
        total += n;
    }
    close(fd);
    return total;
}
#endif

#define TYPE_QIO_CHANNEL_CHUNKED_STATE "qio-channel-chunked-state"
OBJECT_DECLARE_SIMPLE_TYPE(QIOChannelChunkedState, QIO_CHANNEL_CHUNKED_STATE)

struct QIOChannelChunkedState {
    QIOChannel parent;
    char *base;            /* chunks live at <base>/chunks/ */
    uint8_t *hashes;       /* the index */
    uint64_t size;         /* of the state file */
    uint64_t blocks;
    uint64_t pos;          /* read position in the state file */
    int64_t cur;           /* block held in buf, -1 for none */
    uint8_t *buf;          /* that block, decompressed */
    uint8_t *compressed;
    int compressed_cap;
    uint64_t fetched_bytes;
};

static void chunk_url(QIOChannelChunkedState *s, uint64_t blk, char *url, size_t cap)
{
    const uint8_t *h = s->hashes + blk * HASH_BYTES;
    char hex[HASH_BYTES * 2 + 1];
    for (int i = 0; i < HASH_BYTES; i++) {
        snprintf(hex + i * 2, 3, "%02x", h[i]);
    }
    snprintf(url, cap, "%s/chunks/%.2s/%s", s->base, hex, hex);
}

static bool block_is_zero(QIOChannelChunkedState *s, uint64_t blk)
{
    static const uint8_t zero[HASH_BYTES];
    return memcmp(s->hashes + blk * HASH_BYTES, zero, HASH_BYTES) == 0;
}

static int load_block(QIOChannelChunkedState *s, uint64_t blk, Error **errp)
{
    char url[1024];
    uLongf len = BLOCK;
    int n;

    for (uint64_t a = blk + 1; a < s->blocks && a <= blk + READAHEAD; a++) {
        if (!block_is_zero(s, a)) {
            chunk_url(s, a, url, sizeof(url));
            state_prefetch(url);
        }
    }
    if (block_is_zero(s, blk)) {
        memset(s->buf, 0, BLOCK);
    } else {
        chunk_url(s, blk, url, sizeof(url));
        n = state_http_get(url, s->compressed, s->compressed_cap);
        if (n < 0 || uncompress(s->buf, &len, s->compressed, n) != Z_OK || len != BLOCK) {
            error_setg(errp, "chunked-state: block %" PRIu64 " (%s): fetch/inflate failed (%d)", blk, url, n);
            return -1;
        }
        s->fetched_bytes += n;
    }
    s->cur = blk;
    return 0;
}

static ssize_t chunked_state_readv(QIOChannel *ioc, const struct iovec *iov, size_t niov, int **fds, size_t *nfds,
                                   int flags, Error **errp)
{
    QIOChannelChunkedState *s = QIO_CHANNEL_CHUNKED_STATE(ioc);
    ssize_t done = 0;

    for (size_t i = 0; i < niov; i++) {
        size_t off = 0;
        while (off < iov[i].iov_len && s->pos < s->size) {
            uint64_t blk = s->pos / BLOCK;
            size_t in = s->pos % BLOCK;
            size_t n = MIN(iov[i].iov_len - off, MIN(BLOCK - in, s->size - s->pos));
            if ((int64_t)blk != s->cur && load_block(s, blk, errp) < 0) {
                return done ? done : -1;
            }
            memcpy((uint8_t *)iov[i].iov_base + off, s->buf + in, n);
            off += n;
            s->pos += n;
            done += n;
        }
    }
    if (s->pos == s->size && done > 0) {
        fprintf(stderr, "chunked-state: %" PRIu64 " MB state, %.1f MB fetched\n", s->size >> 20,
                s->fetched_bytes / 1e6);
    }
    return done; /* 0 = end of the stream */
}

static ssize_t chunked_state_writev(QIOChannel *ioc, const struct iovec *iov, size_t niov, int *fds, size_t nfds,
                                    int flags, Error **errp)
{
    error_setg(errp, "chunked-state is read-only");
    return -1;
}

static int chunked_state_close(QIOChannel *ioc, Error **errp)
{
    return 0;
}

static int chunked_state_set_blocking(QIOChannel *ioc, bool enabled, Error **errp)
{
    return 0;
}

static gboolean always_ready(GSource *src, gint *timeout)
{
    *timeout = 0;
    return TRUE;
}

static gboolean dispatch_ready(GSource *src, GSourceFunc cb, gpointer data)
{
    QIOChannelFunc func = (QIOChannelFunc)cb;
    return func((QIOChannel *)((void **)(src + 1))[0], G_IO_IN, data);
}

static GSourceFuncs ready_funcs = { .prepare = always_ready, .check = NULL, .dispatch = dispatch_ready };

/* Reads never block: the source is always ready. */
static GSource *chunked_state_create_watch(QIOChannel *ioc, GIOCondition condition)
{
    GSource *src = g_source_new(&ready_funcs, sizeof(GSource) + sizeof(void *));
    ((void **)(src + 1))[0] = ioc;
    return src;
}

static void chunked_state_finalize(Object *obj)
{
    QIOChannelChunkedState *s = QIO_CHANNEL_CHUNKED_STATE(obj);
    g_free(s->base);
    g_free(s->hashes);
    g_free(s->buf);
    g_free(s->compressed);
}

static void chunked_state_class_init(ObjectClass *klass, void *data)
{
    QIOChannelClass *ioc_klass = QIO_CHANNEL_CLASS(klass);
    ioc_klass->io_readv = chunked_state_readv;
    ioc_klass->io_writev = chunked_state_writev;
    ioc_klass->io_close = chunked_state_close;
    ioc_klass->io_set_blocking = chunked_state_set_blocking;
    ioc_klass->io_create_watch = chunked_state_create_watch;
}

static const TypeInfo chunked_state_info = {
    .parent = TYPE_QIO_CHANNEL,
    .name = TYPE_QIO_CHANNEL_CHUNKED_STATE,
    .instance_size = sizeof(QIOChannelChunkedState),
    .instance_finalize = chunked_state_finalize,
    .class_init = chunked_state_class_init,
};

static void chunked_state_register_types(void)
{
    type_register_static(&chunked_state_info);
}
type_init(chunked_state_register_types);

/* index = <base>/snapshots/<id>/state.index; its manifest is state.json next to it. */
QIOChannel *chunked_state_open(const char *index, Error **errp)
{
    g_autoptr(QIOChannelChunkedState) s = QIO_CHANNEL_CHUNKED_STATE(object_new(TYPE_QIO_CHANNEL_CHUNKED_STATE));
    const char *cut = strstr(index, "/snapshots/");
    g_autofree char *json_url = NULL;
    char json[4096];
    const char *p;
    int n;

    if (!cut || !g_str_has_suffix(index, ".index")) {
        error_setg(errp, "chunked-state: expected <base>/snapshots/<id>/state.index, got %s", index);
        return NULL;
    }
    s->base = g_strndup(index, cut - index);
    json_url = g_strdup_printf("%.*s.json", (int)(strlen(index) - strlen(".index")), index);
    n = state_http_get(json_url, json, sizeof(json) - 1);
    if (n <= 0) {
        error_setg(errp, "chunked-state: %s: fetch failed (%d)", json_url, n);
        return NULL;
    }
    json[n] = 0;
    p = strstr(json, "\"size\"");
    if (!p || !(p = strchr(p, ':')) || (s->size = g_ascii_strtoull(p + 1, NULL, 10)) == 0) {
        error_setg(errp, "chunked-state: %s: no size", json_url);
        return NULL;
    }
    s->blocks = DIV_ROUND_UP(s->size, BLOCK);
    s->hashes = g_malloc(s->blocks * HASH_BYTES);
    n = state_http_get(index, s->hashes, s->blocks * HASH_BYTES);
    if (n != (int)(s->blocks * HASH_BYTES)) {
        error_setg(errp, "chunked-state: %s: %d bytes, expected %" PRIu64, index, n, s->blocks * HASH_BYTES);
        return NULL;
    }
    s->buf = g_malloc(BLOCK);
    s->compressed_cap = compressBound(BLOCK);
    s->compressed = g_malloc(s->compressed_cap);
    s->cur = -1;
    qio_channel_set_name(QIO_CHANNEL(s), "migration-chunked-state");
    return QIO_CHANNEL(g_steal_pointer(&s));
}
