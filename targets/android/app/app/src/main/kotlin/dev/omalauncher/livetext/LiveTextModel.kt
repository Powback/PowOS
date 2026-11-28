package dev.omalauncher.livetext

/**
 * Live Text's data, free of Android so the JVM tests hold it (docs/research/live-text.md): the words an OCR engine read,
 * in reading order, with their boxes in 0-1 of the image; what a selection between two words says; and the phone
 * numbers / links / emails / street addresses in it that become tappable chips.
 */
data class Word(
    val text: String,
    /** Box in 0-1 of the image: left, top, right, bottom. */
    val l: Float,
    val t: Float,
    val r: Float,
    val b: Float,
    /** The line it belongs to (index into the read's lines): a line break goes between words of different lines. */
    val line: Int,
) {
    fun contains(
        x: Float,
        y: Float,
        slop: Float = 0f,
    ) = x >= l - slop && x <= r + slop && y >= t - slop && y <= b + slop
}

/** One read of an image: its words in reading order, and which engine read it ("device" or "powstation"). */
data class Read(val words: List<Word>, val engine: String) {
    val text: String get() = textOf(0, words.size - 1)

    /** Words [from]..[to] (either order) as text: a space inside a line, a newline between lines. */
    fun textOf(
        from: Int,
        to: Int,
    ): String {
        if (words.isEmpty()) return ""
        val a = minOf(from, to).coerceIn(0, words.size - 1)
        val z = maxOf(from, to).coerceIn(0, words.size - 1)
        val sb = StringBuilder()
        for (i in a..z) {
            if (i > a) sb.append(if (words[i].line != words[i - 1].line) '\n' else ' ')
            sb.append(words[i].text)
        }
        return sb.toString()
    }

    /** The word under ([x], [y]) (0-1 of the image), or the nearest one within [slop]; -1: none. */
    fun wordAt(
        x: Float,
        y: Float,
        slop: Float = 0.02f,
    ): Int {
        words.indexOfFirst { it.contains(x, y) }.let { if (it >= 0) return it }
        var best = -1
        var bestD = Float.MAX_VALUE
        words.forEachIndexed { i, w ->
            if (!w.contains(x, y, slop)) return@forEachIndexed
            val cx = (w.l + w.r) / 2 - x
            val cy = (w.t + w.b) / 2 - y
            val d = cx * cx + cy * cy
            if (d < bestD) {
                bestD = d
                best = i
            }
        }
        return best
    }

    /** The first and last word of [word]'s line. */
    fun lineRange(word: Int): IntRange {
        val line = words[word].line
        val a = words.indexOfFirst { it.line == line }
        val z = words.indexOfLast { it.line == line }
        return a..z
    }

    companion object {
        /**
         * Lines (each a list of words with boxes, already split) into one [Read]: lines sorted top-to-bottom (by
         * centre, lines whose centres are within half a line height of each other read left to right), words left to
         * right inside a line.
         */
        fun ofLines(
            lines: List<List<Word>>,
            engine: String,
        ): Read {
            val kept = lines.map { ws -> ws.filter { it.text.isNotBlank() }.sortedBy { it.l } }.filter { it.isNotEmpty() }
            val sorted =
                kept.sortedWith { p, q ->
                    val pc = (p.minOf { it.t } + p.maxOf { it.b }) / 2
                    val qc = (q.minOf { it.t } + q.maxOf { it.b }) / 2
                    val h = minOf(p.maxOf { it.b } - p.minOf { it.t }, q.maxOf { it.b } - q.minOf { it.t })
                    if (kotlin.math.abs(pc - qc) < h / 2) p.minOf { it.l }.compareTo(q.minOf { it.l }) else pc.compareTo(qc)
                }
            return Read(sorted.flatMapIndexed { i, ws -> ws.map { it.copy(line = i) } }, engine)
        }

        /** A line's text with its box, split into words with boxes in proportion to their characters (PowStation's
         *  spotting gives line boxes only). [box]: the line's box (its text unused). */
        fun splitLine(
            text: String,
            box: Word,
        ): List<Word> {
            val (_, l, t, r, b) = box
            val total = text.length.coerceAtLeast(1)
            val out = mutableListOf<Word>()
            Regex("\\S+").findAll(text).forEach { m ->
                val a = l + (r - l) * m.range.first / total
                val z = l + (r - l) * (m.range.last + 1) / total
                out += Word(m.value, a, t, z, b, 0)
            }
            return out
        }
    }
}

/** A tappable thing in read text: what it is, the text as read, and what to open (tel:/https:/mailto:/geo:). */
data class Entity(val kind: Kind, val text: String, val uri: String) {
    enum class Kind { PHONE, URL, EMAIL, ADDRESS }
}

