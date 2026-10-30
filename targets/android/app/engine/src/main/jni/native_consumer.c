#define _GNU_SOURCE
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <errno.h>
#include <poll.h>
#include <jni.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>

#include "anw_hidden.h"
#include "camera_service.h"
#include "display_consumer.h"
#include "native_audio.h"
#include "protocol.h"
#include "socket_utils.h"

#define TAG "Andromarchy"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define PIXEL_FORMAT_RGBA_8888 1
#define MAX_COLLECT_BUFS 8

static int cfg_custom_width = 0;
static int cfg_custom_height = 0;

/* Saved JVM / activity reference for event-thread JNI callbacks. */
static JavaVM *g_jvm = NULL;
static jobject g_activity_obj = NULL;

static struct anw_api api;
static bool api_loaded = false;
static void on_fallback(void *userdata);

static void on_exit_fallback(void *userdata);
/* PowOS: one per Android surface. g_state is the desktop (MainActivity: audio, camera, clipboard, keyboard
 * visibility); others are PowOS windows shown as their own Android tasks (PowosWindowActivity), surfaces of the same
 * display daemon with their own id - pixels and input only. See docs/powos-window-tasks.md. */
struct consumer_state {
    pthread_mutex_t lock;
    bool primary;
    uint32_t surface_id;     /* 0 for the desktop */
    ANativeWindow *window;
    display_ctx *ctx;
    pthread_t render_thread;
    volatile bool running;

    //Note: it is Deamon's Reconnect, not Fallback Flag
    //Fallback is maintained by display lib, and the consumer should not care about it.
    volatile bool need_reconnect;
    int select_failures;   /* consecutive select_dmabuf failures (render thread only) */

    int buf_count;
    int dmabuf_fds[MAX_COLLECT_BUFS];
    struct buf_info dmabuf_infos[MAX_COLLECT_BUFS];
    ANativeWindowBuffer *buf_anb[MAX_COLLECT_BUFS];

    int screen_w;
    int screen_h;
    /* PowOS: a window consumer's buffers at this size (the screen's), not its surface's: a floating window resizes
     * without new buffers (KWin draws the window at its real size from the top left; the crop shows the task's part).
     * 0: the surface's size. */
    int buffers_w;
    int buffers_h;
    /* The part of the buffers the surface shows (its size), queued as each buffer's crop - shown 1:1, never scaled.
     * 0: the whole buffer. Set from Java (nativeSetWindowCrop), read by the render thread. */
    volatile int crop_w;
    volatile int crop_h;

    /* PowOS: pre-rotation (protocol.h, struct bufs_ext). The buffers are screen_w x screen_h rotated by [pretransform]
     * (an OutputTransform kind 0-3: swapped for 1 and 3), queued with the Android buffer transform that undoes it, so
     * SurfaceFlinger needs no rotation of its own - on the inner panel (install orientation 270) that is HWC instead of
     * GPU composition every frame. It follows the surface's transform hint (rotation, fold: another display). */
    int pretransform;
    /* The geometry the collected buffers were made for: a reconnect with the same one reuses them (no enumeration
     * frames - fresh, never-drawn buffers - shown on every reconnect). recollect: they are no good any more. */
    int coll_w, coll_h, coll_kind;
    bool recollect;
    int foreign_bufs;       /* consecutive dequeues of a buffer not in the collected set */
    int mismatch_reconnects;/* consecutive reconnects for frames drawn with another rotation than the buffers' */
    /* Buffers never shown because the producer drew nothing into them (render thread only); logged rate-limited. */
    unsigned undrawn;
    unsigned undrawn_logged;
    int64_t undrawn_log_ms;

    // Latest display refresh rate (milli-Hz) reported from Java. Read on
    // (re)connect to seed the producer; updated live by nativeSetRefreshRate.
    volatile uint32_t refresh_mhz;

    // Event (output) thread
    pthread_t event_thread;
    volatile bool event_running;
    /* True while event_thread holds a started-but-not-yet-joined thread. stop only
     * signals (never joins -- on_fallback can run ON the event thread); the join is
     * deferred to the next start_event_thread() (create time), which runs on the
     * render thread and so cannot self-join. */
    bool event_thread_joinable;
};

static struct consumer_state g_state = {
    .lock = PTHREAD_MUTEX_INITIALIZER,
    .primary = true,
};

/* Connection config, set from Java via nativeConfigure() and read on each
 * (re)connect in do_connect(). Guarded by cfg_lock. */
static pthread_mutex_t cfg_lock = PTHREAD_MUTEX_INITIALIZER;
/* PowOS: fallback only; nativeConfigure() sets the real path from the app (SessionService.daemonSocket). */
static char cfg_socket_path[256] = "/data/data/com.powos.app/files/run/andromarchy/display_daemon.sock";
static bool cfg_use_root = false;
static bool cfg_use_compatible_bridge = false;
static int cfg_compatible_fd = -1;
static char cfg_helper_path[512] = "";
static char cfg_bridge_path[512] = "";

/* PowOS: the producer (KWin) said it can pre-rotate (a frame tagged FRAME_TAG_PRETRANSFORM). Until then - and again
 * after an untagged frame, an older KWin - every surface asks for normal buffers. Shared by all surfaces: the desktop's
 * first frame tells the window tasks too. */
static volatile bool g_producer_prerotates = false;

static bool motion_has_last = false;
static float motion_last_x = 0.0f;
static float motion_last_y = 0.0f;

