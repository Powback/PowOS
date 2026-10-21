---
name: powos-speech
description: Load before touching PowOS phone dictation (Speech.kt, GpuSpeech.kt, dictation.ts, push-to-talk, the side button) or debugging "speech recognizer is busy", doubled/lost words, stt.pow, or the mic staying open.
---

# PowOS dictation: how it works and where it bites

## Path
Shell `shell/ui/dictation.ts` (the only consumer: listen/makeHold/release/interrupt; release = send the shown text at
once, then `speech.cancel`). It calls bridge `speech.start(hold)|stop|hold|quiet(ms)|cancel|warm`, which goes to
`ShellBridge.kt` and then `Speech` (one per bridge window; state goes to the page as `speech.state`, the result as
`speech.done`). `Speech.start` calls `SpeechEngines.start` (GpuSpeech.kt): one session at a time across both engines,
and the latest start wins.
- **GPU (default):** `GpuSession` records itself (`MicSource`: AudioRecord VOICE_RECOGNITION, 16 kHz mono PCM16, 20 ms
  frames, keeps everything). It cuts segments at 700 ms pauses (min 1.2 s, max 25 s) by loudness over a tracked floor.
  Partials go to stt.pow back to back (one request in flight, on its own executor per session); each segment gets a
  final with the earlier text as the prompt.
- **On-device:** `NativeSpeech` (Speech.kt): Android's SpeechRecognizer. Its plan (on-device ASI if it has the
  language installed, else the regular Google recognizer `com.google.android.tts`) is cached for 5 min. It uses
  segmented sessions on API 33+, else restarts at each pause.
- **Fallback (per session):** stt.pow known down (`SttServer` /health, cached 30 s, 400 ms connect), no answer within
  1.5 s of the first voice, an error, or a hung request. The untranscribed audio, from the first unfinished segment,
  replays into NativeSpeech through `AudioFeed` (a pipe per listen, `EXTRA_AUDIO_SOURCE`, API 33+), then live.
- **Setting:** settings tile "voice" (screens.tsx), `speechEngine` in shell/state.ts. It writes store `speech` =
  `{engine:"gpu"|"ondevice"}` to files/shell-data/speech.json, read at every start. Store an object: store.set quotes
  strings, and a quoted string silently fell back to the GPU default (64a2468).
- **Side button:** assist/PowerKey.kt (root getevent on pmic_pwrkey) goes to the assist page (mode=assist):
  `dictate(mic, true)`, `assist.quick` leads to `speech.quiet(ms)`, key-up leads to release.

## Pitfalls (learned on the phone, 2026-10-21)
- **ASI holds ONE session** ("#startListening received when the service's capacity is full - ignoring this call",
  then ERROR_RECOGNIZER_BUSY 8). A session never cancelled there blocks every later start, whatever recognizer object
  asks, even after our app restarts. The cause was a stop whose final never came: the end didn't cancel. Now every end
  cancels. BUSY/CLIENT destroy the recognizer and retry once on a new one; if on-device is still full, the regular
  recognizer takes over for 10 min. To clear a wedged ASI: `su -c "kill $(pidof com.google.android.as)"` (it
  restarts; a one-off, not code).
- system_server allows one session per caller per recognizer: never keep two live recognizers of one kind.
- A start right after a cancel can get CLIENT once: segmenting turns off only after 2 refusals in a row.
- A doubled dictation was the user testing two engines back to back, not a bug. Check the logs before "fixing" text.
- An ended recording ends the session: `Dictation.goOn(feedDone)` (a fallback after the release doesn't listen again on
  an ended pipe).
- ASI reading PowOS's recording (`EXTRA_AUDIO_SOURCE`) ends each utterance with ERROR_CLIENT (5), not results. A CLIENT
  error after words counts as a segment's end: the partial is committed, a new recognizer is used, and no retry is
  spent. Before this fix the replay kept only the last sentence.
