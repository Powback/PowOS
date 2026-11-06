/* PowOS: direct scanout of a window task's client buffer - see direct_scanout.h and
 * docs/research/window-task-direct-scanout.md (step 2: the app side; the producer side is KWin, step 4). */
#include "direct_scanout.h"

#include <android/hardware_buffer.h>
#include <android/log.h>
#include <android/surface_control.h>
#include <dlfcn.h>
#include <poll.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/system_properties.h>
#include <unistd.h>

#include "anw_hidden.h"   /* native_handle_t */

#define TAG "Andromarchy"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define FOURCC_XR24 0x34325258u
#define FOURCC_AR24 0x34325241u
#define MOD_LINEAR 0ull
#define MOD_INVALID 0x00ffffffffffffffull
#define HAL_BGRA_8888 5          /* gralloc's twin of DRM XR24/AR24 (bytes B G R X) */
#define HANDLE_CLONE 3           /* vndk CreateFromHandleMethod CLONE (= GraphicBuffer::CLONE_HANDLE); 1 is refused */
#define MAX_IDS 8
#define MAX_REL 16

typedef const native_handle_t *(*pfn_getNativeHandle)(const AHardwareBuffer *);
typedef int (*pfn_createFromHandle)(const AHardwareBuffer_Desc *, const native_handle_t *, int32_t, AHardwareBuffer **);

struct slot { bool used; uint32_t id; AHardwareBuffer *ahb; };

struct direct_state {
    pthread_mutex_t lock;
    ASurfaceControl *child;
    ANativeWindow *child_of;
    bool shown;
    bool dead;            /* refused for good on this surface */
    bool tested;          /* the self-test passed once */
    struct slot slots[MAX_IDS];
    uint32_t rel[MAX_REL];
    int rel_n;
    int pending;          /* transactions whose OnComplete hasn't run */
    uint32_t on_screen;   /* the id SurfaceFlinger shows (0 none) */
    void (*release_cb)(void *, uint32_t);   /* direct_set_release_cb: releases sent from the callback at once */
    void *release_ud;
    bool has_on_screen;
    float vote;           /* direct_set_vote: the rate the child should vote for (0 none) */
    float voted;          /* what the child votes now (a new child: 0) */
};

struct txn_ctx { struct direct_state *d; uint32_t prev; bool has_prev; };

bool direct_flag(void)
{
    char v[PROP_VALUE_MAX] = "";
    __system_property_get("debug.powos.direct_scanout", v);
    return v[0] == '1';
}

void direct_set_release_cb(struct direct_state *d, void (*cb)(void *ud, uint32_t id), void *ud)
{
    if (!d)
        return;
    pthread_mutex_lock(&d->lock);
    d->release_ud = ud;
    d->release_cb = cb;
    pthread_mutex_unlock(&d->lock);
}

struct direct_state *direct_new(void)
{
    struct direct_state *d = calloc(1, sizeof(*d));
    if (d)
        pthread_mutex_init(&d->lock, NULL);
    return d;
}

static void push_release(struct direct_state *d, uint32_t id)
{
    if (d->rel_n < MAX_REL)
        d->rel[d->rel_n++] = id;
}

/* SurfaceFlinger's callback (binder thread): the buffer this transaction replaced is free once its release fence
 * signals - waited here (bounded), then queued for the render thread to send as INPUT_TYPE_DIRECT_RELEASE. */
static void on_complete(void *c, ASurfaceTransactionStats *st)
{
    struct txn_ctx *x = c;
    struct direct_state *d = x->d;
    if (x->has_prev) {
        int f = d->child ? ASurfaceTransactionStats_getPreviousReleaseFenceFd(st, d->child) : -1;
        if (f >= 0) {
            struct pollfd p = { .fd = f, .events = POLLIN };
            poll(&p, 1, 1000);
            close(f);
        }
    }
    /* At once, from here: queued for the render thread, a release waited for its NEXT frame - which needs a client
     * buffer free, so with Xwayland's 4 all held (KWin "held 4") the game ran at 2-3 fps (step 5, 11-05 19:44). */
    if (x->has_prev && d->release_cb)
        d->release_cb(d->release_ud, x->prev);
    pthread_mutex_lock(&d->lock);
    if (x->has_prev && !d->release_cb)
        push_release(d, x->prev);
    d->pending--;
    pthread_mutex_unlock(&d->lock);
    free(x);
}

