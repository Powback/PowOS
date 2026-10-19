package dev.omalauncher.assist

import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService

/** Makes the assistant's sessions: one per summoning ([PowosAssistSession]). */
class PowosAssistSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession = PowosAssistSession(this)
}