- stt.pow answers HTTP 500 to audio with no speech (silence, clips under ~0.5 s): GpuSession pads clips to 1 s and
  reads a 500 as "nothing heard", failing over only after 3 in a row (a `HACK:`; the real fix is in stt-batch).
- Release with GPU: the last ~300 ms before release can be missing (partials are chunked).

## stt.pow facts
stt-batch (whisper-fast large-v3-turbo, gpu-195 GPU1 :8001, Traefik `http://stt.pow`, LAN/VPN, no auth).
OpenAI-compatible `POST /v1/audio/transcriptions` (multipart `file`, `model=whisper-1`, `response_format=verbose_json`
gives `language`, `prompt`, `language`). `GET /health` returns `{"status":"ok",...}`. **No live streaming:**
`stream=true` is SSE of the already-uploaded file only. No speech gives 500, not empty text. A 2-3 s clip takes ~60-150 ms; the phone (Wi-Fi) pings it at
~12 ms. Server-side VAD is on. "Thank you."-style hallucinations on silence are filtered in GpuSession.

## Logs and checks
- `tools/phone/adb.sh shell 'logcat -d -v time | grep -E "/speech|capacity is full|RecognitionClient"'`. Grep soon:
  the main buffer rolls over in minutes. Lines: `session #n: start|listen, attempt k (KIND)|error c|stop|cancel|end`,
  `session #n (gpu): ...`, `falling back to on-device (why), replaying N ms`, `recognizer: created|destroyed KIND
  (why)`, `stt.pow up|down`.
- Mic released: `dumpsys media.audio_flinger | grep -A2 "Input thread" | grep Standby` shows `yes` when idle.
- ASI connections: `dumpsys activity services com.google.android.as | grep AiAiSpeechRecognitionService`.

## Testing without the mic (the user may be using the phone)
- Server: `say -o /tmp/t.aiff "Testing one two three"; afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/t.aiff /tmp/t.wav;
  curl -F file=@/tmp/t.wav -F model=whisper-1 http://stt.pow/v1/audio/transcriptions`.
- On the phone (no mic, fine while the user is active): bridge `speech.test(name, mode)` calls
  `SpeechEngines.test`, which plays a 16 kHz mono 16-bit WAV from files/speech-test/ in place of the mic and logs
  `test (mode): "<text>"`. Modes: `gpu`, `fallback` (stt.pow made to fail after its first answer), `down` (on-device
  from the file). Make a WAV: `say -o a.aiff "One sentence. [[slnc 1500]] Another."; afconvert -f WAVE -d
  LEI16@16000 -c 1 a.aiff t.wav`. Push: `tools/phone/adb.sh push t.wav /data/local/tmp/speech-t.wav`, then `su -c`
  to cp it to /data/data/com.powos.app/files/speech-test/t.wav and chown it to the app uid (`stat -c %u
  /data/data/com.powos.app`). Run: `tools/phone/cdp.sh eval home "(()=>{window.PowosHost.postMessage(JSON.stringify([910001,'speech.test',JSON.stringify(['t.wav','gpu'])]));return 1})()"`,
  wait ~15 s, then grep logcat for `test (`.
- Double-start / BUSY check over CDP with `tools/phone/cdp.sh eval home '<js>'` (the repo's: it forwards the devtools
  socket and runs tools/phone/cdp.ts; don't use copies in job tmp or ~/.cache, they get pruned). The js:
  `(async()=>{const h=window.PowosHost;for(const i of [1,2])h.postMessage(JSON.stringify([900000+i,"speech.start","[false]"]));await new Promise(r=>setTimeout(r,4000));h.postMessage(JSON.stringify([900003,"speech.cancel","[]"]));return "ok"})()`
  (cancel within the 8 s eval timeout). That opens the mic: only at idle >= 120 s.
- Unit tests: `targets/android/app/app/src/test/kotlin/dev/omalauncher/ui/SpeechDictationTest.kt` (the Dictation rules).
