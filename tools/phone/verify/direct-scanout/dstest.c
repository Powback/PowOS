/* dstest.c: direct-scanout step-1 self-test (docs/research/window-task-direct-scanout.md, board task
 * broforce-fps-low-cpu-bound-under-fex). Loaded by DsTest.java under app_process as root on the phone.
 *
 * The question it answers: does this device's QTI mapper + HWC accept a gralloc buffer CLONED from a template
 * AHardwareBuffer with its dma-buf fd swapped for a foreign one (a Broforce-shaped 1116x2484 XR24 linear dma-buf,
 * pitch 4608, from the system dma-heap - what turnip-kgsl gives the game), shown on a child ASurfaceControl?
 *   1. template AHardwareBuffer (format 5 = BGRA_8888, the gralloc twin of DRM XR24's byte order), its native handle
 *   2. a dma-heap dma-buf of the client's size, a known pattern written through mmap
 *   3. clone the handle with fd = that dma-buf, AHardwareBuffer_createFromHandle(CLONE) = mapper importBuffer;
 *      release the template (the clone must live on its own)
 *   4. present on a child ASurfaceControl, no CPU lock first ("SHOWN": the Mac takes dumpsys SurfaceFlinger + a
 *      screencap while it holds)
 *   5. flip between two such clones for a few seconds, counting OnComplete callbacks and release fences
 *   6. CPU-lock the clone and compare every pixel with the pattern (mapper lock path on the foreign fd)
 * Prints one "RESULT key=value" line per measurement, "SHOWN"/"FLIPPING"/"DONE" markers for the phone script.
 * args: size=fit|keep (the clone's size field: the dma-buf's real size, or the template's), hold=S, flip=S,
 *       pitch=N (bytes, default 4608), w=N h=N (default 1116x2484) */
#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/surface_control.h>
#include <android/surface_control_jni.h>
#include <linux/dma-heap.h>
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <time.h>

typedef struct native_handle {
    int version, numFds, numInts;
    int data[0];
} native_handle_t;

typedef const native_handle_t *(*pfn_getNativeHandle)(const AHardwareBuffer *);
typedef int (*pfn_createFromHandle)(const AHardwareBuffer_Desc *, const native_handle_t *, int32_t, AHardwareBuffer **);

#define P(...) do { printf(__VA_ARGS__); fflush(stdout); } while (0)

static uint32_t W = 1116, H = 2484, PITCH = 4608;

/* XR24 (DRM_FORMAT_XRGB8888): a little-endian 0xXXRRGGBB word, bytes B G R X. */
static uint32_t pat(int b, uint32_t x, uint32_t y)
{
    static const uint32_t bars[8] = {0xffffff, 0xffff00, 0x00ffff, 0x00ff00, 0xff00ff, 0xff0000, 0x0000ff, 0x000000};
    uint32_t rgb;
    if (y < H / 2) rgb = bars[x * 8 / W];
    else rgb = ((x & 255) << 16) | ((y & 255) << 8) | (((x + y) >> 3) & 255);
    if (b) rgb ^= 0xffffff;
    /* buffer A: X = 0xff; buffer B: X = 0x00 (the layer is OPAQUE: X must be ignored either way) */
    return (b ? 0u : 0xff000000u) | rgb;
}

static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }

static int heap_alloc(size_t len)
{
    static const char *heaps[] = {"/dev/dma_heap/system", "/dev/dma_heap/qcom,system", NULL};
    for (int i = 0; heaps[i]; i++) {
        int h = open(heaps[i], O_RDONLY | O_CLOEXEC);
        if (h < 0) continue;
        struct dma_heap_allocation_data a = {.len = len, .fd_flags = O_RDWR | O_CLOEXEC};
        int r = ioctl(h, DMA_HEAP_IOCTL_ALLOC, &a);
        close(h);
        if (r == 0) { P("RESULT heap=%s len=%zu\n", heaps[i], len); return (int)a.fd; }
        P("heap %s alloc failed\n", heaps[i]);
    }
    return -1;
}

