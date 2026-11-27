package dev.omalauncher.devices

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

class DropsTest {
    private val key = ByteArray(32) { it.toByte() }

    @Test
    fun sealedRoundTripsAndNeverOpensElsewhere() {
        val item = Drops.Item("image", ByteArray(5000) { (it * 7).toByte() }, "cat.png", "image/png")
        val ct = Drops.seal(key, "send", item)
        // nothing of it in the clear: not the name, not the type
        assertTrue(!String(ct, Charsets.ISO_8859_1).contains("cat.png"))
        val back = Drops.open(key, "send", ct)!!
        assertArrayEquals(item.body, back.body)
        assertEquals("cat.png", back.name)
        assertEquals("image/png", back.mime)
        assertEquals("image", back.type)
        assertNull(Drops.open(ByteArray(32), "send", ct)) // another account's key
        assertNull(Drops.open(key, "clip", ct)) // a send can't be replayed as a clip
        val bent = ct.copyOf().also { it[40] = (it[40] + 1).toByte() }
        assertNull(Drops.open(key, "send", bent))
        assertNull(Drops.open(key, "send", ByteArray(10)))
    }

    @Test
    fun opensWhatLinuxSealed() {
        // lib/apps/powos-drop seal(bytes(range(32)), "send", "file", b"hello from linux", name="note.txt", ...)
        val ct =
            Base64.getDecoder().decode(
                "av1OLWg8eZq/l+1GcHXnsCIABF2UyXRrMB9Xv7QlFlGZUGVDoUi2ZvodEJcVVhIWqexrqEp2B78uIDJH/x3WF4al5YOYjq6ZC3Qw4ef6veIc9M9D0VwAI97IdRSl2575dXQ+G86lL4jPC0uhnDcmfh3TFwLwrWBQYbwAS3OjiteDJH0e7eGPVUEDXmNZCozJY3eL",
            )
        val item = Drops.open(key, "send", ct)
        assertNotNull(item)
        assertEquals("hello from linux", item!!.text)
        assertEquals("note.txt", item.name)
        assertEquals("file", item.type)
    }

    @Test
    fun textOrLink() {
        assertEquals("link", Drops.Item.ofText(" https://example.com/a?b=1 ").type)
        assertEquals("text", Drops.Item.ofText("see https://example.com").type)
    }

    @Test
    fun sizeCaps() {
        assertNull(Drops.tooBig("clip", 1024L * 1024))
        assertTrue(Drops.tooBig("clip", 1024L * 1024 + 1)!!.contains("1 MB max"))
        assertNull(Drops.tooBig("send", Drops.SEND_MAX.toLong()))
        assertTrue(Drops.tooBig("send", 40L * 1024 * 1024)!!.contains("NAS"))
    }

    @Test
    fun targetsAreTheOtherLiveDevices() {
        val r =
            JSONObject().put(
                "devices",
                JSONArray()
                    .put(JSONObject().put("id", "s25").put("name", "S25").put("self", true))
                    .put(JSONObject().put("id", "desk").put("name", "Desk"))
                    .put(JSONObject().put("id", "tv").put("name", "TV").put("revoked", true))
                    .put(JSONObject().put("id", "verify-drops-peer").put("name", "PowOS verify").put("kind", "test"))
                    .put(JSONObject().put("id", "fold")),
            )
        assertEquals(listOf("desk" to "Desk", "fold" to "fold"), Drops.targets(r))
    }

    @Test
    fun waitingAndOffered() {
        val r = JSONObject().put("drops", JSONArray().put(JSONObject().put("id", "a").put("kind", "clip").put("from", "desk").put("from_name", "Desk").put("at", 5)))
        val w = Drops.parseWaiting(r)
        assertEquals("Desk", w[0].fromName)
        val older = Drops.Waiting("b", "clip", "fold", "", 3, 2, 9)
        val list = ClipShare.offeredJson(listOf(older to Drops.Item("image", ByteArray(3), mime = "image/png"), w[0] to Drops.Item.ofText("hi")))
        assertEquals("a", list.getJSONObject(0).getString("id")) // newest first
        assertEquals("hi", list.getJSONObject(0).getString("text"))
        assertEquals("fold", list.getJSONObject(1).getString("from")) // no name: the id
        assertTrue(!list.getJSONObject(1).has("text"))
    }

    @Test
    fun receivedFileNames() {
        assertEquals("passwd", DropInbox.safeName(Drops.Item("file", ByteArray(1), "../../etc/passwd")))
        assertEquals("a_b.txt", DropInbox.safeName(Drops.Item("file", ByteArray(1), "a:b.txt")))
        assertEquals("image.jpeg", DropInbox.safeName(Drops.Item("image", ByteArray(1), "", "image/jpeg")))
        assertEquals("text.txt", DropInbox.safeName(Drops.Item.ofText("x")))
        assertEquals("file", DropInbox.safeName(Drops.Item("file", ByteArray(1), ".hidden/..")))
    }
}
