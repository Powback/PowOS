package dev.omalauncher.shell

import dev.omalauncher.shell.AppShortcuts.Entry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppShortcutsTest {
    private fun e(
        id: String,
        rank: Int,
        manifest: Boolean = false,
        dynamic: Boolean = true,
        enabled: Boolean = true,
        label: String = id,
    ) = Entry(id, label, enabled, rank, manifest, dynamic)

    @Test
    fun stockOrderManifestThenDynamicThenPinnedByRank() {
        val got = AppShortcuts.pick(listOf(e("pin", 0, dynamic = false), e("dyn1", 1), e("man1", 1, manifest = true, dynamic = false), e("dyn0", 0), e("man0", 0, manifest = true, dynamic = false)))
        assertEquals(listOf("man0", "man1", "dyn0", "dyn1"), got.map { it.id })
    }

    @Test
    fun capsAtStockCountAndDropsUnlabelledAndDuplicates() {
        val many = (0 until 8).map { e("s$it", it) } + e("blank", -1, label = " ") + e("s0", 99)
        val got = AppShortcuts.pick(many)
        assertEquals(AppShortcuts.MAX, got.size)
        assertEquals(listOf("s0", "s1", "s2", "s3"), got.map { it.id })
    }

    @Test
    fun disabledGoLast() {
        val got = AppShortcuts.pick(listOf(e("off", 0, manifest = true, enabled = false), e("on", 5)))
        assertEquals(listOf("on", "off"), got.map { it.id })
    }

    @Test
    fun jsonCarriesIdLabelIconAndEnabled() {
        val json = AppShortcuts.toJson(listOf(e("new_tab", 0, label = "New tab").copy(icon = "data:image/png;base64,AA"), e("incognito", 1, enabled = false, label = "New Incognito tab")))
        assertEquals(2, json.length())
        val a = json.getJSONObject(0)
        assertEquals("new_tab", a.getString("id"))
        assertEquals("New tab", a.getString("label"))
        assertEquals("data:image/png;base64,AA", a.getString("icon"))
        assertTrue(a.getBoolean("enabled"))
        val b = json.getJSONObject(1)
        assertTrue(b.isNull("icon"))
        assertFalse(b.getBoolean("enabled"))
    }
}
