package dev.omalauncher.widgets.lang

/**
 * How wide text is in the face a widget's text is drawn in, for `measure(text, size, bold)` (owl 9): advance widths in
 * em (a character's width at size 1), by code point, regular and bold. The host that draws the text knows its face: the
 * web shell measures its UI font (--font-body) with the browser's own measureText and sends the table (ui/owl.tsx
 * fontMetrics(), the bridge's widgets.metrics); without one, [MONO] - the monospace face the Compose launcher draws in.
 * Kerning is left out: a word's width is the sum of its characters' (within ~2% in the faces measured).
 */
class TextMetrics(
    private val regular: Map<Int, Double>,
    private val bold: Map<Int, Double> = regular,
    /** A character the table doesn't carry: about an average letter. */
    private val other: Double = 0.6,
) {
    fun width(
        text: String,
        size: Double,
        bold: Boolean = false,
    ): Double {
        val table = if (bold) this.bold else regular
        var w = 0.0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            i += Character.charCount(cp)
            w += table[cp] ?: if (wide(cp)) 1.0 else other
        }
        return w * size
    }

    companion object {
        /** Monospace: every character 0.6 em (DejaVu Sans Mono 0.602, JetBrains Mono 0.6, Android's mono 0.6). */
        val MONO = TextMetrics(emptyMap())

        /** CJK and other full-width characters: a whole em in any face. */
        private fun wide(cp: Int) = cp in 0x1100..0x115F || cp in 0x2E80..0xA4CF || cp in 0xAC00..0xD7A3 || cp in 0xF900..0xFAFF || cp in 0xFF00..0xFF60 || cp in 0x1F300..0x1FAFF

        /** A table as the shell sends it: { "regular": { "<char>": em }, "bold": {...}, "other": em }; null: not one. */
        fun of(v: Value?): TextMetrics? {
            val o = (v as? Obj)?.fields ?: return null
            val regular = table(o["regular"]).ifEmpty { return null }
            return TextMetrics(regular, table(o["bold"]).ifEmpty { regular }, em(o["other"])?.takeIf { it > 0 } ?: 0.6)
        }

        /** A width in em the table may carry: finite, 0 up to 4 em. */
        private fun em(v: Value?) = (v as? Num)?.v?.takeIf { it.isFinite() && it >= 0 && it < 4 }

        /** One weight's { "<char>": em }, by code point; keys that aren't one character are left out. */
        private fun table(v: Value?): Map<Int, Double> =
            (v as? Obj)?.fields.orEmpty().mapNotNull { (ch, w) -> oneCodePoint(ch)?.let { cp -> em(w)?.let { cp to it } } }.toMap()

        private fun oneCodePoint(ch: String) = ch.takeIf { it.isNotEmpty() && Character.charCount(it.codePointAt(0)) == it.length }?.codePointAt(0)
    }
}