static int fill(int fd, size_t len, int b)
{
    uint8_t *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) return -1;
    struct dma_buf_sync s = {.flags = DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE};
    ioctl(fd, DMA_BUF_IOCTL_SYNC, &s);
    for (uint32_t y = 0; y < H; y++) {
        uint32_t *row = (uint32_t *)(m + (size_t)y * PITCH);
        for (uint32_t x = 0; x < W; x++) row[x] = pat(b, x, y);
        memset(row + W, 0x5a, PITCH - W * 4);   /* pitch padding: garbage, must never show */
    }
    s.flags = DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE;
    ioctl(fd, DMA_BUF_IOCTL_SYNC, &s);
    munmap(m, len);
    return 0;
}

struct ctx { atomic_int completes, releases, rel_err; };
static void on_complete(void *c, ASurfaceTransactionStats *st)
{
    struct ctx *x = c;
    atomic_fetch_add(&x->completes, 1);
    ASurfaceControl **scs = NULL; size_t n = 0;
    ASurfaceTransactionStats_getASurfaceControls(st, &scs, &n);
    for (size_t i = 0; i < n; i++) {
        int f = ASurfaceTransactionStats_getPreviousReleaseFenceFd(st, scs[i]);
        if (f >= 0) {
            struct pollfd p = {.fd = f, .events = POLLIN};
            if (poll(&p, 1, 1000) == 1) atomic_fetch_add(&x->releases, 1); else atomic_fetch_add(&x->rel_err, 1);
            close(f);
        }
    }
    ASurfaceTransactionStats_releaseASurfaceControls(scs);
}

/* clone <tmpl> with fd = dmabuf; size field (index si into the ints) = newsize when >= 0 */
static AHardwareBuffer *clone_ahb(pfn_createFromHandle mk, const native_handle_t *t, const AHardwareBuffer_Desc *d,
                                  int dmabuf, int si, long newsize)
{
    size_t bytes = sizeof(native_handle_t) + sizeof(int) * (t->numFds + t->numInts);
    native_handle_t *c = malloc(bytes);
    memcpy(c, t, bytes);
    c->data[0] = dmabuf;                 /* QTI private_handle_t: fd first, fd_metadata second (the template's) */
    if (si >= 0 && newsize >= 0) c->data[t->numFds + si] = (int)newsize;
    AHardwareBuffer *out = NULL;
    int r = mk(d, c, 1 /* AHARDWAREBUFFER_CREATE_FROM_HANDLE_METHOD_CLONE: our fds stay ours */, &out);
    free(c);
    P("RESULT import_rc=%d buffer=%s\n", r, out ? "ok" : "null");
    return r == 0 ? out : NULL;
}

static long cmp_lock(AHardwareBuffer *b, int which, long *first)
{
    AHardwareBuffer_Desc d; AHardwareBuffer_describe(b, &d);
    void *p = NULL;
    int r = AHardwareBuffer_lock(b, AHARDWAREBUFFER_USAGE_CPU_READ_RARELY, -1, NULL, &p);
    if (r != 0 || !p) { P("RESULT lock_rc=%d\n", r); return -1; }
    long bad = 0; *first = -1;
    for (uint32_t y = 0; y < H; y++) {
        const uint32_t *row = (const uint32_t *)((const uint8_t *)p + (size_t)y * d.stride * 4);
        for (uint32_t x = 0; x < W; x++)
            if (row[x] != pat(which, x, y)) { if (*first < 0) *first = (long)y * W + x; bad++; }
    }
    AHardwareBuffer_unlock(b, NULL);
    P("RESULT lock_rc=0 lock_stride=%u\n", d.stride);
    return bad;
}

