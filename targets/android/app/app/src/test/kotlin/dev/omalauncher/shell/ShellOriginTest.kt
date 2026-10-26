package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ShellOriginTest {
    private val rules = ShellOrigin.rules(null)

    @Test
    fun theShellsTopFrameIsAllowed() {
        assertTrue(ShellOrigin.allowed("https://shell.powos", true, rules))
        assertTrue(ShellOrigin.allowed("https://shell.powos/", true, rules))
    }

    @Test
    fun anIframeIsRefusedEvenAtTheShellsOrigin() {
        // A srcdoc / about:blank iframe without a sandbox inherits the page's origin.
        assertFalse(ShellOrigin.allowed("https://shell.powos", false, rules))
    }

    @Test
    fun opaqueAndOtherOriginsAreRefused() {
        for (o in listOf("null", "", " ", "https://evil.example", "http://shell.powos", "https://shell.powos:444", "https://shell.powos.evil.example", "https://sub.shell.powos", "data:", "file://", "about:blank")) {
            assertFalse(o, ShellOrigin.allowed(o, true, rules))
            assertFalse(o, ShellOrigin.allowed(o, false, rules))
        }
        assertFalse(ShellOrigin.allowed(null, true, rules))
    }

    @Test
    fun aDevServerIsAddedOnlyWhenSet() {
        assertEquals(setOf("https://shell.powos"), rules)
        val dev = ShellOrigin.rules("http://192.168.50.99:4321/index.html?x=1")
        assertEquals(setOf("https://shell.powos", "http://192.168.50.99:4321"), dev)
        assertTrue(ShellOrigin.allowed("http://192.168.50.99:4321", true, dev))
        assertFalse(ShellOrigin.allowed("http://192.168.50.99:4321", false, dev))
        assertFalse(ShellOrigin.allowed("http://192.168.50.99:4321", true, rules))
    }

    @Test
    fun originOfNormalisesAndRejects() {
        assertEquals("https://shell.powos", ShellOrigin.of("https://SHELL.powos:443/a"))
        assertEquals("http://h:8080", ShellOrigin.of("http://h:8080/"))
        assertNull(ShellOrigin.of("file:///sdcard/x.html"))
        assertNull(ShellOrigin.of("javascript:alert(1)"))
        assertNull(ShellOrigin.of("not a url"))
        assertEquals(setOf("https://shell.powos"), ShellOrigin.rules("file:///x"))
    }
}
