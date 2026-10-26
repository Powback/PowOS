---
name: powos-voice
description: Use before touching PowOS phone dictation (Speech.kt, GpuSpeech.kt, dictation.ts, side button, stt.pow, "recognizer is busy"/doubled words, mic staying open) or the LAN's GPU servers (gpu-195, .58, llm.pow/stt.pow/voiceagent.pow routes, model loads, benchmarks, units, fan noise).
---

## Quick recipe
- Files: `targets/android/app/.../ui/{Speech,GpuSpeech}.kt`, `shell/ui/dictation.ts`, `WhisperJunk.kt`; GPU servers:
  `hosts/gpu-195/{install.sh,bench/*.py}`, `units/<host>/*.json`, `docs/GPU-SERVERS-PLAN.md`.
- Build: dictation is Kotlin - `tools/phone/compile-check.sh` before pushing. GPU servers: deploy .195 with
  `cd ~/Projects/PowOS && git pull --ff-only && hosts/gpu-195/install.sh [--no-build]` (ssh keys to
  `powos@192.168.50.195`/`.58`, no sudo; measure after, a restart touches voice-agent).
- Check: dictation - `tools/phone/verify/queue.sh add <task> tools/phone/verify/speech-test.sh [text] [mode]`
  (gpu/fallback/down, no mic needed, fine while the user is active); logs via
  `tools/phone/adb.sh shell 'logcat -d -v time | grep -E "/speech|capacity is full|RecognitionClient"'`. GPU
  servers - `curl :9292/running`, `python3 hosts/gpu-195/bench/{llm,voice}-bench.py <case>`; noise:
  `nvidia-smi --query-gpu=index,pstate,power.draw,fan.speed,temperature.gpu --format=csv`.
- Land (dictation): `tools/agents/land.sh "msg" -- <paths> --ship "..." --queue <check args>`. GPU servers have no
  ship/land path - changes deploy straight on the box; keep loads short and unload after (fan noise, no power cap).
- Friction: `tools/agents/friction add --area <speech|gpu-servers> --kind <...> "<title>" --repro "<cmd>"`.

## speech


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
  error after words counts as a segment's end: the partial is committed, and the SAME recognizer listens again 250 ms
  later, with no retry spent. A new recognizer right after destroying the old got SERVER_DISCONNECTED (11) on every
  listen. Before this fix the replay kept only the last sentence.
- stt.pow gives 200 `{"text":""}` for silence and clips under 0.5 s (since 2df111b; it used to answer 500). GpuSession
  tolerates a real 500 twice (no words from that request) and fails over on the third in a row.
- Release with GPU: the last ~300 ms before release can be missing (partials are chunked).
- Never write an AudioFeed pipe on main: a pipe holds 64 KB (2 s of PCM) and the recognizer reads only after
  startListening, so a write in open() with a fallback backlog froze the app for good (7 ANRs, 2026-10-23/24). Only the
  speech-feed thread writes. Check: tools/phone/verify/assist-freeze.sh (5 assist shows, fallback with a >2 s replay).

## stt.pow facts
stt-batch (whisper-fast large-v3-turbo, gpu-195 GPU1 :8001, Traefik `http://stt.pow`, LAN/VPN, no auth).
OpenAI-compatible `POST /v1/audio/transcriptions` (multipart `file`, `model=whisper-1`, `response_format=verbose_json`
gives `language`, `prompt`, `language`). `GET /health` returns `{"status":"ok",...}`. **No live streaming:**
`stream=true` is SSE of the already-uploaded file only. No speech gives 200 with empty text. A 2-3 s clip takes ~60-150 ms; the phone (Wi-Fi) pings it at
~12 ms. Server-side VAD is on. verbose_json segments carry only id/start/end/text: NO `no_speech_prob`/`avg_logprob`
(whisper-fast drops them; adding them is a VoiceAgent services/whisper-fast change on gpu-195, not in this repo).
- **Whisper junk on silence/noise** ("Субтитры создавал DimaTorzok", "Thanks for watching!", "Продолжение следует...",
  "Amara.org"): `WhisperJunk.clean` (WhisperJunk.kt, test WhisperJunkTest) on every GpuSession answer. Credit lines go
  per sentence (<= 8 words, sentence split only at punctuation + space); "Thank you."/"You"/"Bye"/"Спасибо" only as
  the whole answer (people say them after real speech). Drops log `dropped Whisper junk "..."`; add a phrase only
  after seeing it there. The cleaned text is also what goes into the next segment's prompt.