static int collect_dmabufs(struct consumer_state *s)
{
    ANativeWindow *win = s->window;
    int target = s->buf_count;
    int found = 0;

    LOGI("collecting %d dma-bufs via dequeue/queue", target);

    for (int attempt = 0; attempt < target * 4 && found < target; attempt++) {
        ANativeWindowBuffer *anb = NULL;
        int fence = -1;
        if (api.dequeueBuffer(win, &anb, &fence) != 0 || !anb) {
            LOGE("dequeueBuffer failed on attempt %d", attempt);
            if (fence >= 0)
                close(fence);
            break;
        }
        if (fence >= 0)
            close(fence);   /* enumeration only: no need to wait the fence */

        if (!anb->handle || anb->handle->numFds < 1) {
            LOGE("dequeued buffer has no dma-buf handle on attempt %d", attempt);
            api.cancelBuffer(win, anb, -1);
            continue;
        }

        int fd = anb->handle->data[0];   /* first fd backs the dma-buf */
        int stride = anb->stride, width = anb->width, height = anb->height;

        /* deduplicate by ANativeWindowBuffer pointer (stable per queue slot) */
        bool dup_found = false;
        for (int i = 0; i < found; i++) {
            if (s->buf_anb[i] == anb) {
                dup_found = true;
                break;
            }
        }

        /* post it back so the next dequeue rotates to another slot */
        api.queueBuffer(win, anb, -1);

        if (dup_found)
            continue;

        int dup_fd = dup(fd);
        if (dup_fd < 0)
            continue;

        s->buf_anb[found] = anb;
        s->dmabuf_fds[found] = dup_fd;
        s->dmabuf_infos[found].stride = stride * 4;
        s->dmabuf_infos[found].width  = width;
        s->dmabuf_infos[found].height = height;
        s->dmabuf_infos[found].format = PIXEL_FORMAT_RGBA_8888;
        s->dmabuf_infos[found].modifier = 0;
        s->dmabuf_infos[found].offset = 0;
        LOGI("  buf[%d]: anb=%p fd=%d dup=%d %dx%d stride=%d",
             found, (void *)anb, fd, dup_fd, width, height, stride);
        found++;
    }

    if (found < target) {
        LOGE("only collected %d/%d", found, target);
        for (int i = 0; i < found; i++) {
            close(s->dmabuf_fds[i]);
            s->dmabuf_fds[i] = -1;
        }
        return -1;
    }

    s->buf_count = found;
    LOGI("collected %d dma-bufs", found);
    return 0;
}

static void cleanup_dmabufs(struct consumer_state *s)
{
    for (int i = 0; i < s->buf_count; i++) {
        if (s->dmabuf_fds[i] >= 0) {
            close(s->dmabuf_fds[i]);
            s->dmabuf_fds[i] = -1;
        }
    }
    s->buf_count = 0;
}

/* Report the current display refresh rate to the producer over the data
 * channel, reusing the InputEvent framing (see INPUT_TYPE_DISPLAY_REFRESH).
 * No-op when disconnected or rate unknown. */
static void send_refresh_rate(struct consumer_state *s)
{
    if (!s->ctx || s->refresh_mhz == 0)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_DISPLAY_REFRESH,
        .display = { .refresh_mhz = s->refresh_mhz },
    };
    push_input_event(s->ctx, &ev);
}

/*
 * Event thread: listens for output events (clipboard, etc.) from the producer
 * on the data_fd. Runs while s->event_running is true.
 */
static void *event_thread_func(void *arg)
{
    struct consumer_state *s = arg;
    LOGI("event thread started");

    JNIEnv *env = NULL;
    if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) != 0) {
        LOGE("event thread: AttachCurrentThread failed");
        return NULL;
    }

    /* Find classes/methods once */
    jclass ctxClass = (*env)->GetObjectClass(env, g_activity_obj);
    jmethodID setClipMethod = (*env)->GetMethodID(env, ctxClass, "nativeSetClipboardText", "(Ljava/lang/String;)V");
    if (!setClipMethod) {
        LOGE("event thread: nativeSetClipboardText not found");
        (*g_jvm)->DetachCurrentThread(g_jvm);
        return NULL;
    }
    /* PowOS: the Android keyboard follows text-field focus in the compositor (OUTPUT_TYPE_KEYBOARD). */
    jmethodID setKeyboardMethod = (*env)->GetMethodID(env, ctxClass, "nativeSetKeyboardVisible", "(Z)V");
    if (!setKeyboardMethod)
        (*env)->ExceptionClear(env);

    while (s->event_running) {
        if (!s->ctx) {
            usleep(50000);
            continue;
        }

        struct OutputEvent ev;
        int ret = poll_output_event(s->ctx, &ev, 500);
        if (ret <= 0)
            continue;

        if (ev.type == OUTPUT_TYPE_RESOURCES_REQUEST) {
            /* Producer is asking for a service's fds (e.g. camera). The display lib
             * matches the type against the registered services and sends the
             * pre-created fds back over SCM_RIGHTS. */
            handle_resource_request(s->ctx, &ev);
        } else if (ev.type == OUTPUT_TYPE_CLIPBOARD && ev.clipboard.size > 0) {
            char *buf = malloc(ev.clipboard.size + 1);
            if (!buf)
                continue;

            if (poll_output_event_extend_data(s->ctx, buf, ev.clipboard.size, 5000) == 1) {
                buf[ev.clipboard.size] = '\0';
                jstring jstr = (*env)->NewStringUTF(env, buf);
                if (jstr) {
                    (*env)->CallVoidMethod(env, g_activity_obj, setClipMethod, jstr);
                    (*env)->DeleteLocalRef(env, jstr);
                }
            }
            free(buf);
        } else if (ev.type == OUTPUT_TYPE_KEYBOARD) {
            if (setKeyboardMethod)
                (*env)->CallVoidMethod(env, g_activity_obj, setKeyboardMethod, (jboolean)(ev.keyboard.visible != 0));
        } else {
            /* Unknown or zero-length event: drain any trailing data if size > 0 */
            LOGI("event thread: unknown output event type=%u size=%u", ev.type, ev.clipboard.size);
        }
    }

    (*g_jvm)->DetachCurrentThread(g_jvm);
    LOGI("event thread stopped");
    return NULL;
}

static void join_event_thread(struct consumer_state *s)
{
    /* Idempotent. MUST be called only from a non-event thread (render / JNI teardown);
     * never from on_fallback (which may run on the event thread). */
    if (s->event_thread_joinable) {
        pthread_join(s->event_thread, NULL);
        s->event_thread_joinable = false;
    }
}

static void start_event_thread(struct consumer_state *s)
{
    if (s->event_running)
        return;
    /* Reap the previous stopped-but-unjoined thread before spawning a new one. Runs on
     * the render thread (on_exit_fallback), so this join can't self-deadlock. */
    join_event_thread(s);
    s->event_running = true;
    if (pthread_create(&s->event_thread, NULL, event_thread_func, s) == 0)
        s->event_thread_joinable = true;
    else
        s->event_running = false;
}

