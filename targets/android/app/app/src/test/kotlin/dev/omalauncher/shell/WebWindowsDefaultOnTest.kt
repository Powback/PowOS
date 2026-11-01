package dev.omalauncher.shell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Board linux-windows-as-first-class-powos-windows-own-s, step "device check, then switch on": web windows are on by
 * default (e2e-desktop round 205, 11-01 19:34: Chrome, Kate, Calculator, Dolphin and Gwenview as web windows, all PASS).
 * `settings put global powos_web_windows 0` still turns them off; a phone that never set it gets them.
 */
class WebWindowsDefaultOnTest {
    @Test
    fun unsetIsOn() = assertTrue(WebWindows.isOn(null))

    @Test
    fun oneIsOn() = assertTrue(WebWindows.isOn(1))

    @Test
    fun zeroIsOff() = assertFalse(WebWindows.isOn(0))
}
