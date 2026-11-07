/* PowOS 0017: what a touch event that finds no selecting client on its listener's window means (Xi/exevents.c).
 *
 * A regular touch listener (an XI2/XI event selection) is recorded at TouchBegin with the InputClients resource of
 * the client that selected the begin type on the window. XISetEventMask() with an empty or touch-less mask keeps
 * that InputClients entry (and its resource) and only zeroes its bits, so the next event of the sequence still finds
 * the window but no client that selects it: upstream 24.1.13 hits BUG at exevents.c:1396 (backtrace on every event)
 * and keeps the listener - an owner that never takes the rest of the sequence and never gives ownership to the
 * listeners behind it. Wine deselects on focus/clip changes, so on the phone it fired at Broforce's focus flips
 * (minimize/restore) right before its input stopped.
 *
 * Two different misses:
 *   NOT_SELECTED  the listener's own client still selects the begin type, it just never selected this event type
 *                 (a pointer-emulating listener that took ButtonPress but not Motion): skip it quietly, no BUG.
 *   DESELECTED    the listener's own client no longer selects the begin type (or its entry is gone): the listener
 *                 is gone; it is rejected like a disconnected client's (TouchListenerGone) so ownership moves on or
 *                 the sequence ends.
 * A TouchEnd (including the TouchEnd a reject itself emits) is never answered with a reject: the record ends anyway.
 *
 * Pure logic, no X server headers: unit test test/touch-listener-test.c. */
#ifndef XWAYLAND_KGSL_TOUCH_LISTENER_H
#define XWAYLAND_KGSL_TOUCH_LISTENER_H

enum xwl_touch_miss {
    XWL_TOUCH_MISS_NOT_SELECTED,
    XWL_TOUCH_MISS_DESELECTED,
};

/* own_entry_found: the listener's InputClients entry (resource == listener id) is on the window.
 * own_selects_begin: that entry still selects the type the listener was added for (XI_TouchBegin for a touch
 * listener, ButtonPress for a pointer-emulating one). */
static inline enum xwl_touch_miss
xwl_touch_classify_miss(int own_entry_found, int own_selects_begin)
{
    return own_entry_found && own_selects_begin ? XWL_TOUCH_MISS_NOT_SELECTED : XWL_TOUCH_MISS_DESELECTED;
}

/* Reject the listener (drop it from the sequence)? Only a deselected one, never on a TouchEnd, never one that has
 * its end already. */
static inline int
xwl_touch_should_reject(enum xwl_touch_miss miss, int event_is_end, int listener_has_end)
{
    return miss == XWL_TOUCH_MISS_DESELECTED && !event_is_end && !listener_has_end;
}

/* Counts for the log: the first miss of each kind is logged, then one in every 256. */
struct xwl_touch_miss_stats {
    unsigned long not_selected;
    unsigned long deselected;
};

static inline int
xwl_touch_miss_count(struct xwl_touch_miss_stats *s, enum xwl_touch_miss miss)
{
    unsigned long n = miss == XWL_TOUCH_MISS_DESELECTED ? ++s->deselected : ++s->not_selected;

    return n == 1 || (n & 255) == 0;
}

#endif /* XWAYLAND_KGSL_TOUCH_LISTENER_H */