static void stop_event_thread(struct consumer_state *s)
{
    /* Signal only -- do NOT join here. enter_fallback()->on_fallback() can execute on
     * the event thread itself, so joining would self-deadlock. The handle stays in
     * event_thread (event_thread_joinable) and is reaped at create time by the next
     * start_event_thread() (or do_connect's reconnect path, both on the render
     * thread). */
    s->event_running = false;
}

/*
 * "Connect with root" handshake. The app cannot connect() to a root-owned
 * daemon socket directly, so it listens on a bridge socket, launches the bundled
 * helper through `su -c`, and the helper (as root) connects to the daemon and
 * passes the connected fd back over the bridge. Returns the received fd (caller
 * owns it) or -1 on failure.
 */
static int recv_fd_via_root_helper(const char *daemon_sock,
                                   const char *helper_path,
                                   const char *bridge_path)
{
    if (helper_path[0] == '\0' || bridge_path[0] == '\0') {
        LOGE("root helper: helper/bridge path not configured");
        return -1;
    }

    unlink(bridge_path);

    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) {
        LOGE("root helper: socket() failed: %s", strerror(errno));
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, bridge_path, sizeof(addr.sun_path) - 1);

    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        LOGE("root helper: bind(%s) failed: %s", bridge_path, strerror(errno));
        close(lfd);
        return -1;
    }
    /* Root helper runs in a different SELinux/uid context; make the socket file
     * reachable. (Root bypasses DAC, but be permissive anyway.) */
    chmod(bridge_path, 0777);

    if (listen(lfd, 1) < 0) {
        LOGE("root helper: listen() failed: %s", strerror(errno));
        close(lfd);
        unlink(bridge_path);
        return -1;
    }

    /* Build the command su runs: "<helper> <daemon_sock> <bridge_path>". */
    char inner[1100];
    snprintf(inner, sizeof(inner), "%s %s %s",
             helper_path, daemon_sock, bridge_path);

    pid_t pid = fork();
    if (pid < 0) {
        LOGE("root helper: fork() failed: %s", strerror(errno));
        close(lfd);
        unlink(bridge_path);
        return -1;
    }
    if (pid == 0) {
        execlp("su", "su", "-c", inner, (char *)NULL);
        _exit(127);   /* su not found / exec failed */
    }

    /* Wait for the helper to connect (root prompt may take a while). */
    int fd = -1;
    struct pollfd pfd = { .fd = lfd, .events = POLLIN };
    if (poll(&pfd, 1, 30000) > 0 && (pfd.revents & POLLIN)) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd >= 0) {
            char b;
            int got = 0;
            if (recv_fds(cfd, &b, 1, &fd, 1, &got) < 0 || got < 1)
                fd = -1;
            close(cfd);
        }
    } else {
        LOGE("root helper: timed out waiting for helper connection");
    }

    int status = 0;
    waitpid(pid, &status, 0);
    close(lfd);
    unlink(bridge_path);

    if (fd < 0)
        LOGE("root helper: did not receive daemon fd (su status=%d)", status);
    return fd;
}

/* AOSP system/window.h NATIVE_WINDOW_TRANSFORM_HINT: the transform SurfaceFlinger would apply to this surface's
 * buffers (the display's orientation, its install orientation included). */
#define ANW_QUERY_TRANSFORM_HINT 8

static int64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* The OutputTransform kind (protocol.h) the producer renders with for transform hint [hint]: logical (x, y) to
 * buffer (y, W - x) for hint ROT_270 is KWin's Rotate90 (HWUI's GetPreTransformMatrix for the same hint). */
static int kind_for_hint(int hint)
{
    switch (hint) {
    case ANATIVEWINDOW_TRANSFORM_ROTATE_90:  return 3;
    case ANATIVEWINDOW_TRANSFORM_ROTATE_180: return 2;
    case ANATIVEWINDOW_TRANSFORM_ROTATE_270: return 1;
    default:                                 return 0;   /* none, or a flip: not pre-rotated */
    }
}

/* The buffer transform SurfaceFlinger applies to show buffers drawn with [kind]: the hint's inverse (as HWUI's
 * InvertTransformToNative), so the composed transform is none. */
static int anw_transform_for_kind(int kind)
{
    static const int t[4] = { 0, ANATIVEWINDOW_TRANSFORM_ROTATE_90, ANATIVEWINDOW_TRANSFORM_ROTATE_180,
                              ANATIVEWINDOW_TRANSFORM_ROTATE_270 };
    return t[kind & 3];
}

static int query_transform_hint(struct consumer_state *s)
{
    int hint = 0;
    if (api.query(s->window, ANW_QUERY_TRANSFORM_HINT, &hint) != 0)
        return 0;
    return hint;
}

/* The pre-rotation this surface should have now. [bufs]: how many buffers it has - the request rides in a trailer
 * that only fits below MAX_BUFS (protocol.h). */
static int wanted_pretransform(struct consumer_state *s, int bufs)
{
    if (!g_producer_prerotates || bufs >= MAX_BUFS)
        return 0;
    return kind_for_hint(query_transform_hint(s));
}

/* A buffer the producer drew nothing into was not shown (cancelled: the surface keeps its last frame). Counted, and
 * logged at most every 5 s - a black or stale frame on screen used to come from queueing these. */
static void note_undrawn(struct consumer_state *s, const char *why)
{
    s->undrawn++;
    int64_t now = now_ms();
    if (now - s->undrawn_log_ms < 5000)
        return;
    LOGE("surface %u: %u buffer(s) not shown in %lld ms, %u in all (the producer drew nothing into them: %s)",
         s->surface_id, s->undrawn - s->undrawn_logged,
         (long long)(s->undrawn_log_ms ? now - s->undrawn_log_ms : 0), s->undrawn, why);
    s->undrawn_logged = s->undrawn;
    s->undrawn_log_ms = now;
}