static void apply(struct direct_state *d, ASurfaceTransaction *t, bool has_prev, uint32_t prev)
{
    struct txn_ctx *x = malloc(sizeof(*x));
    if (x) {
        *x = (struct txn_ctx){ d, prev, has_prev };
        pthread_mutex_lock(&d->lock);
        d->pending++;
        pthread_mutex_unlock(&d->lock);
        ASurfaceTransaction_setOnComplete(t, x, on_complete);
    }
    ASurfaceTransaction_apply(t);
    ASurfaceTransaction_delete(t);
}

/* The client's dma-buf as an AHardwareBuffer: a template of the same size/format from gralloc, its handle cloned with
 * fd = the client's. QTI's linear BGRA_8888 pitch for the width must equal the client's (1116 -> 1152 px = 4608 B, as
 * turnip's): no stride override. NULL: refused. */
static AHardwareBuffer *wrap(const struct direct_frame *f, int dmabuf)
{
    static pfn_getNativeHandle gh;
    static pfn_createFromHandle mk;
    if (!gh || !mk) {
        void *lib = dlopen("libnativewindow.so", RTLD_NOW);
        gh = lib ? (pfn_getNativeHandle)dlsym(lib, "AHardwareBuffer_getNativeHandle") : NULL;
        mk = lib ? (pfn_createFromHandle)dlsym(lib, "AHardwareBuffer_createFromHandle") : NULL;
        if (!gh || !mk) { LOGE("direct: no AHardwareBuffer_getNativeHandle/createFromHandle"); return NULL; }
    }
    AHardwareBuffer_Desc desc = { .width = f->width, .height = f->height, .layers = 1, .format = HAL_BGRA_8888,
        .usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_COMPOSER_OVERLAY |
                 AHARDWAREBUFFER_USAGE_CPU_READ_RARELY /* keeps QTI gralloc linear, no UBWC */ };
    AHardwareBuffer *tb = NULL;
    if (AHardwareBuffer_allocate(&desc, &tb) != 0) { LOGE("direct: template allocate failed"); return NULL; }
    AHardwareBuffer_describe(tb, &desc);
    AHardwareBuffer *out = NULL;
    const native_handle_t *th = gh(tb);
    if (desc.stride * 4 != f->pitch || !th || th->numFds != 2) {
        LOGE("direct: template pitch %u / %d fds vs client pitch %u - refused", desc.stride * 4, th ? th->numFds : -1,
             f->pitch);
    } else {
        size_t bytes = sizeof(native_handle_t) + sizeof(int) * (size_t)(th->numFds + th->numInts);
        native_handle_t *c = malloc(bytes);
        if (c) {
            memcpy(c, th, bytes);
            c->data[0] = dmabuf;   /* QTI private_handle_t: fd, then fd_metadata (the template's: no UBWC, crop) */
            int r = mk(&desc, c, HANDLE_CLONE, &out);
            if (r != 0) { LOGE("direct: createFromHandle %d", r); out = NULL; }
            free(c);
        }
    }
    AHardwareBuffer_release(tb);
    return out;
}

/* First buffer of a surface: the gralloc view of the clone must read what the dma-buf holds (mapper mapped the right
 * fd at the right offset/stride). Two rows compared. */
static bool self_test(AHardwareBuffer *b, int dmabuf, const struct direct_frame *f)
{
    size_t len = (size_t)f->pitch * f->height;
    uint8_t *m = mmap(NULL, len, PROT_READ, MAP_SHARED, dmabuf, 0);
    if (m == MAP_FAILED) { LOGE("direct: self-test mmap failed"); return false; }
    void *p = NULL;
    bool ok = false;
    if (AHardwareBuffer_lock(b, AHARDWAREBUFFER_USAGE_CPU_READ_RARELY, -1, NULL, &p) == 0 && p) {
        AHardwareBuffer_Desc dd;
        AHardwareBuffer_describe(b, &dd);
        uint32_t rows[2] = { 0, f->height / 2 };
        ok = dd.stride * 4 == f->pitch;
        for (int i = 0; ok && i < 2; i++)
            ok = !memcmp((uint8_t *)p + (size_t)rows[i] * f->pitch, m + (size_t)rows[i] * f->pitch, f->width * 4);
        AHardwareBuffer_unlock(b, NULL);
    }
    munmap(m, len);
    LOGI("direct: self-test %s (%ux%u pitch %u)", ok ? "passed" : "FAILED", f->width, f->height, f->pitch);
    return ok;
}

