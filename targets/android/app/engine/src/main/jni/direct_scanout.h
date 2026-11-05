#ifndef DIRECT_SCANOUT_H
#define DIRECT_SCANOUT_H
/* PowOS: direct scanout of a window task's client buffer (docs/research/window-task-direct-scanout.md, protocol.h
 * FRAME_TAG_DIRECT). The producer's dma-buf becomes an AHardwareBuffer by cloning a template's gralloc handle with the
 * fd swapped (proven on the phone by tools/phone/verify/direct-scanout.sh), shown on a child ASurfaceControl of the
 * window above its BufferQueue content. Off unless the system property debug.powos.direct_scanout is 1. */
#include <android/native_window.h>
#include <stdbool.h>
#include <stdint.h>
#include "protocol.h"

struct direct_state;

/* debug.powos.direct_scanout == "1" (read each time: setprop takes effect on the next connect). */
bool direct_flag(void);
struct direct_state *direct_new(void);
/* Show frame f (fence: acquire fence or -1, dmabuf: its fd when DIRECT_FLAG_NEW_FD, else -1; both consumed).
 * 0 shown; -1 not shown (this frame); -2 refused for good (self-test / mapper / layout) - offer no more direct frames. */
int direct_present(struct direct_state *d, ANativeWindow *win, const struct direct_frame *f, int fence, int dmabuf);
/* A composited frame was queued: hide the child so the window's own buffer shows. */
void direct_hide(struct direct_state *d);
/* The next client buffer SurfaceFlinger let go of (send INPUT_TYPE_DIRECT_RELEASE): 1 + *id, 0 none. */
int direct_take_release(struct direct_state *d, uint32_t *id);
/* A new connection: every id is forgotten (the producer sends the fds again), the child hidden. */
void direct_reset(struct direct_state *d);
void direct_free(struct direct_state *d);
#endif