static int do_connect(struct consumer_state *s)
{
    /* Snapshot the connection config for this attempt. */
    pthread_mutex_lock(&cfg_lock);
    bool use_root = cfg_use_root;
    bool use_compatible_bridge = cfg_use_compatible_bridge;
    bool compatible_fd_available = cfg_compatible_fd >= 0;
    char sock_path[sizeof(cfg_socket_path)];
    char helper_path[sizeof(cfg_helper_path)];
    char bridge_path[sizeof(cfg_bridge_path)];
    memcpy(sock_path, cfg_socket_path, sizeof(sock_path));
    memcpy(helper_path, cfg_helper_path, sizeof(helper_path));
    memcpy(bridge_path, cfg_bridge_path, sizeof(bridge_path));
    pthread_mutex_unlock(&cfg_lock);

    if (use_compatible_bridge && !compatible_fd_available) {
        LOGI("compatible bridge has not supplied a socket fd yet");
        return -1;
    }

    if (!s->primary) {
        if (use_compatible_bridge) {
            LOGE("surface %u: no window surfaces over the compatible bridge", s->surface_id);
            return -1;
        }
        /* The root helper's bridge socket is per connection. */
        char suffix[16];
        snprintf(suffix, sizeof(suffix), "-%u", s->surface_id);
        strncat(bridge_path, suffix, sizeof(bridge_path) - strlen(bridge_path) - 1);
    }
    const char *sock = sock_path;

    if (s->ctx) {
        if (s->primary)
            audio_set_ctx(NULL);   /* detach audio before the old ctx (and its fd) dies */
        stop_event_thread(s);
        join_event_thread(s);
        disconnect(s->ctx);
        s->ctx = NULL;
    }

    ANativeWindow *win = s->window;
    pthread_mutex_lock(&cfg_lock);
    int cw = cfg_custom_width;
    int ch = cfg_custom_height;
    pthread_mutex_unlock(&cfg_lock);

    if (s->buffers_w > 0 && s->buffers_h > 0) {
        s->screen_w = s->buffers_w;
        s->screen_h = s->buffers_h;
    } else if (cw > 0 && ch > 0) {
        s->screen_w = cw;
        s->screen_h = ch;
    } else {
       s->screen_w = ANativeWindow_getWidth(win);
       s->screen_h = ANativeWindow_getHeight(win);
    }

    /* PowOS: the buffers from the last connection, when they still fit (same size and rotation, none reallocated):
     * no new enumeration, whose never-drawn buffers would be shown for a moment (black) on every reconnect. */
    bool reuse = s->buf_count > 0 && !s->recollect && s->coll_w == s->screen_w && s->coll_h == s->screen_h;
    if (reuse && wanted_pretransform(s, s->buf_count) != s->coll_kind)
        reuse = false;

    if (!reuse) {
        cleanup_dmabufs(s);
        s->recollect = false;

        /* dequeueBuffer needs the window connected to an API first (ANativeWindow_lock
         * did this internally). Disconnect first so reconnect is idempotent. */
        anw_api_disconnect(win, ANW_API_CPU);
        if (anw_api_connect(win, ANW_API_CPU) != 0) {
            LOGE("api_connect(CPU) failed");
            return -1;
        }

        int min_undequeued = 0;
        api.query(win, ANATIVEWINDOW_QUERY_MIN_UNDEQUEUED_BUFFERS, &min_undequeued);
        int total = min_undequeued + 2;
        if (total > MAX_COLLECT_BUFS)
            total = MAX_COLLECT_BUFS;

        /* Pre-rotated (the hint, read after the connect that delivers it): the buffers are the logical size turned. */
        int kind = wanted_pretransform(s, total);
        int bw = (kind & 1) ? s->screen_h : s->screen_w;
        int bh = (kind & 1) ? s->screen_w : s->screen_h;
        ANativeWindow_setBuffersGeometry(win, bw, bh, AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM);
        ANativeWindow_setBuffersTransform(win, anw_transform_for_kind(kind));

        api.setBufferCount(win, total);

        s->buf_count = total;
        if (collect_dmabufs(s) < 0) {
            s->buf_count = 0;   /* closed: never reused */
            return -1;
        }
        s->pretransform = kind;
        s->coll_w = s->screen_w;
        s->coll_h = s->screen_h;
        s->coll_kind = kind;
    }

    LOGI("connecting to %s (%dx%d, %d bufs%s, pre-rotation %d for hint %d, root=%d, compatible=%d)", sock,
         s->screen_w, s->screen_h, s->buf_count, reuse ? " kept" : "", s->pretransform,
         query_transform_hint(s), use_root, use_compatible_bridge);

    if (use_compatible_bridge) {
        pthread_mutex_lock(&cfg_lock);
        /* Keep the Binder-supplied descriptor as a master copy. Each display
         * context owns a duplicate, while the Termux bridge keeps the actual
         * daemon connection alive across consumer reconnect attempts. */
        int compatible_fd = cfg_compatible_fd >= 0 ? dup(cfg_compatible_fd) : -1;
        pthread_mutex_unlock(&cfg_lock);
        if (compatible_fd < 0) {
            LOGE("could not duplicate compatible bridge socket fd: %s", strerror(errno));
            return -1;
        }
        if (connect_to_deamon_with_fd(&s->ctx, compatible_fd) < 0) {
            LOGE("connect_to_deamon_with_fd from compatible bridge failed");
            return -1;
        }
    } else if (use_root) {
        int ctrl_fd = recv_fd_via_root_helper(sock, helper_path, bridge_path);
        if (ctrl_fd < 0) {
            LOGE("root helper connect failed");
            return -1;
        }
        if (connect_to_deamon_surface(&s->ctx, ctrl_fd, s->surface_id) < 0) {
            LOGE("connect_to_deamon_surface failed");
            return -1;
        }
    } else if (connect_to_deamon_surface(&s->ctx, connect_unix(sock), s->surface_id) < 0) {
        LOGE("connect_to_deamon failed");
        return -1;
    }

    set_screen_info(s->ctx, s->screen_w, s->screen_h,
                    PIXEL_FORMAT_RGBA_8888, s->refresh_mhz);
    set_buffers_transform(s->ctx, (uint32_t)s->pretransform);
    push_dmabufs(s->ctx, s->dmabuf_fds, s->dmabuf_infos, s->buf_count);

    /* Register the camera service only when it was initialised (i.e. the user
     * enabled it in settings and granted CAMERA). allocate_services() stores this
     * pointer by reference, so it must outlive the ctx -> keep it static. The
     * producer drives it via RESOURCES_REQUEST (handled on the event thread). */
    if (s->primary && camera_service_is_ready()) {
        static struct service_info camera_svc;
        camera_svc.type = SERVICE_TYPE_CAMERA;
        camera_svc.allocate_resource = camera_allocate_resource;
        camera_svc.free_resource = camera_free_resource;
        allocate_services(s->ctx, &camera_svc, 1);
    }

    set_fallback_callback(s->ctx, on_fallback, s);
    set_exit_fallback_callback(s->ctx, on_exit_fallback, s);

    if (s->primary)
        audio_set_ctx(s->ctx);   /* audio fd is now live; threads pick it up via get_audio_fd */

    s->need_reconnect = false;
    LOGI("connected");
    return 0;
}