- Server model: large-v3-turbo (2024). Newer open ASR (Qwen3-ASR 1.7B, Canary-Qwen 2.5B, Parakeet) is a gpu-servers
  owner decision, not a dictation change.

## Logs and checks
- `tools/phone/adb.sh shell 'logcat -d -v time | grep -E "/speech|capacity is full|RecognitionClient"'`. Grep soon:
  the main buffer rolls over in minutes. Lines: `session #n: start|listen, attempt k (KIND)|error c|stop|cancel|end`,
  `session #n (gpu): ...`, `falling back to on-device (why), replaying N ms`, `recognizer: created|destroyed KIND
  (why)`, `stt.pow up|down`.
- Mic released: `dumpsys media.audio_flinger | grep -A2 "Input thread" | grep Standby` shows `yes` when idle.
- ASI connections: `dumpsys activity services com.google.android.as | grep AiAiSpeechRecognitionService`.

## Testing without the mic (the user may be using the phone)
- Scripted: `tools/phone/verify/queue.sh add <task> tools/phone/verify/speech-test.sh [text] [mode]` (all of the below).
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
- Unit tests: `targets/android/app/app/src/test/kotlin/dev/omalauncher/ui/SpeechDictationTest.kt` (the Dictation rules),
  `WhisperJunkTest.kt`. A worktree outside ~/Projects can't use compile-check.sh: run the android-builder image with
  `-v $PWD:/w` and `./gradlew :app:testDebugUnitTest --tests dev.omalauncher.ui.WhisperJunkTest` (also compiles main).

## gpu-servers


Design and every measurement: `docs/GPU-SERVERS-PLAN.md`. This is the working map.

## Topology
SSH `powos@192.168.50.195` and `powos@192.168.50.58` (keys installed, no sudo). Rootless podman, CDI GPUs from
`/var/run/cdi/nvidia.yaml` (`--device nvidia.com/gpu=N --security-opt label=disable`). Models: `/var/lib/powos/models`
(hf/ = shared HF cache, vllm/ = compile cache) on .195; podman volume `vllm-hf-cache` on .58.

| where | unit | port | what | VRAM |
|---|---|---|---|---|
| .195 GPU0 | voice-stt | 8000 | whisper-fast large-v3-turbo | 2.3 GiB |
| .195 GPU0 | voice-tts | 8880 | Kokoro bf_emma | 1.0 GiB |
| .195 GPU0 | voice-llm | 8100 | vLLM Qwen3-8B-AWQ as qwen3-8b, util 0.45, 16 seqs | 10.9 GiB |
| .195 CPU | voice-agent / voice-web | 9000 / 4321 | VoiceAgent (`~/Projects/VoiceAgent`, branch server-gpu195, unpushed) | - |
| .195 GPU1 | stt-batch | 8001 | whisper-fast for files (stt.pow) | 2.4 GiB resident |
| .195 GPU1 | llm-pool | 9292 | llama-swap v265 + vLLM, TTL 600 s: general (Qwen3-14B-AWQ, 0.70), vision (Qwen2.5-VL-7B-AWQ, 0.70), embed (bge-m3, 0.10); matrix `general&embed` / `vision&embed` | <= 19.2 GiB |
| .58 5090 | llama-swap-58 | 9292 | llama-swap v240 -> `run-vllm-32b.sh`: Qwen3-32B-AWQ as qwen-32b-vllm/coder-32b, 64k, TTL 300 s | 29.3 GiB |
GPU1 budget: 2.4 + 2.4 + 16.5 = 21.3 of 24. vLLM util is a share of the WHOLE card, checked against free memory at start.

## Routes (Traefik on .100, LAN/VPN only)
- `voiceagent.pow` (file route voiceagent.yml), `stt.pow` -> :8001, `llm-gpu.pow` -> .195:9292 (file routes, Pi-hole
  `dns.hosts` entry by API because dns-sync only sees Docker labels).
