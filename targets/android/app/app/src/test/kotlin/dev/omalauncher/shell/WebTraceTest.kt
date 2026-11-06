package dev.omalauncher.shell

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The fps meter's traces: pages may profile their JS (Document-Policy), the Chrome trace carries JS stacks + timeline. */
class WebTraceTest {
    @Test
    fun pagesMayProfileTheirJs() {
        val page = WebTrace.shellHeaders("index.html", "https://shell.powos")
        assertEquals("js-profiling", page["Document-Policy"])
        assertEquals("no-store", page["Cache-Control"])
        assertEquals("https://shell.powos", page["Access-Control-Allow-Origin"])
        assertNull(WebTrace.shellHeaders("ui/perfrec.ts", "https://shell.powos")["Document-Policy"])
    }

    @Test
    fun traceCarriesStacksAndTimeline() {
        for (c in listOf("devtools.timeline", "disabled-by-default-v8.cpu_profiler", "blink.user_timing", "disabled-by-default-devtools.timeline.frame")) {
            assertTrue(c, c in WebTrace.CATEGORIES)
        }
    }
}
