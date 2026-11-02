package dev.omalauncher.ui

import android.text.InputType
import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertEquals
import org.junit.Test

/** A terminal's field tells the IME what Termux's TerminalView does (PowTerm's input): keys at once, no suggestions. */
class TerminalEditorInfoTest {
    @Test
    fun visiblePasswordWithoutSuggestions() {
        val info = EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE }
        terminalEditorInfo(info, cjk = false)
        assertEquals(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS,
            info.inputType,
        )
        assertEquals(EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI, info.imeOptions)
    }

    @Test
    fun cjkKeyboardKeepsPlainText() {
        val info = EditorInfo()
        terminalEditorInfo(info, cjk = true)
        assertEquals(InputType.TYPE_CLASS_TEXT, info.inputType)
    }
}