static struct slot *slot_of(struct direct_state *d, uint32_t id)
{
    for (int i = 0; i < MAX_IDS; i++)
        if (d->slots[i].used && d->slots[i].id == id)
            return &d->slots[i];
    return NULL;
}

static void forget(struct direct_state *d, struct slot *s)
{
    if (s->ahb)
        AHardwareBuffer_release(s->ahb);   /* SurfaceFlinger holds its own reference while it still shows it */
    memset(s, 0, sizeof(*s));
}

int direct_present(struct direct_state *d, ANativeWindow *win, const struct direct_frame *f, int fence, int dmabuf)
{
    int rc = -1;
    if (d->dead) {
        rc = -2;   /* refused for good earlier (a reconnect offered again): the caller turns direct off again */
        goto out;
    }
    if (f->flags & DIRECT_FLAG_FORGET) {
        struct slot *s = slot_of(d, f->id);
        if (s) forget(d, s);
        goto out;
    }
    if ((f->fourcc != FOURCC_XR24 && f->fourcc != FOURCC_AR24) || f->offset != 0 ||
        /* HACK: an implicit modifier (INVALID) is taken as linear - the kwin 0057 probe saw turnip's WSI images linear
         * with it. Real fix: KWin sends the explicit modifier (linux-dmabuf v4 feedback) and anything else composites. */
        (f->modifier != MOD_LINEAR && f->modifier != MOD_INVALID)) {
        LOGE("direct: id %u layout fourcc %08x offset %u modifier %llx - this buffer refused", f->id, f->fourcc,
             f->offset, (unsigned long long)f->modifier);
        rc = -3;   /* this buffer's layout, not the path: the client's next buffers may be fine */
        goto out;
    }
    struct slot *s = slot_of(d, f->id);
    if (!s) {
        if (dmabuf < 0) { LOGE("direct: id %u without its buffer", f->id); goto out; }
        for (int i = 0; i < MAX_IDS && !s; i++)
            if (!d->slots[i].used) s = &d->slots[i];
        if (!s) { LOGE("direct: more than %d client buffers - refused", MAX_IDS); d->dead = true; rc = -2; goto out; }
        AHardwareBuffer *b = wrap(f, dmabuf);
        if (!b) {
            /* One buffer gralloc won't take (pitch, or createFromHandle 3 = BAD_VALUE: Xwayland's own AR24 linear
             * window pixmap that a game task shows before its first Present flip, 11-06 - the turnip XR24 flips right
             * after wrap fine). Not the path: refusing it for good kept Broforce composited all run (1 frame direct). */
            LOGE("direct: id %u (%ux%u fourcc %08x modifier %llx pitch %u) - this buffer refused", f->id, f->width,
                 f->height, f->fourcc, (unsigned long long)f->modifier, f->pitch);
            rc = -3;
            goto out;
        }
        if (!d->tested && !self_test(b, dmabuf, f)) {
            AHardwareBuffer_release(b);
            d->dead = true; rc = -2;   /* gralloc's view of a dma-buf is wrong: the path itself, for good */
            goto out;
        }
        d->tested = true;
        *s = (struct slot){ true, f->id, b };
    }
    if (!d->child || d->child_of != win) {
        if (d->child) ASurfaceControl_release(d->child);
        d->child = ASurfaceControl_createFromWindow(win, "powos-direct");
        d->child_of = win;
        d->voted = 0.0f;
        if (!d->child) { LOGE("direct: no child surface"); d->dead = true; rc = -2; goto out; }
    }
    ASurfaceTransaction *t = ASurfaceTransaction_create();
    ASurfaceTransaction_setBuffer(t, d->child, s->ahb, fence);
    fence = -1;   /* the transaction owns it */
    ASurfaceTransaction_setBufferTransparency(t, d->child, ASURFACE_TRANSACTION_TRANSPARENCY_OPAQUE);
    ASurfaceTransaction_setZOrder(t, d->child, 1);
    ASurfaceTransaction_setVisibility(t, d->child, ASURFACE_TRANSACTION_VISIBILITY_SHOW);
    if (d->vote != d->voted) {
        /* The layer that updates votes itself too (it inherits the SurfaceView's vote; ColorOS's touch idle picks its
         * "app request" per layer: PowosWindowActivity.surfaceVote, sf-latch-60). The mode is already the rate's. */
        ASurfaceTransaction_setFrameRate(t, d->child, d->vote, ANATIVEWINDOW_FRAME_RATE_COMPATIBILITY_DEFAULT);
        d->voted = d->vote;
    }
    bool had = d->has_on_screen;
    uint32_t prev = d->on_screen;
    d->on_screen = f->id; d->has_on_screen = true; d->shown = true;
    apply(d, t, had && prev != f->id, prev);
    rc = 0;
out:
    if (fence >= 0) close(fence);
    if (dmabuf >= 0) close(dmabuf);   /* gralloc's clone holds its own dup */
    return rc;
}

