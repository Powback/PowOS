# GPU servers: the plan (2026-10-21)

PowOS now has real GPU servers on the LAN. This is how inference (voice, LLMs, everything AI) is laid out across
them, how it's run and managed, and the order to build it in. Status: **phases 1-3 built on `.195` (2026-10-21), see
[Status](#status-2026-10-21); phases 4-6 not started**.

## What we have

| host | GPUs | role in this plan |
|---|---|---|
| `192.168.50.195` (new PowOS box, Bazzite 44 nvidia-open, 8 cores, 62 GB, 3.6 TB NVMe) | 2x RTX 3090 24 GB | **realtime + general inference**: GPU0 = voice (always fast), GPU1 = general LLM pool |
| `192.168.50.58` (PowOS, still up: Ollama answers) | RTX 5090 32 GB | **big models**: the 32B-class coder/reasoning model (llama-swap :9292 + Ollama :11434, as today) |
| `192.168.50.100` (Colima on the Mac) | none | **router + front door**: Traefik, Authelia, Pi-hole, the LLM router, claude-auth |
| phone (OnePlus Open), glasses (Even G2) | Adreno 740 | **clients**: PowOS AI voice, glasses mic/HUD |

Prior work this reuses, not rewrites:
- `~/Projects/VoiceAgent`: FastAPI voice agent with a WebSocket at `/ws` and `/transcribe`. It has Silero VAD,
  wake words on the transcript ("hey luna"), barge-in, speaker diarization and ChromaDB recall. The web UI is Astro,
  routed as `voiceagent.pow`, and Powpanion's "Luna" panel connects to it.
  - Ran CUDA on a Windows box until 2026-03, then CPU/MLX on the Mac (commit 6b1f44b), which is why it died off the Mac.
- `~/Projects/local-llm-stack`: the LiteLLM router (Mac) plus the `powos/` GPU side.
  - The GPU side is rootless podman + CDI (`nvidia.com/gpu`, `label=disable`), Ollama, llama-swap, a vLLM VRAM gate.
  - Known bug: `run-vllm-32b.sh` has a comment inside the backslash continuation, so `--max-model-len` / `--port`
    never reach vLLM.

## Principles

1. **One front door for models.** Every client asks `llm.pow` (the LiteLLM router), one OpenAI-compatible endpoint.
   - Model names, not hosts: `voice-fast`, `general`, `coder-32b`, `claude-*`.
   - The router decides where each one runs, so moving a model between boxes changes one config line, not clients.
2. **Every service is a registered PowOS unit** (`powos units`) with owner, limits, autosleep and a removal path.
   - No ad-hoc `docker run`, no host-level pip/conda (memory: no unmanaged system deps).
   - Containers are rootless podman with CDI GPUs, pinned to a GPU each.
3. **Voice is never queued behind batch work.**
   - GPU0 on `.195` belongs to the realtime voice path and nothing else may allocate on it.
   - Everything else shares GPU1 and the 5090, swapped on demand.
4. **Idle = no VRAM, near-zero power, fast wake.**
   - Big models load on first request (llama-swap with a TTL) and unload when idle.
   - The voice path stays resident: about 13 GB, and the price of sub-second replies.
5. **Images built from the repo, not bind-mounted from the Mac.** VoiceAgent's compose mounts `/Users/macback/...`.
   On the server it runs from images built from the repo (CI on the hub or `podman build` on the box) with config in
   env files.
6. **Private by default.**
   - `*.pow` on the LAN and VPN.
   - Public `*.powback.com` only behind Authelia (with the documented WebSocket bypasses).
   - Nothing calls out to cloud APIs except `claude-auth.pow`.

## Layout

### `.195` GPU0: realtime voice (resident, ~13-15 GB of 24)
| service | what | VRAM |
|---|---|---|
| `stt` | faster-whisper (CUDA) `large-v3-turbo`, float16 (replaces MLX Whisper) | ~3 GB |
| `tts` | Kokoro (`kokoro-fastapi-gpu`), voice `bf_emma` | ~1.5 GB |
| `voice-llm` | vLLM `Qwen3-8B-AWQ`, `--gpu-memory-utilization 0.42`, max-model-len 16k, tool calling (hermes parser); the voice agent's fast model | ~10 GB |
| `voice-agent` | the VoiceAgent backend (VAD, diarization, recall on CPU), `/ws` | CPU, ~2 GB RAM |
| `voice-web` | the Astro UI | CPU |

Target: end of speech -> first audio in **< 800 ms** (STT ~150 ms, first token ~150 ms, first TTS chunk ~150 ms).

### `.195` GPU1: general pool (on demand, llama-swap)
- llama-swap (:9292) fronting vLLM / llama.cpp profiles, one loaded at a time, TTL 10 min:
  - `general`: Qwen3-14B-AWQ (agents, summaries, tools).
  - `vision`: Qwen2.5-VL-7B (screenshots from PowOS AI's assistant).
  - `embed`: bge-m3 for recall/RAG (small, can co-reside).
- Ollama (:11434) stays for quick model trials, on the same GPU under the same VRAM gate.
- Batch jobs (transcribing meetings, embeddings, image gen later) queue here, never on GPU0.

### `.58` RTX 5090: big models (as today, cleaned up)
- `coder-32b`: Qwen2.5-Coder-32B-AWQ (or Qwen3-32B-AWQ) via llama-swap, 64k context. The `run-vllm-32b.sh`
  continuation bug gets fixed.
- When the 5090 is busy or off, the router falls back to `general` on `.195` GPU1.
- Tensor-parallel across both 3090s (48 GB) is possible for a 70B-class model, but only when voice is explicitly
  off. That's not a default.

### Router and front door (`.100`)
- LiteLLM (local-llm-stack) is the router. It runs on the Mac today and is currently not answering on :4000; it
  becomes a Colima service `llm.pow`.
  - The model list is repointed: `voice-fast` -> `.195:8100`, `general`/`vision`/`embed` -> `.195:9292`,
    `coder-32b` -> `.58:9292`, `claude-*` -> `claude-auth.pow`.
  - It keeps the api.anthropic.com blackhole.
- Traefik file-provider routes to the GPU boxes (they're not Colima containers): `voiceagent.pow`,
  `voiceagent.powback.com` (Authelia; `/ws` handled like the other WebSocket bypasses), `llm-gpu.pow`.

## Clients

- **Phone (PowOS AI): a voice mode.**
  - The app streams mic PCM to `voiceagent.pow/ws` and plays the TTS stream back. Long-press power can open it.
  - Tool calls go to the PowOS AI agents, so voice can do what the chat can: `claude-*` through the router for
    heavy tasks, the local `voice-fast` for chit-chat and quick answers.
- **Even G2 glasses.**
  - The glasses mic goes through the phone app to the same `/ws` (the VAD threshold is already tuned for the
    glasses mic).
  - Replies go to the glasses HUD as text.
  - Needs the G2 mic format confirmed (likely LC3, decode on the phone before sending; docs/GLASSES.md).
- **Powpanion "Luna" panel**: `LUNA_API_URL` already names `http://192.168.50.195:9000`; point it at
  `voiceagent.pow`.
- **Pi kiosk / desktop browser**: the web UI, unchanged.
- **Agents (PowOS AI, Claude Code on the fleet)**: local models via `llm.pow` for cheap sub-tasks (summaries,
  classification, embeddings); Claude stays the primary.

## Operations

- **Units:**
  - `.195` gets a current PowOS with `powos units`; it's on an older build without it.
  - Each service is a unit with GPU pin, VRAM budget, memory/CPU/pid limits, autosleep policy, owner `voice` /
    `llm`, and removal commands.
  - `powos units check` on `.195` must show no orphans.
- **GPU access:** generate the CDI spec (`nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`; it's missing) as a
  registered host change. Containers use `--device nvidia.com/gpu=0|1` plus `--security-opt label=disable`.
- **Autosleep:** the voice path stays resident; llama-swap TTLs unload the pool; idle 3090s sit at P8 (~17-20 W
  each); `powos sleep status` shows each model loaded/unloaded.
- **Health and overview:**
  - Each service has a health endpoint.
  - A GPU panel (VRAM per service, loaded models, tokens/s, voice latency) is published to the units overview on the
    PowOS AI page.
  - A latency probe runs the voice round trip every 15 min while idle.
- **Storage:**
  - Models live on the NVMe under `/var/lib/powos/models` (HF cache shared by vLLM / faster-whisper, Ollama's own
    dir), one copy each, as a registered unit with a size budget.
  - The 3.7 TB external drive takes backups and model archives.
- **Compute mesh** (the spec from 2026-10-20): `.195` and `.58` are its first GPU nodes. This plan's units are what
  the mesh schedules later.

## Phases (each verified before the next)

1. **Base.**
   - Update `.195` to current PowOS (`powos units`, sleep, agents hook).
   - CDI spec, rootless podman GPU test (`nvidia-smi` in a container on each GPU).
   - Model storage unit.
   - Register the box in the fleet docs (CLAUDE.md network table).
2. **Voice core on GPU0.**
   - stt + tts + voice-llm as units.
   - Measure each one alone (latency, VRAM).
3. **VoiceAgent ported.**
   - Images from the repo, CUDA providers back (pre-6b1f44b), `WHISPER_URL`/`VLLM_URL`/`KOKORO_URL` to the units, no
     Mac paths, no `--reload`.
   - Traefik routes `voiceagent.pow` (+ the public one behind Authelia).
   - Verify: browser round trip < 800 ms to first audio, barge-in, wake word.
4. **Router.**
   - LiteLLM as `llm.pow` on Colima with the new model map.
   - Fix the `run-vllm-32b.sh` bug on `.58`.
   - GPU1 llama-swap profiles.
   - Verify every model name answers through `llm.pow`, and a fallback when `.58` is off.
5. **Phone and glasses.**
   - PowOS AI voice mode (APK) against `/ws`.
   - G2 mic -> phone -> `/ws`, replies on the HUD.
   - Powpanion Luna repointed.
6. **Overview and autosleep.** GPU panel, latency probe, TTLs tuned, `powos units check` clean on every host.

## Open decisions (defaults chosen; say if different)

- **Voice LLM:** Qwen3-8B-AWQ on GPU0 (fast, tool calling).
  - Alternative: route voice to `general` 14B on GPU1 (smarter, ~300 ms slower first token, and it competes with
    the pool).
- **Public voice endpoint:** `voiceagent.powback.com` behind Authelia, as before.
- **The 5090 box stays** the big-model host. If it's going away, `coder-32b` moves to tensor-parallel on the two
  3090s with voice off-hours, or to a 14B on GPU1.

## Status (2026-10-21)

Phases 1-3 are up on `.195`, deployed by `hosts/gpu-195/install.sh` (quadlets, env, image builds, unit registration;
idempotent, run as `powos` from `~/Projects/PowOS`). Units: `units/gpu-195/*.json` (host `desktop`, the box's
platform). VoiceAgent ran unchanged: config only (branch `server-gpu195` in `~/Projects/VoiceAgent`, not pushed).

**Base.**
- CDI: nothing to do. The image's `nvidia-cdi-refresh` already writes `/var/run/cdi/nvidia.yaml` at boot and on driver
  changes, and podman reads it. A static `/etc/cdi` copy would go stale on the next driver update, so none was made.
  `podman run --device nvidia.com/gpu=0|1 --security-opt label=disable ... nvidia-smi -L` works on both 3090s, rootless.
- `powos units`: the box runs image 0.3.0 (0f5e878, built from master), which has no units tool, and an image update
  means `rpm-ostree` + a reboot. The desktop session (seat0, auto-login, screen locked) was live, so there was no
  reboot. `/usr/local/bin/powos` (unit `powos-units-shim`, a marked HACK) routes `units` to a git checkout of
  `worktree-powos-multiplatform` at `~/Projects/PowOS`, and everything else to the image's `/usr/bin/powos`.
  - Real fix: an image with powos-units, then `rpm-ostree upgrade` + reboot at a quiet time, then remove the shim.
- Fleet docs: `~/Projects/CLAUDE.md` network table has the box.
- Linger was already on. Firewalld's FedoraWorkstation zone already allows 1025-65535/tcp, so the service ports
  needed no change.
- Models: `/var/lib/powos/models` (unit `models-store`).
  - `hf/` is the HF cache shared by vLLM, faster-whisper and the backend.
  - `torch/` holds Silero VAD; `vllm/` is vLLM's compile cache.
  - 8.2 GB used.
- `powos units check` claims every process the units added.
  - Its "outside its cgroup" list shows only podman's own helpers (conmon, rootlessport). They sit in each quadlet's
    service cgroup, next to the container payload, and podman enforces the unit's limits on that payload.
  - It still lists the base OS: Bazzite's own /etc/systemd links, the desktop's processes, and an unexplained
    `/etc/systemd/system/powback-stripe.service`. The box has no baseline unit yet.
  - That is phase 6: `powos units baseline`, after someone looks at powback-stripe.

**Voice core on GPU0** (rootless podman quadlets, `Restart=always`, started at boot, `autosleep: never`):

| unit | image | port | VRAM measured | RAM (limit) |
|---|---|---|---|---|
| `voice-stt` | `localhost/voice-stt-fast` (VoiceAgent `services/whisper-fast` on faster-whisper-server's CUDA image), `deepdml/faster-whisper-large-v3-turbo-ct2` float16 | 8000 | 2.3 GiB | 0.7 GB (6g) |
| `voice-tts` | `remsky/kokoro-fastapi-gpu:latest`, bf_emma | 8880 | 1.0 GiB | 1.6 GB (4g) |
| `voice-llm` | `vllm/vllm-openai:latest`, `Qwen/Qwen3-8B-AWQ` as `qwen3-8b` | 8100 | 10.9 GiB | 2.9 GB (16g) |

GPU0 total: 15.5 GiB of 24, including about 30 MB for the desktop's kwin. It sits at P2, about 130 W, with everything
resident; GPU1 is idle at P8, about 19 W.

**STT for everything else on GPU1** (2026-10-21): `stt-batch`, the same whisper-fast image and model as `voice-stt`,
resident on GPU1 (2.4 GiB), :8001, served as `http://stt.pow` (Traefik on `.100`, PowStation
`config/traefik/dynamic/stt.yml`; Pi-hole `dns.hosts`). Files and dictation from every PowOS (`powos transcribe`,
anything OpenAI-compatible) never queue a voice turn: GPU0 stays the voice path's alone, and the batch container gets
2 CPUs at cpu-shares 128. Settings: Silero VAD, timestamps on for audio over one 30 s window (without them
faster-whisper drops the words at window boundaries: 84% of a 12 min recording's words came back instead of ~100%),
500 MB uploads (413), 4 requests running or waiting (503; Traefik inFlightReq 4 -> 429), `stream=true` SSE.

| measured 2026-10-21 | |
|---|---|
| 3.3 s clip via stt.pow (Mac, LAN) | 0.08-0.13 s round trip |
| 12 min 12 s speech (23 MB wav / 3 MB m4a) | 12.0-12.8 s (~60x realtime), GPU1 ~86% |
| voice-bench `stt` / `ws` idle | 55.9 ms; end of speech -> first audio 644 ms |
| same, while 12 min files transcribe back to back on stt.pow | 60.2 ms; 615 ms (unchanged) |

- vLLM's budget: 0.42 with the default `--max-num-seqs` (256) left 1.35 GiB of KV cache, and one 16k sequence needs
  2.25 GiB, so vLLM refused to start. With `--max-num-seqs 16` and `--gpu-memory-utilization 0.45`, it gets 4.5 GiB
  of KV (33k tokens).

Each service measured alone (`hosts/gpu-195/bench/voice-bench.py`, median of 5, warm):

| | |
|---|---|
| STT, 1.9 s utterance | 59 ms with whisper-fast (greedy, no timestamps, encoder window sized to the audio, 4 CPUs). faster-whisper-server took 250-300 ms (beam 5, timestamps, a fixed 30 s window). 5 s: 169 vs 264 ms; 7 s: 182 vs 350 ms; same transcripts. |
| TTS, first audio (streamed PCM) | 55 ms. A one-sentence WAV takes 48 ms. |
| LLM first token | 27 ms |
| LLM decode | 129 tok/s |

**VoiceAgent** (`voice-agent` :9000 and `voice-web` :4321, images built on the box from the repo, config in
`~/.config/voiceagent/voiceagent.env` plus `secrets.env` at mode 600):
- `VLLM_ENABLE_THINKING=false`: a Qwen3 think block would delay the first spoken word.
- Traefik on `.100`: `PowStation/config/traefik/dynamic/voiceagent.yml`.
  - `voiceagent.pow` goes to the web UI. `/ws` and `/transcribe` go straight to the backend.
  - Pi-hole already had `voiceagent.pow`.
  - Rewriting the file from inside the Colima VM (`colima ssh`) fires the file provider's watch, so Traefik was not
    restarted.
- Verified with a scripted WebSocket client. A Kokoro-made "Hey Luna, what time is it?" was streamed in real time and
  returned a transcript, LLM tokens (with a tool call) and TTS audio.
  - Wake word: after a `sleep`, plain speech got no reply, and "Hey Luna..." woke it and got one.
  - Barge-in: see below.

**Latency pass (2026-10-21, VoiceAgent branch `server-gpu195`):** end of speech -> first audio byte went from
**1.73 s to 0.67 s** median, measured direct and through Traefik.

All numbers are medians from `voice-bench.py ws`: 8-10 real-time turns over `/ws`, with Kokoro's leading and trailing
silence trimmed so "end of speech" is the last voiced sample. The 1.35 s reported before used untrimmed audio and read
about 0.3 s too good. The "before" stack was the old image and old STT server, run side by side on the same box.

| | before | after (direct) | after (via Traefik) |
|---|---|---|---|
| end of speech -> final transcript | 906 ms | 429 ms | 428 ms |
| end of speech -> first LLM token | 1595 ms | 532 ms | 526 ms |
| end of speech -> first audio byte | 1728 ms | 676 ms | 671 ms |

One turn from the backend log (after):

| step | time |
|---|---|
| VAD end, after 250 ms of silence plus Silero's decay | ~350 ms |
| STT | ~60-90 ms |
| commit and request | ~30 ms |
| LLM to the first sentence | ~90 ms |
| first TTS sentence (one WAV) | ~105 ms |

What changed:

1. **Adaptive end of speech** (`VAD_BASE_SILENCE_MS=250`; the cap is `VAD_MIN_SILENCE_MS=500`).
   - The turn is transcribed speculatively while still listening.
   - It commits at once unless the transcript looks unfinished: a trailing conjunction or filler, a comma or
     ellipsis, or a bare wake word. Then it waits out the cap.
   - Speech that resumes before the commit cancels the speculative turn and merges its audio.
   - While asleep, the cap is always waited.
2. **Speaker ID off the event loop.**
   - speechbrain ran synchronously inside a coroutine, which blocked everything for ~300 ms right before the LLM call.
   - It now runs in a worker thread, and the wake-word path no longer waits for it.
3. **LLM prefix cache.** The prompt was already streamed into TTS sentence by sentence, and the tool-call deltas
   arrive separately. The cost was elsewhere:
   - The few-shot examples interpolated `datetime.now()` (seconds) right after the system prompt.
   - So every request missed vLLM's prefix cache from there on, re-prefilling about 3k tokens plus the history.
   - Fixed example values took the first sentence from ~500 ms to ~90 ms after the request.
4. **STT.**
   - `WHISPER_STREAMING=false`: one plain request, with no server-side VAD pass and no SSE.
   - whisper-fast, as in the table above.
   - `--cpus=4`: with 2 CPUs the CPU side was throttled to ~190 ms.
5. **Barge-in bug.** After a spoken interrupt, the next turn was silent: `barge_in()` left `cancelled` set.
   - A new turn now clears it.
   - The interrupt also cancels the interrupted turn's task.

Behaviour checks (`voice-bench.py bargein|merge|wake`), all passing:
- **bargein:** speaking over the story's audio produces an `interrupt` ~325 ms later, and the new question gets
  answered ("2 plus 2 is 4.").
- **merge:** "Remind me to buy milk and" + a 380 ms pause + "eggs tomorrow." arrives as one turn.
- **wake:** asleep, plain speech gets no reply, and "Hey Luna..." does.
- **recall:** transcripts are still stored, and speaker ID still runs.

What's left: the first TTS chunk is one WAV per sentence (~105 ms). A streamed or clause-sized first chunk would save
~50 ms, but the web client decodes whole WAVs.

**Left for later:**
- The public `voiceagent.powback.com`. `/ws` has no auth of its own on the upgrade, so it can't take the Authelia
  WebSocket bypass, and behind forwardAuth it hangs. Decide this with the phase 5 clients.
- Phase 4 (router / `llm.pow`): the `litellm` provider is configured, but nothing answers.
- Phases 5-6.
