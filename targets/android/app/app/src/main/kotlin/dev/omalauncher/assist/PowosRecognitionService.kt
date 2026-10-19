package dev.omalauncher.assist

import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * The assistant role asks for a recognition service of the assistant's own (the role's requirement), and the system
 * may make it the phone's default speech recognizer: this one passes every request on to the phone's on-device
 * recognizer (or its regular one), as is, and its results back - nothing of its own.
 */
class PowosRecognitionService : RecognitionService() {
    private var recognizer: SpeechRecognizer? = null

    override fun onStartListening(
        intent: Intent,
        callback: Callback,
    ) {
        recognizer?.destroy()
        val r =
            if (SpeechRecognizer.isOnDeviceRecognitionAvailable(this)) SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
            else SpeechRecognizer.createSpeechRecognizer(this)
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