static int run(JNIEnv *env, jobject jsc, int argc, char **argv)
{
    int keep = 0; int hold = 3, flip = 3;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "size=keep")) keep = 1;
        else if (!strncmp(argv[i], "hold=", 5)) hold = atoi(argv[i] + 5);
        else if (!strncmp(argv[i], "flip=", 5)) flip = atoi(argv[i] + 5);
        else if (!strncmp(argv[i], "pitch=", 6)) PITCH = atoi(argv[i] + 6);
        else if (!strncmp(argv[i], "w=", 2)) W = atoi(argv[i] + 2);
        else if (!strncmp(argv[i], "h=", 2)) H = atoi(argv[i] + 2);
    }
    void *lib = dlopen("libnativewindow.so", RTLD_NOW);
    pfn_getNativeHandle gh = lib ? (pfn_getNativeHandle)dlsym(lib, "AHardwareBuffer_getNativeHandle") : NULL;
    pfn_createFromHandle mk = lib ? (pfn_createFromHandle)dlsym(lib, "AHardwareBuffer_createFromHandle") : NULL;
    P("RESULT dlsym getNativeHandle=%s createFromHandle=%s\n", gh ? "ok" : "MISSING", mk ? "ok" : "MISSING");
    if (!gh || !mk) return 10;

    /* 1. template */
    AHardwareBuffer_Desc d = {.width = W, .height = H, .layers = 1, .format = 5 /* B8G8R8A8 */,
        .usage = AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE | AHARDWAREBUFFER_USAGE_COMPOSER_OVERLAY |
                 AHARDWAREBUFFER_USAGE_CPU_READ_RARELY};
    AHardwareBuffer *tb = NULL;
    int r = AHardwareBuffer_allocate(&d, &tb);
    P("RESULT template_alloc_rc=%d format=%u\n", r, d.format);
    if (r) return 11;
    AHardwareBuffer_describe(tb, &d);
    P("RESULT template_stride_px=%u pitch_bytes=%u client_pitch=%u\n", d.stride, d.stride * 4, PITCH);
    const native_handle_t *th = gh(tb);
    P("RESULT handle numFds=%d numInts=%d ints=", th->numFds, th->numInts);
    for (int i = 0; i < th->numInts; i++) P("%s%d", i ? "," : "", th->data[th->numFds + i]);
    P("\n");
    size_t len = ((size_t)PITCH * H + 4095) & ~(size_t)4095;   /* turnip's linear image: pitch * h, page-rounded */
    /* the size field: the first int that is >= pitch*h and within 1 MiB of it */
    int si = -1; long tsize = -1;
    for (int i = 0; i < th->numInts; i++) {
        long v = (unsigned)th->data[th->numFds + i];
        if (v >= (long)PITCH * H && v < (long)PITCH * H + (1 << 20)) { si = i; tsize = v; break; }
    }
    P("RESULT size_field_index=%d template_size=%ld client_size=%zu mode=%s\n", si, tsize, len, keep ? "keep" : "fit");
    if (d.stride * 4 != PITCH) P("RESULT WARN template pitch %u != client pitch %u (no stride override in this test)\n", d.stride * 4, PITCH);

    /* 2. client-like dma-bufs */
    int fa = heap_alloc(len), fb = heap_alloc(len);
    if (fa < 0 || fb < 0) return 12;
    if (fill(fa, len, 0) || fill(fb, len, 1)) { P("RESULT mmap_fill=FAIL\n"); return 13; }

    /* 3. clones */
    long ns = keep ? -1 : (long)len;
    AHardwareBuffer *ba = clone_ahb(mk, th, &d, fa, si, ns);
    AHardwareBuffer *bb = clone_ahb(mk, th, &d, fb, si, ns);
    AHardwareBuffer_release(tb);   /* the clones must not depend on the template */
    close(fa); close(fb);          /* CLONE dup'd them: the gralloc buffers own their copies */
    if (!ba || !bb) return 14;

    /* 4. present A on a child of the Java root layer, no CPU lock first */
    ASurfaceControl *root = ASurfaceControl_fromJava(env, jsc);
    ASurfaceControl *ch = ASurfaceControl_create(root, "powos-ds-clone");
    struct ctx cx = {0};
    ASurfaceTransaction *t = ASurfaceTransaction_create();
    ASurfaceTransaction_setBuffer(t, ch, ba, -1);
    ASurfaceTransaction_setBufferTransparency(t, ch, ASURFACE_TRANSACTION_TRANSPARENCY_OPAQUE);
    ASurfaceTransaction_setVisibility(t, ch, ASURFACE_TRANSACTION_VISIBILITY_SHOW);
    ASurfaceTransaction_setZOrder(t, ch, 1);
    ASurfaceTransaction_setOnComplete(t, &cx, on_complete);
    double t0 = now_ms();
    ASurfaceTransaction_apply(t);
    ASurfaceTransaction_delete(t);
    while (atomic_load(&cx.completes) < 1 && now_ms() - t0 < 3000) usleep(2000);
    P("RESULT first_complete_ms=%.1f completes=%d\n", now_ms() - t0, atomic_load(&cx.completes));
    P("SHOWN\n");
    sleep(hold);

    /* 5. flip A/B for <flip> s, one transaction per ~16.7 ms */
    P("FLIPPING\n");
    int c0 = atomic_load(&cx.completes), sent = 0;
    t0 = now_ms();
    while (now_ms() - t0 < flip * 1000.0) {
        t = ASurfaceTransaction_create();
        ASurfaceTransaction_setBuffer(t, ch, (sent & 1) ? ba : bb, -1);
        ASurfaceTransaction_setOnComplete(t, &cx, on_complete);
        ASurfaceTransaction_apply(t);
        ASurfaceTransaction_delete(t);
        sent++;
        usleep(16667);
    }
    usleep(200000);
    double el = now_ms() - t0;
    P("RESULT flip_sent=%d flip_completes=%d releases=%d release_timeouts=%d per_s=%.1f\n", sent,
      atomic_load(&cx.completes) - c0, atomic_load(&cx.releases), atomic_load(&cx.rel_err),
      (atomic_load(&cx.completes) - c0) * 1000.0 / el);
    /* end on A so the "end" capture knows what it should show */
    t = ASurfaceTransaction_create();
    ASurfaceTransaction_setBuffer(t, ch, ba, -1);
    ASurfaceTransaction_apply(t);
    ASurfaceTransaction_delete(t);
    usleep(300000);
    P("SHOWN_END\n");
    sleep(hold);

    /* 6. CPU lock self-test on the foreign fd */
    long first, bad = cmp_lock(ba, 0, &first);
    P("RESULT lock_mismatch=%ld first=%ld\n", bad, first);
    long bad2 = cmp_lock(bb, 1, &first);
    P("RESULT lock_mismatch_b=%ld first=%ld\n", bad2, first);

    t = ASurfaceTransaction_create();
    ASurfaceTransaction_setVisibility(t, ch, ASURFACE_TRANSACTION_VISIBILITY_HIDE);
    ASurfaceTransaction_reparent(t, ch, NULL);
    ASurfaceTransaction_apply(t);
    ASurfaceTransaction_delete(t);
    ASurfaceControl_release(ch);
    ASurfaceControl_release(root);
    usleep(100000);
    AHardwareBuffer_release(ba);
    AHardwareBuffer_release(bb);
    P("DONE\n");
    return 0;
}

JNIEXPORT jint JNICALL Java_DsTest_run(JNIEnv *env, jclass cls, jobject sc, jobjectArray jargs)
{
    (void)cls;
    int n = (*env)->GetArrayLength(env, jargs);
    char *argv[16]; if (n > 16) n = 16;
    for (int i = 0; i < n; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, jargs, i);
        const char *c = (*env)->GetStringUTFChars(env, s, NULL);
        argv[i] = strdup(c);
        (*env)->ReleaseStringUTFChars(env, s, c);
    }
    return run(env, sc, n, argv);
}