static void on_fallback(void *userdata)
{
    struct consumer_state *s = userdata;
    LOGI("fallback triggered (surface %u)", s->surface_id);

    if (s->primary)
        audio_set_ctx(NULL);   /* the lib has closed the audio fd; stop touching it */

    // Disable clip listener on Java side before stopping event thread
    if (s->primary && g_jvm && g_activity_obj) {
        JNIEnv *env = NULL;
        bool attached = false;
        if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
            if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) == 0)
                attached = true;
        }
        if (env) {
            jclass cls = (*env)->GetObjectClass(env, g_activity_obj);
            jmethodID mid = (*env)->GetMethodID(env, cls, "nativeClipListening", "(Z)V");
            if (mid)
                (*env)->CallVoidMethod(env, g_activity_obj, mid, JNI_FALSE);
        }
        if (attached)
            (*g_jvm)->DetachCurrentThread(g_jvm);
    }

    stop_event_thread(s);

    /* PowOS: the link to the desktop is gone (KWin restarted with the session, or dropped us): connect afresh.
     * Nothing else did - the activity kept believing it was connected (MainActivity.nativeRunning) and the
     * render loop kept failing select_dmabuf, so the desktop stayed blank until the app was force-stopped.
     * do_connect() tears the old ctx down and retries every 0.5 s until the daemon answers. */
    s->need_reconnect = true;
}

static void on_exit_fallback(void *userdata)
{
    struct consumer_state *s = userdata;
    LOGI("exit fallback triggered (surface %u)", s->surface_id);

    send_refresh_rate(s);
    /* Clipboard, keyboard visibility and resource requests are the desktop's: no event thread for the others. */
    if (!s->primary)
        return;

    JNIEnv *env = NULL;
    if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) != 0) {
        LOGE("on_exit_fallback: AttachCurrentThread failed");
        return;
    }

    // Enable clip listener on Java side
    jclass cls = (*env)->GetObjectClass(env, g_activity_obj);
    jmethodID listenMid = (*env)->GetMethodID(env, cls, "nativeClipListening", "(Z)V");
    if (listenMid)
        (*env)->CallVoidMethod(env, g_activity_obj, listenMid, JNI_TRUE);

    start_event_thread(s);

    // Initial clipboard sync: read current system clipboard and send to producer
    jmethodID syncMethod = (*env)->GetMethodID(env, cls, "nativeClipboardSync", "()V");
    if (syncMethod)
        (*env)->CallVoidMethod(env, g_activity_obj, syncMethod);

    (*g_jvm)->DetachCurrentThread(g_jvm);
}

/* AOSP system/window.h NATIVE_WINDOW_SET_CROP; its rect is android_native_rect_t (left, top, right, bottom). */
#define ANW_SET_CROP 3

/* The buffer's part the surface shows, set on the window before a queue (Surface keeps it per queue). */
static void apply_crop(struct consumer_state *s)
{
    int w = s->crop_w, h = s->crop_h;
    if (w <= 0 || h <= 0)
        return;
    const int W = s->screen_w, H = s->screen_h;
    if (w > W)
        w = W;
    if (h > H)
        h = H;
    /* The crop is in buffer space, before the buffer transform: the logical top-left w x h where the pre-rotation
     * put it (kind 1: (x, y) -> (y, W - x); 2: (W - x, H - y); 3: (H - y, x)). */
    int32_t rect[4];
    switch (s->pretransform) {
    case 1:  rect[0] = 0;     rect[1] = W - w; rect[2] = h; rect[3] = W; break;
    case 2:  rect[0] = W - w; rect[1] = H - h; rect[2] = W; rect[3] = H; break;
    case 3:  rect[0] = H - h; rect[1] = 0;     rect[2] = H; rect[3] = w; break;
    default: rect[0] = 0;     rect[1] = 0;     rect[2] = w; rect[3] = h; break;
    }
    struct anw_window *aw = (struct anw_window *)s->window;
    aw->perform(aw, ANW_SET_CROP, rect);
}

