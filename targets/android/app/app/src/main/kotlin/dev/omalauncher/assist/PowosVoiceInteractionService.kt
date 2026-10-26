package dev.omalauncher.assist

import android.os.Bundle
import android.service.voice.VoiceInteractionService
import android.service.voice.VoiceInteractionSession

/**
 * PowOS AI as the phone's digital assistant (docs/POWAI-ASSISTANT.md): the service the assistant role points at.
 * Holding the power button (or the assist gesture) makes the system open a session ([PowosAssistSessionService]) with
 * the screen's text and a screenshot. Between sessions only the warm page waits (AssistWeb); no hotword yet.
 */
class PowosVoiceInteractionService : VoiceInteractionService() {
    /** The assistant is ready: its page loads now, so the first summoning is as quick as the rest. */
    override fun onReady() {
        super.onReady()
        running = this
        AssistWeb.get(this)
        // The side button's release, for hold-to-talk (PowosAssistSession): read from now on, so the first hold has it.
        PowerKey.start()
    }

    override fun onShutdown() {
        if (running === this) running = null
        super.onShutdown()
    }

    companion object {
        private var running: PowosVoiceInteractionService? = null

        /**
         * Opens the assistant over the screen as the side button does (with the screen's text and screenshot, for
         * circle-to-select): an edge gesture's. False when PowOS isn't the assistant (or it isn't ready yet).
         */
        fun show(): Boolean {
            val s = running ?: return false
            return runCatching {
                s.showSession(Bundle(), VoiceInteractionSession.SHOW_WITH_ASSIST or VoiceInteractionSession.SHOW_WITH_SCREENSHOT)
                true
            }.getOrDefault(false)
        }
    }
}