void direct_set_vote(struct direct_state *d, float hz)
{
    if (d)
        d->vote = hz;
}

void direct_hide(struct direct_state *d)
{
    if (!d || !d->child || !d->shown)
        return;
    /* HACK: the composited frame was queued on the BufferQueue first, the child hides in its own transaction after -
     * for a frame or so the last direct frame may still cover the new composited one (never black). Real fix (doc
     * step 3): queue that frame through ASurfaceTransaction too, so show/hide and the buffer switch are one. */
    ASurfaceTransaction *t = ASurfaceTransaction_create();
    ASurfaceTransaction_setVisibility(t, d->child, ASURFACE_TRANSACTION_VISIBILITY_HIDE);
    apply(d, t, false, 0);   /* the hidden child keeps its buffer: released when the next direct frame replaces it */
    d->shown = false;
}

int direct_take_release(struct direct_state *d, uint32_t *id)
{
    if (!d)
        return 0;
    int r = 0;
    pthread_mutex_lock(&d->lock);
    if (d->rel_n > 0) {
        *id = d->rel[0];
        memmove(d->rel, d->rel + 1, sizeof(d->rel[0]) * (size_t)--d->rel_n);
        r = 1;
    }
    pthread_mutex_unlock(&d->lock);
    return r;
}

void direct_reset(struct direct_state *d)
{
    if (!d)
        return;
    direct_hide(d);
    for (int i = 0; i < MAX_IDS; i++)
        if (d->slots[i].used) forget(d, &d->slots[i]);
    pthread_mutex_lock(&d->lock);
    d->rel_n = 0;   /* a new producer connection: old ids mean nothing */
    d->has_on_screen = false;
    pthread_mutex_unlock(&d->lock);
    /* d->dead stays: a refusal (mapper, self-test, layout) holds for the surface's lifetime */
}

void direct_free(struct direct_state *d)
{
    if (!d)
        return;
    direct_reset(d);
    if (d->child) {
        ASurfaceTransaction *t = ASurfaceTransaction_create();
        ASurfaceTransaction_reparent(t, d->child, NULL);
        apply(d, t, false, 0);
    }
    /* OnComplete callbacks reference d: wait them out (bounded). */
    for (int i = 0; i < 100; i++) {
        pthread_mutex_lock(&d->lock);
        int p = d->pending;
        pthread_mutex_unlock(&d->lock);
        if (p <= 0) break;
        usleep(5000);
    }
    if (d->pending > 0) {
        /* HACK: SurfaceFlinger never answered (it died?): leak d rather than free memory a late callback writes.
         * Real fix: refcount d from each txn_ctx. */
        LOGE("direct: %d transactions never completed, leaking the state", d->pending);
        return;
    }
    if (d->child) ASurfaceControl_release(d->child);
    pthread_mutex_destroy(&d->lock);
    free(d);
}