static void *render_thread_func(void *arg)
{
    struct consumer_state *s = arg;
    LOGI("render thread started");

    while (s->running) {
        if (s->need_reconnect) {
            LOGI("reconnecting...");
            if (do_connect(s) < 0) {
                usleep(500000);
                continue;
            }
        }

        ANativeWindowBuffer *anb = NULL;
        int acqfence = -1;
        if (api.dequeueBuffer(s->window, &anb, &acqfence) != 0 || !anb) {
            usleep(16000);
            continue;
        }
        /* Emulate ANativeWindow_lock: CPU-wait the acquire fence so the buffer is
         * already safe to write (SurfaceFlinger done reading the previous frame)
         * before we hand it to the producer. A sync_file fd signals POLLIN. */
        if (acqfence >= 0) {
            struct pollfd fpfd = { .fd = acqfence, .events = POLLIN };
            poll(&fpfd, 1, 1000);
            close(acqfence);
        }

        int idx = -1;
        for (int i = 0; i < s->buf_count; i++) {
            if (s->buf_anb[i] == anb) {
                idx = i;
                break;
            }
        }

        if (idx < 0) {
            /* PowOS: not one of the buffers the producer has (the queue reallocated them): never drawn, so never
             * shown - it was queued as is, a black frame. A few in a row: collect them afresh. */
            api.cancelBuffer(s->window, anb, -1);
            note_undrawn(s, "not one of the collected buffers");
            if (++s->foreign_bufs >= 8) {
                LOGE("surface %u: the window's buffers were reallocated, collecting them again", s->surface_id);
                s->foreign_bufs = 0;
                s->recollect = true;
                s->need_reconnect = true;
            }
            usleep(16000);
            continue;
        }
        s->foreign_bufs = 0;

        if (select_dmabuf(s->ctx, idx) < 0) {
            api.cancelBuffer(s->window, anb, -1);
            note_undrawn(s, "select_dmabuf failed");
            /* PowOS: a link that fails every frame for ~2 s is dead even if no fallback was signalled. */
            if (++s->select_failures >= 120) {
                LOGE("select_dmabuf failing for ~2 s, reconnecting");
                s->select_failures = 0;
                s->need_reconnect = true;
            }
            usleep(16000);
            continue;
        }
        s->select_failures = 0;

        /* The producer renders into the buffer and hands back a render-done fence
         * over data_fd (reverse). Queue with it so SurfaceFlinger waits GPU-side
         * before scanout -- this lets the producer submit before its GPU render
         * completes (no glFinish stall). rfence == -1 falls back to "ready now". */
        int rfence = -1;
        uint8_t tag = 0;
        int done = refresh_done_tagged(s->ctx, &rfence, &tag);
        if (done != 1) {
            /* PowOS: no frame in it (0: no producer yet - fallback; -1: it timed out or went away). Queueing it showed
             * whatever the buffer last held, or a never-drawn one: the black flicker. Not shown: the surface keeps its
             * last frame. Only a failure is worth a log line; waiting for a producer is normal. */
            api.cancelBuffer(s->window, anb, -1);
            if (done < 0)
                note_undrawn(s, "the producer gave no frame");
            usleep(16000);
            continue;
        }

        /* PowOS: the rotation the producer drew with (protocol.h FRAME_TAG_PRETRANSFORM; 0 from an older KWin). */
        if ((tag & FRAME_TAG_PRETRANSFORM) && !g_producer_prerotates) {
            LOGI("surface %u: the producer pre-rotates", s->surface_id);
            g_producer_prerotates = true;
        }
        int drawn = (tag & FRAME_TAG_PRETRANSFORM) ? (tag & 3) : 0;
        if (drawn != s->pretransform) {
            /* Drawn for other buffers than these (an older KWin that can't rotate): never shown. Reconnect with
             * buffers that fit; three times in a row with a producer that says it can - give pre-rotation up. */
            api.cancelBuffer(s->window, anb, rfence);
            note_undrawn(s, "drawn with another rotation than the buffers'");
            if (!(tag & FRAME_TAG_PRETRANSFORM)) {
                if (g_producer_prerotates)
                    LOGI("surface %u: an older producer, no pre-rotation", s->surface_id);
                g_producer_prerotates = false;
            } else if (++s->mismatch_reconnects >= 3) {
                LOGE("surface %u: the producer keeps drawing rotation %d into buffers for %d, pre-rotation off",
                     s->surface_id, drawn, s->pretransform);
                g_producer_prerotates = false;
            }
            s->need_reconnect = true;
            continue;
        }
        s->mismatch_reconnects = 0;

        apply_crop(s);
        api.queueBuffer(s->window, anb, rfence);

        /* Follow the transform hint (rotation, fold to the other screen): buffers for the new one. A queue is when
         * the window learns a new hint, so look right after it. */
        int want = wanted_pretransform(s, s->buf_count);
        if (want != s->pretransform) {
            LOGI("surface %u: transform hint %d: pre-rotation %d -> %d, reconnecting", s->surface_id,
                 query_transform_hint(s), s->pretransform, want);
            s->need_reconnect = true;
        }
    }

    LOGI("render thread stopped");
    return NULL;
}

/* ---------- JNI ---------- */

