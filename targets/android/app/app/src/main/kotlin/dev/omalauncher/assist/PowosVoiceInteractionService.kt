package dev.omalauncher.assist

import android.service.voice.VoiceInteractionService

/**
 * PowOS AI as the phone's digital assistant (docs/POWAI-ASSISTANT.md): the service the assistant role points at.
 * Holding the power button (or the assist gesture) makes the system open a session ([PowosAssistSessionService]) with
 * the screen's text and a screenshot. Between sessions only the warm page waits (AssistWeb); no hotword yet.
 */
class PowosVoiceInteractionService : VoiceInteractionService() {
    /** The assistant is ready: its page loads now, so the first summoning is as quick as the rest. */
    override fun onReady() {
        super.onReady()
        AssistWeb.get(this)
    }
}