- `llm.pow` = PowStation compose service `llm-router` (LiteLLM v1.106.2, `config/litellm/config.yaml`). Bearer key
  `LLM_ROUTER_MASTER_KEY` in PowStation `.env` (LiteLLM refuses to start without a master key). Map: voice-fast ->
  .195:8100 (max 2 parallel; for others, not VoiceAgent), general/general-nothink/vision/embed -> .195:9292,
  coder-32b/-nothink -> .58:9292 (fallback general/-nothink), claude-* and anthropic/* -> claude-auth.pow (tenant
  sk-POWBACK), powos*/ wildcards -> .58. Never a local->Claude fallback; api.anthropic.com is blackholed.

## Commands
- Deploy .195: `cd ~/Projects/PowOS && git pull --ff-only && hosts/gpu-195/install.sh [--no-build]` (restarts
  voice-agent: measure after). Pool config edits: `-watch-config` reloads (and unloads what runs).
- Pool: `curl :9292/running`, `curl :9292/unload`, `curl :9292/v1/models`; logs `journalctl --user -u llm-pool`.
- Pool bench (stdlib): `python3 hosts/gpu-195/bench/llm-bench.py general|nothink|tools|embed|vision|concurrent`.
- Voice first audio: `cd hosts/gpu-195 && podman run --rm --network voice --security-opt label=disable -v
  "$PWD/bench:/bench:ro" localhost/voiceagent-backend:latest python /bench/voice-bench.py ws --n 10` (baseline
  ~640-665 ms median; run variance ~25 ms).
- Units: `python3 lib/apps/powos-units register units/<host>/<id>.json` (.195 via the shim). .58 has no units tool,
  so pipe the repo's tool over ssh (stdin is the script, so the manifest goes over by scp): `scp units/gpu-58/llama-swap-58.json powos@192.168.50.58:/tmp/u.json && ssh
  powos@192.168.50.58 'POWOS_UNITS_DIR=$HOME/.config/powos/units.d python3 - register /tmp/u.json && rm /tmp/u.json'
  < lib/apps/powos-units`.
- Every script this skill uses is in a repo: `hosts/gpu-195/bench/{llm,voice}-bench.py`, `hosts/gpu-195/install.sh`,
  `lib/apps/powos-units` (PowOS), `powos/run-vllm-32b.sh` + `powos/llama-swap.yaml` (local-llm-stack). To run a bench
  from the Mac, `scp` it from the checkout; on .195 run it from `~/Projects/PowOS` after `git pull`.
- Noise check: `nvidia-smi --query-gpu=index,pstate,power.draw,fan.speed,temperature.gpu --format=csv`.

## Measured (2026-10-21)
general 83 tok/s (x4: ~297), TTFT 32-56 ms, cold 40 s; vision 145 tok/s, cold 81 s; embed 524 texts/s, cold 47 s;
coder-32b 76-79 tok/s, cold 75 s, KV 73k tokens; voice first audio 640-665 ms with or without pool load.

## Pitfalls
- Qwen2.5-Coder writes tool calls as `<tools>{...}</tools>` text: hermes never parses them (0/3). Qwen3 works.
- 64k on the 5090 needs YaRN x2 (`--hf-overrides` `rope_parameters`, transformers 5), fp8 KV, util 0.92, 8 seqs.
- No comments inside a backslash-continued command (that is how --max-model-len/--port got lost on .58).
- vLLM needs `--served-model-name` = the name llama-swap forwards (else 404); for aliases use `useModelName`.
- `vllm serve <model>` positional first (0.32 rejects `--model` before it).
- llama-swap healthCheckTimeout 600 s: pre-download big models (`hf download` in the vLLM image, repeat `--exclude`
  per pattern) before a first start.
- Quadlet file binds don't see `install` (new inode): mount the config directory.
- The box runs on UTC: VoiceAgent needs `TZ=Europe/Oslo` (get_current_time).
- Full load = 100%/~300 W and loud fans (ASUS blowers; idle fans 56-77% is the vBIOS curve). The user said no power
  cap; keep loads short and unload after.
