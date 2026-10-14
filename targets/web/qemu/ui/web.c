/*
 * PowOS web: "-display web" - QEMU's graphical console in the browser page.
 *
 * Frames: the console's surface lives in the Wasm heap, which is shared memory (pthreads), so the page reads the
 * pixels in place - no copy. QEMU accumulates the dirty rectangle and, on each display refresh (30 ms), tells the
 * page where the surface is and which rectangle changed (Module.powosFrame on the main thread); the page uploads
 * that rectangle (WebGPU texture, 2D canvas fallback) once per animation frame.
 *
 * Input: the page writes events into a ring in the Wasm heap (Module.powosInputRing gives its address); each refresh
 * drains it into QEMU's input layer: keys as Linux evdev codes (qemu_input_map_linux_to_qcode), the pointer as an
 * absolute position (virtio-tablet / usb-tablet), buttons and wheel.
 *
 * Native builds (the snapshot machine) accept -display web and do nothing: a display is not machine state.
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 */

#include "qemu/osdep.h"
#include "qemu/atomic.h"
#include "qemu/module.h"
#include "ui/console.h"
#include "ui/input.h"

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <emscripten/threading.h>
#endif

/* Ring of input events written by the page: [head, tail, then RING_SLOTS events of 4 int32 each]. */
#define RING_SLOTS 1024
enum { EV_KEY = 1, EV_ABS = 2, EV_BTN = 3 };
/* EV_KEY: a = Linux evdev code, b = down.  EV_ABS: a = x, b = y (0..32767).  EV_BTN: a = InputButton, b = down. */

typedef struct WebDisplay {
    DisplayChangeListener dcl;
    DisplaySurface *surface;
    int dirty_x0, dirty_y0, dirty_x1, dirty_y1; /* x1/y1 exclusive; x1 == 0: nothing dirty */
    int32_t ring[2 + RING_SLOTS * 4];
} WebDisplay;

static WebDisplay *web;

#ifdef __EMSCRIPTEN__
static void web_notify_frame(void *data, int w, int h, int stride, int x, int y, int rw, int rh)
{
    /* HEAPU8 is a view on the shared Wasm memory: the page reads the surface in place. */
    MAIN_THREAD_ASYNC_EM_ASM({
        if (Module.powosFrame) Module.powosFrame(HEAPU8, $0, $1, $2, $3, $4, $5, $6, $7);
    }, data, w, h, stride, x, y, rw, rh);
}

static void web_announce_ring(int32_t *ring)
{
    MAIN_THREAD_ASYNC_EM_ASM({
        if (Module.powosInputRing) Module.powosInputRing(HEAP32, $0 >> 2, $1);
    }, ring, RING_SLOTS);
}
#else
static void web_notify_frame(void *data, int w, int h, int stride, int x, int y, int rw, int rh)
{
}

static void web_announce_ring(int32_t *ring)
{
}
#endif

static void web_drain_input(WebDisplay *wd)
{
    int32_t *ring = wd->ring;
    int32_t head = qatomic_load_acquire(&ring[0]);
    int32_t tail = ring[1];
    bool any = false;

    while (tail != head) {
        int32_t *ev = &ring[2 + (tail % RING_SLOTS) * 4];
        switch (ev[0]) {
        case EV_KEY:
            if (ev[1] > 0 && ev[1] < qemu_input_map_linux_to_qcode_len) {
                qemu_input_event_send_key_qcode(wd->dcl.con, qemu_input_map_linux_to_qcode[ev[1]], ev[2]);
            }
            break;
        case EV_ABS:
            qemu_input_queue_abs(wd->dcl.con, INPUT_AXIS_X, ev[1], 0, 32767);
            qemu_input_queue_abs(wd->dcl.con, INPUT_AXIS_Y, ev[2], 0, 32767);
            any = true;
            break;
        case EV_BTN:
            if (ev[1] >= 0 && ev[1] < INPUT_BUTTON__MAX) {
                qemu_input_queue_btn(wd->dcl.con, ev[1], ev[2]);
                any = true;
            }
            break;
        }
        tail = (tail + 1) % (RING_SLOTS * 1024);
    }
    qatomic_store_release(&ring[1], tail);
    if (any) {
        qemu_input_event_sync();
    }
}

static void web_refresh(DisplayChangeListener *dcl)
{
    WebDisplay *wd = container_of(dcl, WebDisplay, dcl);

    web_drain_input(wd);
    graphic_hw_update(dcl->con);
    if (wd->surface && wd->dirty_x1 > 0) {
        web_notify_frame(surface_data(wd->surface), surface_width(wd->surface), surface_height(wd->surface),
                         surface_stride(wd->surface), wd->dirty_x0, wd->dirty_y0,
                         wd->dirty_x1 - wd->dirty_x0, wd->dirty_y1 - wd->dirty_y0);
        wd->dirty_x1 = 0;
    }
}

static void web_gfx_update(DisplayChangeListener *dcl, int x, int y, int w, int h)
{
    WebDisplay *wd = container_of(dcl, WebDisplay, dcl);

    if (wd->dirty_x1 == 0) {
        wd->dirty_x0 = x;
        wd->dirty_y0 = y;
        wd->dirty_x1 = x + w;
        wd->dirty_y1 = y + h;
    } else {
        wd->dirty_x0 = MIN(wd->dirty_x0, x);
        wd->dirty_y0 = MIN(wd->dirty_y0, y);
        wd->dirty_x1 = MAX(wd->dirty_x1, x + w);
        wd->dirty_y1 = MAX(wd->dirty_y1, y + h);
    }
}

static void web_gfx_switch(DisplayChangeListener *dcl, DisplaySurface *new_surface)
{
    WebDisplay *wd = container_of(dcl, WebDisplay, dcl);

    wd->surface = new_surface;
    if (new_surface) {
        web_gfx_update(dcl, 0, 0, surface_width(new_surface), surface_height(new_surface));
    }
}

static bool web_check_format(DisplayChangeListener *dcl, pixman_format_code_t format)
{
    /* The page uploads BGRX/BGRA 32-bit pixels as-is (WebGPU bgra8unorm). */
    return format == PIXMAN_x8r8g8b8 || format == PIXMAN_a8r8g8b8;
}

static const DisplayChangeListenerOps web_ops = {
    .dpy_name             = "web",
    .dpy_refresh          = web_refresh,
    .dpy_gfx_update       = web_gfx_update,
    .dpy_gfx_switch       = web_gfx_switch,
    .dpy_gfx_check_format = web_check_format,
};

static void web_display_init(DisplayState *ds, DisplayOptions *opts)
{
    QemuConsole *con = NULL;

    for (int i = 0;; i++) {
        QemuConsole *c = qemu_console_lookup_by_index(i);
        if (!c) {
            break;
        }
        if (qemu_console_is_graphic(c)) {
            con = c;
            break;
        }
    }
    if (!con) {
        fprintf(stderr, "web display: no graphical console (add a display device, e.g. virtio-gpu-pci)\n");
        return;
    }
    web = g_new0(WebDisplay, 1);
    web->dcl.ops = &web_ops;
    web->dcl.con = con;
    register_displaychangelistener(&web->dcl);
    web_announce_ring(web->ring);
}

static QemuDisplay qemu_display_web = {
    .type = DISPLAY_TYPE_WEB,
    .init = web_display_init,
};

static void register_web(void)
{
    qemu_display_register(&qemu_display_web);
}

type_init(register_web);