static void copy_jstring(JNIEnv *env, jstring js, char *dst, size_t dstsz)
{
    if (!js) {
        dst[0] = '\0';
        return;
    }
    const char *s = (*env)->GetStringUTFChars(env, js, NULL);
    if (s) {
        strncpy(dst, s, dstsz - 1);
        dst[dstsz - 1] = '\0';
        (*env)->ReleaseStringUTFChars(env, js, s);
    } else {
        dst[0] = '\0';
    }
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeConfigure(
    JNIEnv *env, jclass clazz, jstring socketPath, jboolean useRoot,
    jstring helperPath, jstring bridgePath)
{
    pthread_mutex_lock(&cfg_lock);
    char tmp[sizeof(cfg_socket_path)];
    copy_jstring(env, socketPath, tmp, sizeof(tmp));
    if (tmp[0] != '\0')
        memcpy(cfg_socket_path, tmp, sizeof(cfg_socket_path));
    cfg_use_root = (useRoot == JNI_TRUE);
    copy_jstring(env, helperPath, cfg_helper_path, sizeof(cfg_helper_path));
    copy_jstring(env, bridgePath, cfg_bridge_path, sizeof(cfg_bridge_path));
    pthread_mutex_unlock(&cfg_lock);

    LOGI("configured: socket=%s root=%d helper=%s bridge=%s",
         cfg_socket_path, cfg_use_root, cfg_helper_path, cfg_bridge_path);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetCompatibleMode(
    JNIEnv *env, jclass clazz, jboolean enabled)
{
    (void)env;
    (void)clazz;

    pthread_mutex_lock(&cfg_lock);
    cfg_use_compatible_bridge = (enabled == JNI_TRUE);
    if (!cfg_use_compatible_bridge && cfg_compatible_fd >= 0) {
        close(cfg_compatible_fd);
        cfg_compatible_fd = -1;
    }
    pthread_mutex_unlock(&cfg_lock);

    LOGI("compatible bridge mode: %d", enabled == JNI_TRUE);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetCompatibleFd(
    JNIEnv *env, jclass clazz, jint fd)
{
    (void)env;
    (void)clazz;

    if (fd < 0)
        return;

    pthread_mutex_lock(&cfg_lock);
    if (cfg_compatible_fd >= 0)
        close(cfg_compatible_fd);
    cfg_compatible_fd = fd;
    pthread_mutex_unlock(&cfg_lock);

    LOGI("received compatible bridge socket fd=%d", fd);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetCustomResolution(
    JNIEnv* env, jclass clazz, jint width, jint height)
{
    pthread_mutex_lock(&cfg_lock);
    cfg_custom_width = width;
    cfg_custom_height = height;
    pthread_mutex_unlock(&cfg_lock);
    LOGI("custom resolution: %dx%d", width, height);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeStart(
    JNIEnv *env, jclass clazz, jobject surface, jobject callbackTarget)
{
    if (!api_loaded) {
        if (anw_api_load(&api) < 0) {
            LOGE("failed to load ANativeWindow hidden API");
            return;
        }
        api_loaded = true;
    }

    pthread_mutex_lock(&g_state.lock);

    if (g_state.running) {
        g_state.running = false;
        pthread_mutex_unlock(&g_state.lock);
        pthread_join(g_state.render_thread, NULL);
        pthread_mutex_lock(&g_state.lock);
    }

    if (g_state.ctx) {
        disconnect(g_state.ctx);
        g_state.ctx = NULL;
    }
    motion_has_last = false;
    motion_has_last = false;
    cleanup_dmabufs(&g_state);

    if (g_state.window) {
        ANativeWindow_release(g_state.window);
        g_state.window = NULL;
    }

    g_state.window = ANativeWindow_fromSurface(env, surface);
    if (!g_state.window) {
        LOGE("ANativeWindow_fromSurface failed");
        pthread_mutex_unlock(&g_state.lock);
        return;
    }

    /* Save JVM & clipboard callback target for event-thread JNI callbacks. */
    if (!g_jvm) {
        (*env)->GetJavaVM(env, &g_jvm);
    }
    if (g_activity_obj) {
        (*env)->DeleteGlobalRef(env, g_activity_obj);
    }
    /* Static natives have no `thiz`; Java passes the Clipboard instance whose
     * nativeSetClipboardText / nativeClipListening / nativeClipboardSync methods
     * are called by the event thread. */
    g_activity_obj = (*env)->NewGlobalRef(env, callbackTarget);

    g_state.running = true;
    g_state.need_reconnect = true;
    pthread_create(&g_state.render_thread, NULL, render_thread_func, &g_state);

    /* Audio streams live independently of the connection; the render thread attaches
     * the fd via audio_set_ctx() once connected. */
    audio_start();

    pthread_mutex_unlock(&g_state.lock);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeStop(
    JNIEnv *env, jclass clazz)
{
    pthread_mutex_lock(&g_state.lock);

    if (g_state.running) {
        g_state.running = false;
        pthread_mutex_unlock(&g_state.lock);
        pthread_join(g_state.render_thread, NULL);
        pthread_mutex_lock(&g_state.lock);
    }

    /* Stop audio before the ctx (and its fd) is torn down. */
    audio_set_ctx(NULL);
    audio_stop();

    if (g_state.ctx) {
        stop_event_thread(&g_state);
        join_event_thread(&g_state);
        disconnect(g_state.ctx);
        g_state.ctx = NULL;
    }

    // Disable clip listener on Java side
    if (g_jvm && g_activity_obj) {
        JNIEnv *env = NULL;
        bool attached = false;
        if ((*g_jvm)->GetEnv(g_jvm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
            if ((*g_jvm)->AttachCurrentThread(g_jvm, &env, NULL) == 0)
                attached = true;
        }
        if (env) {
            jclass cls = (*env)->GetObjectClass(env, g_activity_obj);
            jmethodID mid = (*env)->GetMethodID(env, cls, "nativeClipListening", "(Z)V");
            if (mid)
                (*env)->CallVoidMethod(env, g_activity_obj, mid, JNI_FALSE);
        }
        if (attached)
            (*g_jvm)->DetachCurrentThread(g_jvm);
    }

    cleanup_dmabufs(&g_state);

    pthread_mutex_lock(&cfg_lock);
    if (cfg_compatible_fd >= 0) {
        close(cfg_compatible_fd);
        cfg_compatible_fd = -1;
    }
    pthread_mutex_unlock(&cfg_lock);

    if (g_state.window) {
        ANativeWindow_release(g_state.window);
        g_state.window = NULL;
    }

    pthread_mutex_unlock(&g_state.lock);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetRefreshRate(
    JNIEnv *env, jclass clazz, jfloat hz)
{
    if (hz <= 0.0f)
        return;
    g_state.refresh_mhz = (uint32_t)(hz * 1000.0f + 0.5f);
    // Apply live if already connected; otherwise do_connect() seeds it.
    send_refresh_rate(&g_state);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendTouch(
    JNIEnv *env, jclass clazz, jint action, jfloat x, jfloat y, jint pointer_id)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_TOUCH,
        .touch = { .action = action, .x = x, .y = y, .pointer_id = pointer_id },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendTouchFrame(
    JNIEnv *env, jclass clazz)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_TOUCH_FRAME,
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendKey(
    JNIEnv *env, jclass clazz, jint action, jint keycode)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_KEY,
        .key = { .action = action, .keycode = keycode },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendMouseMotion(
    JNIEnv *env, jclass clazz, jfloat x, jfloat y, jfloat dx, jfloat dy)
{
    if (!g_state.ctx)
        return;

    if (dx == 0.0f && dy == 0.0f && motion_has_last) {
        dx = x - motion_last_x;
        dy = y - motion_last_y;
    }

    motion_last_x = x;
    motion_last_y = y;
    motion_has_last = true;

    struct InputEvent ev = {
        .type = INPUT_TYPE_POINTER_MOTION,
        .pointer_motion = { .x = x, .y = y, .dx = dx, .dy = dy },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendMouseButton(
    JNIEnv *env, jclass clazz, jint button, jboolean pressed)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_POINTER_BUTTON,
        .pointer_button = { .button = button, .pressed = pressed ? 1 : 0 },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendMouseScroll(
    JNIEnv *env, jclass clazz, jint axis, jfloat value)
{
    if (!g_state.ctx)
        return;
    struct InputEvent ev = {
        .type = INPUT_TYPE_POINTER_AXIS,
        .pointer_axis = { .axis = axis, .value = value, .discrete = 0 },
    };
    push_input_event(g_state.ctx, &ev);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendClipboard(
    JNIEnv *env, jclass clazz, jbyteArray data)
{
    if (!g_state.ctx)
        return;

    jsize len = (*env)->GetArrayLength(env, data);
    if (len <= 0)
        return;

    char *buf = malloc(len);
    if (!buf)
        return;
    (*env)->GetByteArrayRegion(env, data, 0, len, (jbyte *)buf);

    struct InputEvent ev = {
        .type = INPUT_TYPE_CLIPBOARD,
        .clipboard = { .size = (uint32_t)len },
    };
    push_input_event_with_length(g_state.ctx, &ev, buf, len);
    free(buf);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendTextInput(
    JNIEnv *env, jclass clazz, jbyteArray data)
{
    if (!g_state.ctx)
        return;

    jsize len = (*env)->GetArrayLength(env, data);
    if (len <= 0)
        return;

    char *buf = malloc(len);
    if (!buf)
        return;
    (*env)->GetByteArrayRegion(env, data, 0, len, (jbyte *)buf);

    struct InputEvent ev = {
        .type = INPUT_TYPE_TEXT_INPUT,
        .text_input = { .size = (uint32_t)len },
    };
    push_input_event_with_length(g_state.ctx, &ev, buf, len);
    free(buf);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetMicEnabled(
    JNIEnv *env, jclass clazz, jboolean enabled)
{
    audio_set_mic_enabled(enabled == JNI_TRUE);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetAudioLatency(
    JNIEnv *env, jclass clazz, jint speakerMs, jint micMs)
{
    audio_set_latency(speakerMs, micMs);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetAudioKeepalive(
    JNIEnv *env, jclass clazz, jboolean enabled)
{
    audio_set_keepalive(enabled == JNI_TRUE);
}

/* ---------- PowOS: more surfaces (a PowOS window as its own Android task) ---------- */

/* Starts a consumer for [surface] as the daemon's surface [surfaceId] (a PowOS window KWin exports to this task):
 * pixels and input only (no audio, camera, clipboard or keyboard - those stay with the desktop, g_state). Returns its
 * handle for the *Window* calls, 0 on failure. The connection retries on its own until KWin's producer answers. */
JNIEXPORT jlong JNICALL
Java_andro_marchy_Native_nativeStartWindow(
    JNIEnv *env, jclass clazz, jobject surface, jint surfaceId, jint buffersWidth, jint buffersHeight)
{
    if (!api_loaded) {
        if (anw_api_load(&api) < 0) {
            LOGE("failed to load ANativeWindow hidden API");
            return 0;
        }
        api_loaded = true;
    }
    struct consumer_state *s = calloc(1, sizeof(*s));
    if (!s)
        return 0;
    pthread_mutex_init(&s->lock, NULL);
    s->surface_id = (uint32_t)surfaceId;
    s->buffers_w = buffersWidth > 0 ? buffersWidth : 0;
    s->buffers_h = buffersHeight > 0 ? buffersHeight : 0;
    for (int i = 0; i < MAX_COLLECT_BUFS; i++)
        s->dmabuf_fds[i] = -1;
    s->window = ANativeWindow_fromSurface(env, surface);
    if (!s->window || surfaceId <= 0) {
        LOGE("window consumer: no surface or id");
        if (s->window)
            ANativeWindow_release(s->window);
        pthread_mutex_destroy(&s->lock);
        free(s);
        return 0;
    }
    if (!g_jvm)
        (*env)->GetJavaVM(env, &g_jvm);
    s->refresh_mhz = g_state.refresh_mhz;
    s->running = true;
    s->need_reconnect = true;
    if (pthread_create(&s->render_thread, NULL, render_thread_func, s) != 0) {
        ANativeWindow_release(s->window);
        pthread_mutex_destroy(&s->lock);
        free(s);
        return 0;
    }
    LOGI("window consumer started for surface %u", s->surface_id);
    return (jlong)(intptr_t)s;
}

/* Stops and frees a consumer from nativeStartWindow. The caller must not use [handle] afterwards. */
JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeStopWindow(
    JNIEnv *env, jclass clazz, jlong handle)
{
    struct consumer_state *s = (struct consumer_state *)(intptr_t)handle;
    if (!s)
        return;
    s->running = false;
    pthread_join(s->render_thread, NULL);
    if (s->ctx) {
        stop_event_thread(s);
        join_event_thread(s);
        disconnect(s->ctx);
        s->ctx = NULL;
    }
    cleanup_dmabufs(s);
    if (s->window)
        ANativeWindow_release(s->window);
    LOGI("window consumer stopped for surface %u", s->surface_id);
    pthread_mutex_destroy(&s->lock);
    free(s);
}

static void push_to(jlong handle, struct InputEvent *ev)
{
    struct consumer_state *s = (struct consumer_state *)(intptr_t)handle;
    if (s && s->ctx)
        push_input_event(s->ctx, ev);
}

/* The part of the buffers window consumer [handle]'s surface shows: its size now (a floating window resized). */
JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetWindowCrop(
    JNIEnv *env, jclass clazz, jlong handle, jint width, jint height)
{
    struct consumer_state *s = (struct consumer_state *)(intptr_t)handle;
    if (!s)
        return;
    s->crop_w = width;
    s->crop_h = height;
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSetWindowRefreshRate(
    JNIEnv *env, jclass clazz, jlong handle, jfloat hz)
{
    struct consumer_state *s = (struct consumer_state *)(intptr_t)handle;
    if (!s || hz <= 0.0f)
        return;
    s->refresh_mhz = (uint32_t)(hz * 1000.0f + 0.5f);
    send_refresh_rate(s);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendWindowTouch(
    JNIEnv *env, jclass clazz, jlong handle, jint action, jfloat x, jfloat y, jint pointer_id)
{
    struct InputEvent ev = {
        .type = INPUT_TYPE_TOUCH,
        .touch = { .action = action, .x = x, .y = y, .pointer_id = pointer_id },
    };
    push_to(handle, &ev);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendWindowTouchFrame(
    JNIEnv *env, jclass clazz, jlong handle)
{
    struct InputEvent ev = { .type = INPUT_TYPE_TOUCH_FRAME };
    push_to(handle, &ev);
}

JNIEXPORT void JNICALL
Java_andro_marchy_Native_nativeSendWindowKey(
    JNIEnv *env, jclass clazz, jlong handle, jint action, jint keycode)
{
    struct InputEvent ev = {
        .type = INPUT_TYPE_KEY,
        .key = { .action = action, .keycode = keycode },
    };
    push_to(handle, &ev);
}
