package dev.omalauncher.system

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The recents key toggles what the user sees (OnePlus folded 11-11): the page's reported layer decides, never a host
 * flag gone stale, in either direction.
 */
class SwitcherToggleTest {
    @Test
    fun hostUpPageClosedShows() {
        // Before: the stale host flag sent "switcher.toggle" to a closed layer with zero cards - the key did nothing.
        assertFalse(Switcher.pageToggles(pageLayer = false, hostOpen = true, homeVisible = true, gesture = false))
    }

    @Test
    fun pageUpHostClosedToggles() {
        // Before: the host thought it closed and showed it again - the press never closed what was on screen.
        assertTrue(Switcher.pageToggles(pageLayer = true, hostOpen = false, homeVisible = true, gesture = false))
    }

    @Test
    fun agreeingStatesUnchanged() {
        assertTrue(Switcher.pageToggles(pageLayer = true, hostOpen = true, homeVisible = true, gesture = false))
        assertFalse(Switcher.pageToggles(pageLayer = false, hostOpen = false, homeVisible = true, gesture = false))
    }

    @Test
    fun pageThatNeverReportedFallsBackToHostFlag() {
        assertTrue(Switcher.pageToggles(pageLayer = null, hostOpen = true, homeVisible = true, gesture = false))
        assertFalse(Switcher.pageToggles(pageLayer = null, hostOpen = false, homeVisible = true, gesture = false))
    }

    @Test
    fun swipeOrHiddenHomeAlwaysShows() {
        assertFalse(Switcher.pageToggles(pageLayer = true, hostOpen = true, homeVisible = true, gesture = true))
        assertFalse(Switcher.pageToggles(pageLayer = true, hostOpen = true, homeVisible = false, gesture = false))
    }
}
