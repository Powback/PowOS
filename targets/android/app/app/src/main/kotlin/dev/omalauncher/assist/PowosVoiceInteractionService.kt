package dev.omalauncher.assist

import android.service.voice.VoiceInteractionService

/**
 * PowOS AI as the phone's digital assistant (docs/POWAI-ASSISTANT.md): the service the assistant role points at.
 * Holding the power button (or the assist gesture) makes the system open a session ([PowosAssistSessionService]) with
 * the screen's text and a screenshot. Nothing runs here between sessions: no hotword yet.
 */
class PowosVoiceInteractionService : VoiceInteractionService()
