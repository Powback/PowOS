package dev.omalauncher.ui

import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.input.pointer.PointerType
import androidx.compose.ui.input.pointer.isPrimaryPressed
import androidx.compose.ui.input.pointer.isSecondaryPressed
import androidx.compose.ui.input.pointer.isTertiaryPressed
import androidx.compose.ui.input.pointer.pointerInput
import dev.omalauncher.wayland.AXIS_SOURCE_FINGER
import dev.omalauncher.wayland.AXIS_SOURCE_WHEEL
import dev.omalauncher.wayland.BTN_LEFT
import dev.omalauncher.wayland.BTN_MIDDLE
import dev.omalauncher.wayland.BTN_RIGHT
import dev.omalauncher.wayland.SurfaceHit
import dev.omalauncher.wayland.XdgToplevel
import kotlin.math.roundToInt

private const val WHEEL_STEP = 15f

/**
 * Routes pointer input over a Linux window's view to its surfaces. Mouse input
 * is forwarded as-is. Touch is mapped for a phone: tap = left click, long
 * press = right click, drag = scroll; clients with wl_touch get real touch.
 */
fun Modifier.linuxWindowInput(
    wm: WindowManager,
    window: XdgToplevel,
) = pointerInput(wm, window) {
    handlePointer(wm, window, viewConfiguration.touchSlop, viewConfiguration.longPressTimeoutMillis)
}

private fun XdgToplevel.hitTest(
    x: Float,
    y: Float,
) = renderer?.hitTest(x, y)

private suspend fun PointerInputScope.handlePointer(
    wm: WindowManager,
    window: XdgToplevel,
    touchSlop: Float,
    longPressMs: Long,
) = awaitPointerEventScope {
    val target = TouchTarget(wm, window, touchSlop, longPressMs)
    var mouseButtons = 0
    while (true) {
        val event = awaitPointerEvent()
        val change = event.changes.firstOrNull() ?: continue
        if (change.type == PointerType.Mouse) {
            mouseButtons = handleMouse(wm, window, event, mouseButtons)
            change.consume()
        } else if (event.type == PointerEventType.Press && !change.isConsumed) {
            touchPress(target, change)
        }
    }
}

/** What a touch on a window needs: where it goes, and the platform's slop and long-press time. */
private class TouchTarget(
    val wm: WindowManager,
    val window: XdgToplevel,
    val touchSlop: Float,
    val longPressMs: Long,
)

/** A finger down on the window: real touch for clients that take it, else the phone's mapping (tap, hold, drag). */
private suspend fun AwaitPointerEventScope.touchPress(
    t: TouchTarget,
    change: PointerInputChange,
) {
    val hit = t.window.hitTest(change.position.x, change.position.y)
    change.consume()
    if (!t.wm.onPress(t.window, hit) || hit == null) return
    // Clients with wl_touch (foot, GTK) get real touch: foot turns hold-and-drag into selection.
    if (t.wm.wantsTouch(hit.surface)) realTouch(t.wm, hit, change) else phoneGesture(t, hit, change)
}

private suspend fun AwaitPointerEventScope.realTouch(
    wm: WindowManager,
    hit: SurfaceHit,
    change: PointerInputChange,
) {
    val id = change.id.value.toInt()
    val start = change.position
    wm.touchDown(hit, id)
    while (true) {
        val c = awaitPointerEvent().changes.firstOrNull { it.id == change.id }
        // Taken by the home screen (a long press lifts a tile): the touch ends here.
        if (c == null || c.isConsumed || !c.pressed) break
        c.consume()
        val d = (c.position - start) / wm.scale.toFloat()
        wm.touchMotion(id, hit.x + d.x, hit.y + d.y)
    }
    wm.touchUp(id)
}

/** A phone gesture in progress: where it began, whether it became a scroll or a long press. */
private class Gesture(
    val start: Offset,
) {
    var scrolling = false
    var longPressed = false
    var last = start
    val undecided get() = !scrolling && !longPressed
}

/** Tap = left click, long press = right click, drag = scroll. */
private suspend fun AwaitPointerEventScope.phoneGesture(
    t: TouchTarget,
    hit: SurfaceHit,
    change: PointerInputChange,
) {
    val g = Gesture(change.position)
    while (true) {
        val next = if (g.undecided) withTimeoutOrNull(t.longPressMs) { awaitPointerEvent() } else awaitPointerEvent()
        if (next == null) {
            g.longPressed = true
            t.wm.click(hit, BTN_RIGHT)
            continue
        }
        val c = next.changes.firstOrNull { it.id == change.id } ?: break
        if (!gestureStep(t, hit, g, c)) break
    }
}

/** One move of the finger; false once the gesture is over (lifted, or taken by home). */
private fun gestureStep(
    t: TouchTarget,
    hit: SurfaceHit,
    g: Gesture,
    c: PointerInputChange,
): Boolean {
    val wm = t.wm
    if (c.isConsumed) {
        if (g.scrolling) wm.scrollStop()
        return false
    }
    c.consume()
    if (!c.pressed) {
        if (g.scrolling) wm.scrollStop() else if (!g.longPressed) wm.click(hit, BTN_LEFT)
        return false
    }
    if (g.undecided && (c.position - g.start).getDistance() > t.touchSlop) {
        g.scrolling = true
        wm.pointerMove(hit)
    }
    if (g.scrolling) {
        val d = c.position - g.last
        wm.scroll(-d.x / wm.scale, -d.y / wm.scale, AXIS_SOURCE_FINGER)
    }
    g.last = c.position
    return true
}

private fun handleMouse(
    wm: WindowManager,
    window: XdgToplevel,
    event: PointerEvent,
    previousButtons: Int,
): Int {
    val change = event.changes.first()
    when (event.type) {
        PointerEventType.Exit -> {
            wm.pointerMove(null)
            return previousButtons
        }
        PointerEventType.Scroll -> {
            val d = change.scrollDelta
            wm.scroll(d.x * WHEEL_STEP, d.y * WHEEL_STEP, AXIS_SOURCE_WHEEL, d.y.roundToInt())
            return previousButtons
        }
        else -> Unit
    }
    val hit: SurfaceHit? = window.hitTest(change.position.x, change.position.y)
    val buttons =
        (if (event.buttons.isPrimaryPressed) 1 else 0) or
            (if (event.buttons.isSecondaryPressed) 2 else 0) or
            (if (event.buttons.isTertiaryPressed) 4 else 0)
    val pressed = buttons and previousButtons.inv()
    if (pressed != 0 && !wm.onPress(window, hit)) return buttons
    // Keep the grab on the pressed surface while dragging.
    if (previousButtons == 0 || wm.server.input.pointerFocus == hit?.surface) wm.pointerMove(hit)
    for ((bit, code) in BUTTONS) {
        if (pressed and bit != 0) wm.pointerButton(code, true)
        if (previousButtons and bit != 0 && buttons and bit == 0) wm.pointerButton(code, false)
    }
    return buttons
}

private val BUTTONS = listOf(1 to BTN_LEFT, 2 to BTN_RIGHT, 4 to BTN_MIDDLE)
