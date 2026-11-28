package dev.omalauncher.livetext

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Live Text's gate with its fixture image (src/test/resources/livetext/fixture.png): PowStation's real read of it
 * (fixture.powstation.json, PowScan /api/ocr spot, PaddleOCR-VL-1.6) parses into words in reading order, selections
 * give the right text, and every tappable thing in it is found. The device read of the same image runs on the phone
 * (tools/phone/verify/live-text.sh).
 */
class LiveTextTest {
    private fun fixture(name: String) = javaClass.getResource("/livetext/$name")!!.readText()

    private val read = LiveTextOcr.parseSpots(fixture("fixture.powstation.json"))!!

    @Test fun powstationReadOfTheFixtureParses() {
        assertEquals("powstation", read.engine)
        assertEquals(
            "PowOS Live Text\nCall +47 22 33 44 55\nVisit www.powback.com\nMail hello@powback.com\nStorgata 12, 0155 Oslo",
            read.text,
        )
    }

    @Test fun dragSelectsARunAcrossLinesEitherWay() {
        val a = read.words.indexOfFirst { it.text == "Text" }
        val z = read.words.indexOfFirst { it.text == "+47" }
        assertEquals("Text\nCall +47", read.textOf(a, z))
        assertEquals("Text\nCall +47", read.textOf(z, a))
    }

    @Test fun tapFindsTheWordAndItsLine() {
        val w = read.words.first { it.text == "www.powback.com" }
        val i = read.wordAt((w.l + w.r) / 2, (w.t + w.b) / 2)
        assertEquals("www.powback.com", read.words[i].text)
        val line = read.lineRange(i)
        assertEquals("Visit www.powback.com", read.textOf(line.first, line.last))
        assertEquals(-1, read.wordAt(0.95f, 0.95f))
    }

    @Test fun fixtureEntitiesAreTappable() {
        val found = Entities.find(read.text).associate { it.kind to it.uri }
        assertEquals("tel:+4722334455", found[Entity.Kind.PHONE])
        assertEquals("https://www.powback.com", found[Entity.Kind.URL])
        assertEquals("mailto:hello@powback.com", found[Entity.Kind.EMAIL])
        assertNotNull(found[Entity.Kind.ADDRESS])
        assertTrue(found[Entity.Kind.ADDRESS]!!.contains("Storgata"))
    }

    /** ML Kit's actual read of the fixture on the phone (verify queue 11-28 04:49): it splits the email at the "@". */
    @Test fun deviceReadOfTheFixtureFindsTheSplitEmail() {
        val device = "PowOS Live Text\nCall +47 22 33 44 55\nVisit www.powback.com\nMail hello @powback.com\nStorgata 12, 0155 Oslo"
        val found = Entities.find(device)
        assertEquals(listOf(Entity(Entity.Kind.EMAIL, "hello@powback.com", "mailto:hello@powback.com")), found.filter { it.kind == Entity.Kind.EMAIL })
        // The email's domain is no separate link any more; www.powback.com still is.
        assertEquals(listOf("www.powback.com"), found.filter { it.kind == Entity.Kind.URL }.map { it.text })
        assertEquals(setOf(Entity.Kind.PHONE, Entity.Kind.URL, Entity.Kind.EMAIL, Entity.Kind.ADDRESS), found.map { it.kind }.toSet())
    }

    @Test fun emailsSurviveCommonOcrSplitsAndMisreads() {
        val email = { s: String -> Entities.find(s).filter { it.kind == Entity.Kind.EMAIL }.map { it.uri } }
        for (s in listOf("hello@ powback.com", "hello @ powback.com", "mail hello@powback.corn", "hello@powback.c0m.")) {
            assertEquals(s, listOf("mailto:hello@powback.com"), email(s))
        }
        assertEquals(listOf("mailto:a.b@mail.example.no"), email("to a.b@mail.example.no,"))
        // Not emails: a lone "@" between words, no dot in the domain, a numeric tail.
        assertTrue(email("meet @ noon").isEmpty())
        assertTrue(email("user@localhost").isEmpty())
        assertTrue(email("build 1.2@3.45").isEmpty())
    }

    @Test fun moreEntityShapes() {
        val kinds = { s: String -> Entities.find(s).map { it.kind to it.text } }
        assertEquals(listOf(Entity.Kind.PHONE to "(555) 123-4567"), kinds("ring (555) 123-4567 now"))
        assertEquals(listOf(Entity.Kind.URL to "https://x.dev/a?b=1"), kinds("see https://x.dev/a?b=1."))
        assertEquals(listOf(Entity.Kind.ADDRESS to "12 Main Street"), kinds("at 12 Main Street"))
        assertEquals(listOf(Entity.Kind.ADDRESS to "Karl Johans gate 1, 0154 Oslo"), kinds("Karl Johans gate 1, 0154 Oslo"))
        // Not phone numbers: dates, short numbers, prices.
        assertTrue(kinds("2026-11-27 at 12:30, 1 299,00 kr").none { it.first == Entity.Kind.PHONE })
    }

    @Test fun ofLinesOrdersLinesTopToBottomAndWordsLeftToRight() {
        val r =
            Read.ofLines(
                listOf(
                    listOf(Word("b", 0.5f, 0.5f, 0.6f, 0.6f, 0), Word("a", 0.1f, 0.5f, 0.2f, 0.6f, 0)),
                    listOf(Word("top", 0.1f, 0.1f, 0.3f, 0.2f, 0)),
                ),
                "device",
            )
        assertEquals("top\na b", r.text)
    }
}