object Entities {
    /**
     * OCR splits an address around its "@" the way it splits words: ML Kit read the fixture's "hello@powback.com" as
     * "hello @powback.com" (11-28), and "a @ b.com" / "a@ b.com" are the same thing. Live Text still makes it one email,
     * so one space either side of the "@" belongs to it; [emailOf] puts it back together.
     */
    private val email = Regex("""[A-Za-z0-9._%+-]+[ \t]?@[ \t]?[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z0-9]{2,}""")

    /** OCR's usual misreads of a ".com" ending ("rn" for "m", "0" for "o"): no such TLDs exist, so they mean .com. */
    private val comMisread = Regex("""(?i)\.(?:corn|c0m|c0rn)$""")

    /** An [email] match without the spaces OCR put around the "@", with a misread .com fixed; null if the TLD
     *  isn't letters (a version string or IP-like tail). */
    private fun emailOf(v: String): String? {
        val e = comMisread.replace(v.replace(" ", "").replace("\t", ""), ".com")
        return if (e.substringAfterLast('.').all { it.isLetter() }) e else null
    }
    private val url = Regex("""(?i)\b(?:https?://|www\.)[^\s<>"]+|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|no|org|net|io|dev|app|se|dk|de|uk|eu)(?:/[^\s<>"]*)?""")

    /** +47 22 33 44 55, (555) 123-4567, 22334455: 8+ digits, separators allowed, optional +. */
    private val date = Regex("""\d{4}[-./]\d{1,2}[-./]\d{1,2}|\d{1,2}[-./]\d{1,2}[-./]\d{2,4}""")
    private val phone = Regex("""(?<![\w.])\+?\(?\d[\d ()./-]{6,}\d(?![\w])""")

    /** "Storgata 12", "12 Main Street", "Karl Johans gate 1, 0154 Oslo": a street word next to a house number. */
    private const val STREET =
        """(?:street|st\.?|road|rd\.?|avenue|ave\.?|lane|ln\.?|drive|dr\.?|boulevard|blvd\.?|way|place|pl\.?|""" +
            """gate|gata|gaten|veien|vei|veg|vegen|allé|alle|plass|plassen|stræde|straße|strasse|str\.?|vägen|gatan)"""
    private val address =
        Regex(
            // One line only ([ \t], not \s): across a line break the match would start in the line above.
            """(?i)\b(?:\d{1,5}[a-z]?[ \t]+(?:[A-ZÆØÅÄÖa-zæøåäöüß.'-]+[ \t]+){0,3}$STREET\b|""" +
                """(?:[A-ZÆØÅÄÖa-zæøåäöüß'-]+[ \t]+){0,2}[A-ZÆØÅÄÖa-zæøåäöüß'-]*$STREET[ \t]+\d{1,5}[a-z]?)""" +
                """(?:,?[ \t]+\d{4,5}[ \t]+[A-ZÆØÅÄÖ][a-zæøåäöüß]+)?""",
        )

    /** [norm]: the entity's text from the matched text (null: not one after all), [uri] from that. */
    private class Rule(val re: Regex, val kind: Entity.Kind, val norm: (String) -> String? = { it }, val uri: (String) -> String?)

    private val rules =
        listOf(
            Rule(email, Entity.Kind.EMAIL, ::emailOf) { "mailto:$it" },
            Rule(url, Entity.Kind.URL) { if (it.startsWith("http", true)) it else "https://$it" },
            Rule(address, Entity.Kind.ADDRESS) { "geo:0,0?q=" + java.net.URLEncoder.encode(it, "UTF-8") },
            Rule(phone, Entity.Kind.PHONE, uri = ::telOf),
        )

    /** tel: for 8-15 digits that aren't a date; null otherwise. */
    private fun telOf(v: String): String? {
        val digits = v.filter { it.isDigit() || it == '+' }
        return if (date.matches(v) || digits.count { it.isDigit() } !in 8..15) null else "tel:$digits"
    }

    private fun take(
        out: MutableList<Pair<IntRange, Entity>>,
        rule: Rule,
        m: MatchResult,
    ) {
        if (out.any { (r, _) -> r.first <= m.range.last && m.range.first <= r.last }) return
        val v = rule.norm(m.value.trimEnd('.', ',', ';', ':', ')')) ?: return
        rule.uri(v)?.let { out += m.range to Entity(rule.kind, v, it) }
    }

    /** Emails, links, addresses, then phone numbers - a later kind never takes text an earlier one has. */
    fun find(text: String): List<Entity> {
        val out = mutableListOf<Pair<IntRange, Entity>>()
        for (rule in rules) rule.re.findAll(text).forEach { m -> take(out, rule, m) }
        return out.sortedBy { it.first.first }.map { it.second }
    }
}
