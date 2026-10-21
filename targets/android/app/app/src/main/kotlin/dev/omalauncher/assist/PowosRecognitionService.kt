package dev.omalauncher.assist

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * The assistant role asks for a recognition service of the assistant's own (the role's requirement), and the system
 * may make it the phone's default speech recognizer: this one passes every request on to the phone's real recognizer
 * (NativeSpeech.regularService: the system default unless that's this service, then Google's speech services), as
 * is, and its results back - nothing of its own. Never to "the default" blindly: with this service as the default
 * that would be itself, forever. Not to the on-device one either: on this phone (Android System Intelligence) it
 * often has no model for the language, and the caller's intent may ask for offline itself.
 */
class PowosRecognitionService : RecognitionService() {
    private var recognizer: SpeechRecognizer? = null

    override fun onStartListening(
        intent: Intent,
        callback: Callback,
    ) {
        recognizer?.destroy()
        val target = dev.omalauncher.ui.NativeSpeech.regularService(this) ?: return callback.error(SpeechRecognizer.ERROR_CLIENT)
        val r = SpeechRecognizer.createSpeechRecognizer(this, target)
        r.setRecognitionListener(
            object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = callback.readyForSpeech(params ?: Bundle())

                override fun onBeginningOfSpeech() = callback.beginningOfSpeech()

                override fun onRmsChanged(rmsdB: Float) = callback.rmsChanged(rmsdB)

                override fun onBufferReceived(buffer: ByteArray?) = buffer?.let(callback::bufferReceived) ?: Unit

                override fun onEndOfSpeech() = callback.endOfSpeech()

                override fun onError(error: Int) = callback.error(error)

                override fun onResults(results: Bundle?) = callback.results(results ?: Bundle())

                override fun onPartialResults(partialResults: Bundle?) = callback.partialResults(partialResults ?: Bundle())

                override fun onEvent(
                    eventType: Int,
                    params: Bundle?,
                ) {}
            },
        )
        recognizer = r
        r.startListening(intent)
    }

    override fun onStopListening(callback: Callback) {
        recognizer?.stopListening()
    }

    override fun onCancel(callback: Callback) {
        recognizer?.cancel()
    }

    override fun onDestroy() {
        recognizer?.destroy()
        recognizer = null
        super.onDestroy()
    }
}
