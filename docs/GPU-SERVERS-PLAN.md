# GPU servers: the plan (2026-10-21)

PowOS now has real GPU servers on the LAN. This is how inference (voice, LLMs, everything AI) is laid out across
them, how it's run and managed, and the order to build it in. Status: **phases 1-3 built on `.195` (2026-10-21), see
[Status](#status-2026-10-21); phase 4 done (2026-10-21): the GPU1 pool (`llm-gpu.pow`: general, vision, embed), the router
(`llm.pow`) and `.58`'s `coder-32b` are live and verified end to end; phases 5-6 not started. Request-idle voice
offload and the Flash Next dual-GPU lease were added 2026-10-26 (see the section at the end)**.

## What we have

| host | GPUs | role in this plan |
|---|---|---|
| `192.168.50.195` (new PowOS box, Bazzite 44 nvidia-open, 8 cores, 62 GB, 3.6 TB NVMe) | 2x RTX 3090 24 GB | **realtime + general inference**: GPU0 = voice while active; Flash Next can lease both cards after voice LLM idle-offload; other pool models use GPU1 |
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
3. **Voice takes GPU priority without cancelling active local sessions.**
   - GPU0 on `.195` is reserved for voice while its LLM is active. Flash Next may lease both 3090s after the voice LLM has been offloaded to RAM.
   - A Flash Next session using GPU1 only does not block voice from waking on GPU0. If Flash Next leased both cards, voice waits for that session and its normal TTL unload; other pool models remain on GPU1.
4. **Idle = no VRAM, near-zero power, fast wake.**
   - Big models load on first request (llama-swap with a TTL) and unload when idle.
   - The voice LLM stays in VRAM while requests arrive; after five idle minutes its weights move to host RAM and wake on demand.
5. **Images built from the repo, not bind-mounted from the Mac.** VoiceAgent's compose mounts `/Users/macback/...`.
   On the server it runs from images built from the repo (CI on the hub or `podman build` on the box) with config in
   env files.
6. **Private by default.**
   - `*.pow` on the LAN and VPN.
   - Public `*.powback.com` only behind Authelia (with the documented WebSocket bypasses).
   - Nothing calls out to cloud APIs except `claude-auth.pow`.

## Layout

### `.195` GPU0: realtime voice (resident while active, ~13-15 GB of 24)
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
- Ollama (:11434) stays for quick model trials, on the same GPU under the same VRAM gate. (Not deployed on `.195`
  yet: the pool covers the named models, and Ollama would need its own share of GPU1's budget.)
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
  `main` at `~/Projects/PowOS`, and everything else to the image's `/usr/bin/powos`.
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
`config/traefik/dynamic/stt.yml`; Pi-hole `dns.hosts`). Files and recordings from every PowOS (`powos transcribe`,
anything OpenAI-compatible) never queue a voice turn: GPU0 stays the voice path's alone, and the batch container gets
2 CPUs at cpu-shares 128. Settings: Silero VAD, timestamps on for audio over one 30 s window (without them
faster-whisper drops the words at window boundaries: 84% of a 12 min recording's words came back instead of ~100%),
500 MB uploads (413), 4 requests running or waiting (503; Traefik inFlightReq 4 -> 429), `stream=true` SSE.
Audio with no speech (silence, or a clip VAD empties) answers 200 `{"text": ""}`. It was a 500 until 2026-10-21,
because faster-whisper ran its language detection over an empty array, and the phone had to read the 500 as "nothing
heard". Clips under 2 s decode with timestamps (`WHISPER_SHORT_TIMESTAMPS_S=2`): without them a 0.5 s "Yes." came
back "Yes. Yes. Yes.". voice-stt has the same repetition on very short turns, but its setting stays off until it is
measured on the voice path.

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

**General LLM pool on GPU1** (2026-10-21, phase 4's "GPU1 llama-swap profiles"): unit `llm-pool`, one rootless
quadlet (`hosts/gpu-195/quadlets/llm-pool.container`) running llama-swap v265 on :9292. llama-swap starts `vllm serve`
per model as a child process on the first request and stops it after 10 idle minutes.
- The image `localhost/llm-pool` (`hosts/gpu-195/llm-pool/Containerfile`) is voice-llm's vLLM image, pinned by
  digest, plus the llama-swap release binary, pinned by version and sha256. Nothing is installed on the host.
- Config: `hosts/gpu-195/llm-pool/config.yaml` goes to `~/.config/llm-pool/`. The directory is mounted, not the file:
  `install` writes a new inode, which a file bind never sees. `-watch-config` reloads it, and a reload unloads
  whatever is running.
- Served as `http://llm-gpu.pow` by Traefik on `.100` (PowStation `config/traefik/dynamic/llm-gpu.yml`, 16 requests in
  flight per client IP; Pi-hole `dns.hosts`). LAN and VPN only, no auth, like stt.pow.
- Limits: 28g RAM, 3 CPUs at cpu-shares 256 (the voice units have 4 CPUs at the default 1024), pids 8192, GPU1 only.
  llama-swap answers 429 past 32 requests at once.

| model name | what | VRAM | status |
|---|---|---|---|
| `general` | `Qwen/Qwen3-14B-AWQ` (awq_marlin), 32k context, 32 seqs, hermes tool calls, thinking on (`reasoning_content` separate, `--reasoning-parser qwen3`) | 0.70 = 16.5 GiB (9.4 weights, 5.3 KV = 35k tokens) | verified |
| `general-nothink` | the same loaded model with `chat_template_kwargs.enable_thinking=false` (a llama-swap alias, no second load) | - | verified |
| `vision` | `Qwen/Qwen2.5-VL-7B-Instruct-AWQ`, 16k, up to 4 images | 0.70 (KV 138,832 tokens) | verified |
| `embed` | `BAAI/bge-m3` (`--runner pooling`), 8k | 0.10 = 2.4 GiB | verified |

The routing is a llama-swap matrix: `general & embed` or `vision & embed`, never general with vision. GPU1's
budget: stt-batch 2.4 + embed 2.4 + one big model 16.5 = 21.3 of 24 GiB. Measured with `general` loaded: GPU1 at
19.4 GiB. vLLM's `--gpu-memory-utilization` is a share of the whole card, checked against what is free when it
starts, which is why the shares have to add up with stt-batch's.

Measured with `hosts/gpu-195/bench/llm-bench.py` (stdlib only, run on the box):

| | |
|---|---|
| cold start `general` (load, compile, first answer) | 81 s the first time (36 s of it torch.compile); 39.5 s once the compile cache in `/var/lib/powos/models/vllm` is warm |
| first token, warm | 32 ms thinking off, 56 ms thinking on (median of 3; that's to the first reasoning token) |
| decode, one stream | **83 tok/s** |
| decode, 4 streams | **~297 tok/s** aggregate, 82 tok/s each |
| tool call (`get_weather`, thinking off) | returns `tool_calls` with `{"city": "Oslo"}`, 0.34 s |
| GPU1 during 4 streams | 100%, 280-308 W |
| cold start `embed` / `vision` | 47 s / 81 s |
| `embed`: 64 short texts | 122 ms (524 texts/s), 1024-d |
| `vision`: a generated red square | "The image shows a red square." (0.07 s warm); text decode 145 tok/s, first token 34 ms |
| `vision` + `embed` loaded together, plus stt-batch | GPU1 at 19.1 GiB of 24 |

Voice path (`voice-bench.py ws`, n=10, median end of speech -> first audio byte):

| | final transcript | first LLM token | first audio |
|---|---|---|---|
| before (no pool) | 409 ms | 498 ms | **640 ms** |
| pool running 4 streams on GPU1 the whole time | 421 ms | 517 ms | **665 ms** |
| after, pool installed and idle | 424 ms | 521 ms | **664 ms** (min 606) |

The ~25 ms between the first row and the others is the same with the pool idle, so it is variance between runs, not
the pool. Minimums: 610, 632 and 606 ms. No regression, and well under the 800 ms target. stt-batch kept answering `/health` throughout (stt.pow).

Noise: a 3090 under the pool's full load runs at 100%, ~300 W, with its fan near 100%. The cards are ASUS blowers
(subsystem 1043:87B3). The user stopped the load test because the box was loud.
- Idle, they still run their fans at 56-77% at P8 (GPU0 36 W at 58 °C, with the voice path and the desktop on it;
  GPU1 22 W at 50 °C). That is the vBIOS fan curve.
- 2026-11-03: they DO stop their fans when cool (0% at 46-50 C, both cards, steady for minutes). The noise is the
  vBIOS holding 53-77% for minutes after load ends, plus ~100% under load. NVML's settable range is 30-100%, so a
  fixed floor would be louder than the fan-stop.
- Fix (user asked "permanently", 2026-11-03): unit `gpu-fan`, `hosts/gpu-195/gpu-fan/` (README there). A root
  systemd service, NVML through ctypes (no packages): leaves the vBIOS fan-stop alone; takes over at >= 52 C or when
  the vBIOS spins > 15 points above its curve (30% at 50 C ... 100% at 83 C, fast up, 2%/tick down); hands back at
  <= 47 C; 250 W power cap per card (default 350). Every failure path returns the cards to the vBIOS curve and the
  default power limit. Install: `sudo bash hosts/gpu-195/gpu-fan/install.sh`.

**Router: `llm.pow`** (2026-10-21, phase 4). LiteLLM v1.106.2, pinned by digest. It runs as the PowStation compose
service `llm-router` on Colima: `config/litellm/config.yaml` plus a `docker-compose.yaml` block, Traefik labels,
the `local-only` allowlist, and a Pi-hole entry from pihole-sync. It needs no database, cache or volume, and its limits
are 2g RAM, 2 CPUs and 512 pids.
- Auth: newer LiteLLM refuses to start without a master key. The key is `LLM_ROUTER_MASTER_KEY` in PowStation's
  `.env` (gitignored), and clients send it as `Authorization: Bearer <key>`. A request without it gets 401.
- Model names:
  - `voice-fast` goes to `.195:8100` (GPU0), for clients other than the voice path. The router lets at most 2
    requests through at once, so they can't crowd out live voice turns. VoiceAgent itself stays direct on
    `voice-llm` (`VLLM_URL=http://voice-llm:8000`): no router hop on the latency-critical path (decided
    2026-10-21). Its `litellm` provider stays unused.
  - `general`, `general-nothink`, `vision` and `embed` go to `.195:9292`.
  - `coder-32b` goes to `.58:9292` (`qwen-32b-vllm`), with a fallback to `general`.
  - `anthropic/*` and `claude-haiku|sonnet|opus` go to `claude-auth.pow`.
  - `.58`'s `powos/*`, `powos-vllm/*` and `powos-anthropic/*` wildcards stay as before.
- Carried over from local-llm-stack's old Mac-side LiteLLM (:4000, not running since 2026-08), each with its reason
  in the config: no local -> Claude fallback, the `api.anthropic.com` blackhole, `thinking` dropped on the local
  routes, and the Anthropic /v1/messages chat-completions path.
- Verified (2026-10-21): `/v1/models` lists every name; a request without the key gets 401.
  - `claude-haiku` answers through `claude-auth.pow`, and nothing reached `api.anthropic.com`.
  - `general` cold-loaded through the router in 39 s. Thinking on and off both answer; `general-nothink` made a
    correct `get_weather` tool call, and `voice-fast` answers.
  - Fallback: with `.58`'s llama-swap stopped, `coder-32b` was answered by `general` (`x-litellm-attempted-fallbacks:
    1`, 4.2 s).

**`.58` `coder-32b`** (2026-10-21; local-llm-stack branch `gpu-plan-coder-32b`, `powos/run-vllm-32b.sh`, checked out
on `.58`; unit `llama-swap-58`, `units/gpu-58/`, registered on the box with the repo's `powos-units`, since `.58`'s
PowOS image has no units tool). The fast path had never served a request:
- its HF cache on `.58` was empty;
- the comment inside the backslash continuation cut `--max-model-len 65536 --port 8000` off the command;
- with no `--served-model-name`, llama-swap's `qwen-32b-vllm` would have got a 404;
- 64k context didn't fit in 0.78 of the 5090.

The fix:
- served names `qwen-32b-vllm` and `coder-32b`;
- YaRN x2 through `--hf-overrides rope_parameters`, because the image has transformers 5;
- an fp8 KV cache, 128 KB a token;
- utilization 0.92 and 8 sequences;
- hermes tool calls;
- a VRAM gate of 30000 MiB.

The model is now **Qwen3-32B-AWQ**. Qwen2.5-Coder-32B-AWQ loaded and handled 64k, but it writes its tool calls as
`<tools>{...}</tools>` (or bare JSON) in the text, which vLLM's hermes parser doesn't pick up: 0 of 3 came back as
`tool_calls`. That's useless to agents. Qwen3 gets 3 of 3. The router adds `coder-32b-nothink` (thinking off, falls
back to `general-nothink`). Qwen3-32B-AWQ (19 GB) was pre-downloaded into the `vllm-hf-cache` volume; the
Qwen2.5-Coder download was deleted from it.

Measured through `llm.pow` (warm unless noted):

| | Qwen3-32B-AWQ |
|---|---|
| cold start (load, compile, first answer) | 75 s (Qwen2.5-Coder: 71 s) |
| KV cache | 73,488 tokens (fp8), so a 64k request fits; 30.4 GiB of 32 used |
| decode, one stream | 76-79 tok/s; first token 44-249 ms |
| tool calls (thinking off) | 3 of 3 parsed into `tool_calls` |
| 53.5k-token prompt, a code word at the very start | recalled correctly, 32.6 s |

**Left for later:**
- The public `voiceagent.powback.com`. `/ws` has no auth of its own on the upgrade, so it can't take the Authelia
  WebSocket bypass, and behind forwardAuth it hangs. Decide this with the phase 5 clients.
- Ollama on `.195` GPU1 (not deployed; the pool covers the named models).

**Router: `llm.pow`** (2026-10-21, phase 4). LiteLLM v1.106.2, pinned by digest. It runs as the PowStation compose
service `llm-router` on Colima: `config/litellm/config.yaml` plus a `docker-compose.yaml` block, Traefik labels,
the `local-only` allowlist, and a Pi-hole entry from pihole-sync. It needs no database, cache or volume, and its limits
are 2g RAM, 2 CPUs and 512 pids.
- Auth: newer LiteLLM refuses to start without a master key. The key is `LLM_ROUTER_MASTER_KEY` in PowStation's
  `.env` (gitignored), and clients send it as `Authorization: Bearer <key>`. A request without it gets 401.
- Model names:
  - `voice-fast` goes to `.195:8100` (GPU0). The router lets at most 2 requests through at once, so other clients
    can't crowd out live voice turns.
  - `general`, `general-nothink`, `vision` and `embed` go to `.195:9292`.
  - `coder-32b` goes to `.58:9292` (`qwen-32b-vllm`), with a fallback to `general`.
  - `anthropic/*` and `claude-haiku|sonnet|opus` go to `claude-auth.pow`.
  - `.58`'s `powos/*`, `powos-vllm/*` and `powos-anthropic/*` wildcards stay as before.
- Carried over from local-llm-stack's old Mac-side LiteLLM (:4000, not running since 2026-08), each with its reason
  in the config: no local -> Claude fallback, the `api.anthropic.com` blackhole, `thinking` dropped on the local
  routes, and the Anthropic /v1/messages chat-completions path.
- Verified (2026-10-21): `/v1/models` lists every name; a request without the key gets 401.
  - `claude-haiku` answers through `claude-auth.pow`, and nothing reached `api.anthropic.com`.
  - `general` cold-loaded through the router in 39 s. Thinking on and off both answer; `general-nothink` made a
    correct `get_weather` tool call, and `voice-fast` answers.
  - Fallback: with `.58`'s llama-swap stopped, `coder-32b` was answered by `general` (`x-litellm-attempted-fallbacks:
    1`, 4.2 s).

**`.58` `coder-32b`** (2026-10-21; local-llm-stack branch `gpu-plan-coder-32b`, `powos/run-vllm-32b.sh`, checked out
on `.58`; unit `llama-swap-58`, `units/gpu-58/`, registered on the box with the repo's `powos-units`, since `.58`'s
PowOS image has no units tool). The fast path had never served a request:
- its HF cache on `.58` was empty;
- the comment inside the backslash continuation cut `--max-model-len 65536 --port 8000` off the command;
- with no `--served-model-name`, llama-swap's `qwen-32b-vllm` would have got a 404;
- 64k context didn't fit in 0.78 of the 5090.

The fix:
- served names `qwen-32b-vllm` and `coder-32b`;
- YaRN x2 through `--hf-overrides rope_parameters`, because the image has transformers 5;
- an fp8 KV cache, 128 KB a token;
- utilization 0.92 and 8 sequences;
- hermes tool calls;
- a VRAM gate of 30000 MiB.

The model is now **Qwen3-32B-AWQ**. Qwen2.5-Coder-32B-AWQ loaded and handled 64k, but it writes its tool calls as
`<tools>{...}</tools>` (or bare JSON) in the text, which vLLM's hermes parser doesn't pick up: 0 of 3 came back as
`tool_calls`. That's useless to agents. Qwen3 gets 3 of 3. The router adds `coder-32b-nothink` (thinking off, falls
back to `general-nothink`). Both models were pre-downloaded into the `vllm-hf-cache` volume; Qwen2.5-Coder's ~19 GB is
unused now and can be dropped.

Measured through `llm.pow` (warm unless noted):

| | Qwen3-32B-AWQ |
|---|---|
| cold start (load, compile, first answer) | 75 s (Qwen2.5-Coder: 71 s) |
| KV cache | 73,488 tokens (fp8), so a 64k request fits; 30.4 GiB of 32 used |
| decode, one stream | 76-79 tok/s; first token 44-249 ms |
| tool calls (thinking off) | 3 of 3 parsed into `tool_calls` |
| 53.5k-token prompt, a code word at the very start | recalled correctly, 32.6 s |

**Left for later:**
- The public `voiceagent.powback.com`. `/ws` has no auth of its own on the upgrade, so it can't take the Authelia
  WebSocket bypass, and behind forwardAuth it hangs. Decide this with the phase 5 clients.
- Phase 4 still to do:
  - Load and measure `vision` and `embed`.
  - Point VoiceAgent's `litellm` provider at `http://llm.pow` with the router key, if it should use it.
  - Ollama on `.195` GPU1 (not deployed).

**Router: `llm.pow`** (2026-10-21, phase 4). LiteLLM v1.106.2, pinned by digest. It runs as the PowStation compose
service `llm-router` on Colima: `config/litellm/config.yaml` plus a `docker-compose.yaml` block, Traefik labels,
the `local-only` allowlist, and a Pi-hole entry from pihole-sync. It needs no database, cache or volume, and its limits
are 2g RAM, 2 CPUs and 512 pids.
- Auth: newer LiteLLM refuses to start without a master key. The key is `LLM_ROUTER_MASTER_KEY` in PowStation's
  `.env` (gitignored), and clients send it as `Authorization: Bearer <key>`. A request without it gets 401.
- Model names:
  - `voice-fast` goes to `.195:8100` (GPU0). The router lets at most 2 requests through at once, so other clients
    can't crowd out live voice turns.
  - `general`, `general-nothink`, `vision` and `embed` go to `.195:9292`.
  - `coder-32b` goes to `.58:9292` (`qwen-32b-vllm`), with a fallback to `general`.
  - `anthropic/*` and `claude-haiku|sonnet|opus` go to `claude-auth.pow`.
  - `.58`'s `powos/*`, `powos-vllm/*` and `powos-anthropic/*` wildcards stay as before.
- Carried over from local-llm-stack's old Mac-side LiteLLM (:4000, not running since 2026-08), each with its reason
  in the config: no local -> Claude fallback, the `api.anthropic.com` blackhole, `thinking` dropped on the local
  routes, and the Anthropic /v1/messages chat-completions path.
- Verified: `/v1/models` lists every name; `claude-haiku` answers `pong` through `claude-auth.pow`; nothing reached
  `api.anthropic.com`. The local models through the router are not checked yet, because a request would load one.

**`.58` `coder-32b`** (local-llm-stack branch `gpu-plan-coder-32b`, `powos/run-vllm-32b.sh`; not deployed). The
Qwen2.5-Coder-32B-AWQ fast path had never served a request:
- its HF cache on `.58` is empty;
- the comment inside the backslash continuation cut `--max-model-len 65536 --port 8000` off the command;
- with no `--served-model-name`, llama-swap's `qwen-32b-vllm` would have got a 404;
- 64k context doesn't fit in 0.78 of the 5090.

The fix:
- served names `qwen-32b-vllm` and `coder-32b`;
- YaRN x2 through `--hf-overrides rope_parameters`, because the image has transformers 5;
- an fp8 KV cache, 128 KB a token;
- utilization 0.92 and 8 sequences, which should leave about 8 GiB, about 65k tokens of KV;
- hermes tool calls;
- a VRAM gate of 30000 MiB.

Checked with a stub podman: every argument reaches vLLM. Loading the model is the next check.

**Left for later:**
- The public `voiceagent.powback.com`. `/ws` has no auth of its own on the upgrade, so it can't take the Authelia
  WebSocket bypass, and behind forwardAuth it hangs. Decide this with the phase 5 clients.
- Phase 4 still to do (each needs a model load, which waits for the user's go-ahead because of fan noise):
  - Load and measure `vision` and `embed` (configured; the load test stopped before them).
  - Check `general`/`coder-32b` end to end through `llm.pow`, and the `coder-32b` -> `general` fallback.
  - Deploy `.58`'s fixed script (branch `gpu-plan-coder-32b`) and download the model first (~19 GB; llama-swap's
    600 s health timeout would cut a first-start download short), then one load to confirm 64k fits.
  - Point VoiceAgent's `litellm` provider at `http://llm.pow` with the router key, if it should use it.
  - `.58`'s llama-swap (a `systemd --user` service from local-llm-stack) has no PowOS unit yet.
- Phases 5-6.


### Shared local queue, interrupts and conversation cache — 26 October 2026

The Claude authority now gives local GPU-pool requests a separate admission
queue: one active generation, round-robin between session IDs and FIFO within
each session. Flash aliases share that lane; the other general-pool models and
the coder fallback share it too. Voice-fast/embedding have separate lanes, and
cloud subscription queues are unchanged. This is request fairness, not time/token
fairness: a long active generation runs until completion or cancellation.
Direct calls to LiteLLM or llama-swap bypass authority admission.

Up to 32 requests / 64 MiB of request bodies wait per lane, for at most 240
seconds. Streaming callers get SSE pings while waiting. Queue overflow/deadline
errors remain possible; this is not an unbounded backlog. A busy backend rejection
is retried for up to 30 seconds to cover cancellation cleanup. Generation that
has already emitted output is never retried by this queue.

Cancelling a queued HTTP request removes it before inference. Cancelling active
work closes its upstream request and response, propagating through LiteLLM to
Strata without killing the shared engine. In the live probe, the queue fell from
two waiting requests to one after cancellation; after interrupting the active
stream, the next request returned `INTERRUPT-OK` in **0.346 seconds**. Strata
logged `disconnect, cancel=True`. This tests HTTP cancellation, not a particular
terminal key binding, and does not undo shell commands or file edits.

Flash Next's conversation cache is now explicitly bounded to **4096 MiB / four
parked entries**, with a 3072 MiB free-memory floor under the 49152 MiB container
limit. It skips prompts shorter than 2048 tokens and uses a 2048-token growth
threshold to reduce repeated snapshot copying. Matching token prefixes and
steering modes are required for reuse. The four-entry ceiling does not promise
four full 128k histories; large snapshots compete for the byte budget and evict
older ones. Restarting/swapping the model loses KV state, not the client's saved
conversation. The engine log now supplies park/restore counters; the previous
zero counters did not establish that caching was disabled.

A → unrelated B → A follow-up succeeded amid live traffic. The A follow-up
reused **13,839 tokens**, read **19 new tokens**, and returned the correct marker.
The engine recorded **83.8 ms** to restore its snapshot and **667 ms** for the
remaining prompt processing, against **10,064 ms** to read A's original prompt.
Client wall times include waits behind other sessions and are not speed scores.
The same log showed other live histories restoring tens of thousands of tokens.

Two inference slots were also tested, with local admission briefly held while
active work drained. The hold is container-loopback-only and automatically
expires after 180 seconds; the original config and admission were restored.
Two rounds each, with two concurrent short coding prompts capped at 256 output
tokens per request, produced:

| Configuration | Combined output tokens / wall second, median |
|---|---:|
| Single slot, deployed MTP configuration | 93.59 |
| Two slots, batch MTP, 768 MiB VRAM reserve | 50.93 |

The two-slot candidate was **45.6% slower**, and reserved another 1.46 GiB of GPU
session state plus two 50 MiB private draft states. This is a small configuration
comparison, including prompt time, not a quality benchmark or a controlled
estimate of slot count alone. **Single-slot serving remains deployed.** No
multi-GPU changes were made.

Validation: 15 automated routing/queue/transport checks passed, including fairness,
queue limits, timeout, cancellation, SSE errors, upstream truncation, and automatic
maintenance expiry. The public maintenance endpoint refused access with 403.
Live session/interrupt evidence and both slot profiles are saved in
[local-session-trial-20261026.json](../hosts/gpu-195/bench/local-session-trial-20261026.json).
Probes: [local-session-trial.py](../hosts/gpu-195/bench/local-session-trial.py) and
[strata-slots-trial.py](../hosts/gpu-195/bench/strata-slots-trial.py).
See also [Strata batching documentation](https://github.com/Niko1221/Strata/blob/main/docs/BATCHING.md).

### Flash Next context-window fix — 26 October 2026

The coding trials below used 32k context. Interactive PowFrame use exposed an
integration problem: its initial Claude Code request already used about 15,249
tokens for instructions/tools and the greeting. Claude Code 2.1.310 reserves
4,096 output tokens and another 13,000 for compaction, so a 32,768-token window
starts compacting at approximately **15,672 tokens**. Raising the compaction
percentage cannot remove that fixed buffer in this version.

All four Flash Next aliases now use **131,072 tokens**, on both Strata and
`claude-local`. The engine keeps int8 KV with `--kv-resident 32768`: the larger
cache is backed by host RAM. GPU1 remains the only inference GPU; speech stays
running. The usual compaction threshold becomes approximately **113,976 tokens**.
Other model profiles remain at their previously tested 32k limits, including the
coder-to-general fallback chain. Restart Claude Code through the launcher to
pick up the new window; existing processes retain their startup environment.

Validation with `flash-next-huihui`, thinking enabled, in PowFrame:

- Engine startup and Claude Code both reported 131,072 context tokens.
- A 72,449-token synthetic log prompt returned all three embedded checkpoints
  correctly in 45.09 seconds including CLI overhead.
- A resumed follow-up returned the same three checkpoints in 1.56 seconds;
  usage reported 72,512 cached input tokens plus 33 fresh tokens.
- Neither turn compacted. Debug logs reported `level=ok effectiveWindow=126976`.
- The launcher/routing suite passed all six checks. All five speech units stayed
  active; pool memory during the longer prompt was about 41.17 GB of its 51.54 GB
  limit. GPU1 used about 23,813 MiB, with 365 MiB free in that sample.

This checks serving capacity and simple recall at 72k, not accuracy at the full
128k limit or an updated speed ranking. The prior 32k coding benchmark numbers
remain historical measurements. Huihui is the currently selected profile: it
passed both short coding tasks fastest, but those runs do not establish a broad
quality advantage over the plain profile.

Evidence: [context-trial-20261026.json](../hosts/gpu-195/bench/context-trial-20261026.json).
Reusable probe: [claude-context-trial.py](../hosts/gpu-195/bench/claude-context-trial.py).
See [Claude Code custom-model context configuration](https://code.claude.com/docs/en/model-config#correct-the-window-for-a-gateway-or-custom-model-id)
and [Strata KV memory modes](https://github.com/Niko1221/Strata/blob/main/docs/DETAILS.md).

### Consolidated benchmark overview 25 and 26 October 2026

**Fastest successful candidate in these trials: `flash-next-huihui-nothink`.**
The plain Flash Next variant also passed both coding tasks. Both completed them in tens of seconds,
with normal speech services running. Nanbeige and GLM can produce correct code,
but took minutes on these tasks. This selects a candidate for a real `nofate/br`
trial; two small Python exercises do not establish reverse-engineering ability
or a broad model-quality ranking.

#### Hardware and method

- Host: `.195`, i7-7700K, four physical cores/eight threads, 62 GiB usable RAM,
  WD_BLACK AN1500 NVMe storage, two 24 GB RTX 3090s connected by NVLink.
- Every inference trial used **GPU1 only**. GPU1 negotiated PCIe 3.0 x8 under
  load. GPU0 served voice until the explicitly authorized GLM speech pause.
- `.58` and its 32 GB RTX 5090 were unreachable by SSH. No multi-GPU trial ran.
- Claude Code 2.1.310; 32k context and 4k output per request. The current two
  tasks repair interval merging and an LRU cache, using Read/Edit/Write/Bash
  and external assertions kept outside its working directory. Each newer case has a
  600-second wall deadline and requires a clean CLI completion as well as
  passing assertions. These are single runs with each profile's sampling.
- The interval prompt explicitly requires a **list of tuples** and distinguishes
  shared endpoints from adjacent integers. An earlier ambiguous Huihui failure
  is excluded. Raw earlier runs remain in the JSON for traceability.
- New speed results are medians of three warm 128-token streams. The long-input
  test uses 10,315 characters of synthetic logs. Its latency includes reading
  the prompt; cached short-prompt latency is a different measurement.

#### Current coding harness results

| Profile | Quantization | Decode median | Interval task | Cache task |
|---|---|---:|---|---|
| general-nothink | Qwen3-14B AWQ | 82.42 tok/s | Fail, 23.05 s | Fail, 32.49 s |
| flash-next-nothink | Flash Next IQ2_XS, Strata | 67.87 tok/s | Pass, 29.15 s | Pass, 25.42 s |
| flash-next-huihui-nothink | Same weights plus Huihui projection | 75.59 tok/s | Pass, 24.51 s | Pass, 20.56 s |
| nanbeige-33b-nothink | Nanbeige4.3-33B Q4_K_S, Q4 KV | 37.23 tok/s | Timeout, 600 s | Pass, 191.53 s |
| nanbeige-33b | Same weights, thinking enabled | Not separately measured | Pass, 258.32 s retest | Not rerun in this mode |
| GLM-5.3-Flash | Maya-S24, corrected expert profile | 6.73 tok/s, thinking-off speed probe | Pass, 596.03 s, thinking enabled | Pass, 498.32 s, thinking enabled |

GLM used its native Anthropic endpoint through an SSH tunnel, with speech
services temporarily stopped and a 46 GiB pinned expert cache. The other rows
used the production Claude authority → LiteLLM → llama-swap route with speech
running. Claude Code enabled thinking on GLM despite the server's fallback
setting; the trace, not the zero-valued aggregate thinking-token counter,
identifies the mode. These differences prevent treating the table as a
controlled accuracy leaderboard. Huihui's faster single run does not establish
that its projection improves coding quality.

| Profile | Short-prompt TTFT median | Longer-input TTFT |
|---|---:|---:|
| general-nothink | 25.7 ms | 1.81 s |
| flash-next-nothink | 213.5 ms | 4.10 s |
| flash-next-huihui-nothink | 203.0 ms | 4.06 s |
| nanbeige-33b-nothink | 38.4 ms | 3.92 s |
| Corrected GLM with speech paused | 381.6 ms | 16.79 s |

Flash Next's measured pool cold start plus a small answer was 36.94 s;
Nanbeige's was 12.46 s. GLM's first API request happened after engine startup,
so its `first_request_seconds` is **not** a cold-load measurement.

#### Earlier 27B trials

These used earlier prompts, tool selections or deadlines and are kept separate
from the current paired comparison. Their token speeds are single warm samples.

| Profile | Decode | Observed agent outcome |
|---|---:|---|
| Swift 1.5 Qwen3.8-27B W4A16, non-thinking | 13.65 tok/s | File tools only: intervals pass 44.34 s; cache pass 41.36 s |
| Swift 1.5 with thinking | Not separately measured | File tools only: intervals fail 108.03 s; cache pass 57.39 s |
| Ternary Bonsai 2 27B PQ2_0, non-thinking | 66.93 tok/s | With Bash: intervals timeout 240 s; cache pass 56.62 s. File-only run instead passed intervals 68.35 s and timed out on cache |

Bonsai's compact weights did not make it the most reliable coding agent in these
runs. The publisher's aggregate retention percentage is not a measurement of
this harness. Swift's file-only successes warrant a future comparable trial,
not an automatic claim that it outperforms the current Bash-enabled profiles.

#### What the Maya investigation changed

The first launcher omitted the bundled expert profile. Corrected serving passes
`--expert-profile /opt/maya/data/expert-profile-glm.bin`, matching upstream setup.
The profile ranks experts for initial placement and assigns GPU slots per layer.
The pack also has to sit inside the GGUF shard directory because its references
are relative. Both fixes are in `hosts/gpu-195/maya-bench/launch.py`.

Before correcting the profile, the voice-running 36 GiB cache diagnostic gave
4.04 tok/s. A 42 GiB cache loaded successfully beside voice but was not timed.
Pausing speech allowed 46 GiB and a larger GPU expert pool; the corrected final
result was 6.73 tok/s. The earlier numbers are diagnostics, not a fair estimate
of correctly configured Maya or an isolated measurement of the effect of RAM.
Disk waits and PCIe transfers remain substantial. CPU quota throttling was
negligible, so the CPU cap stayed at four logical CPUs with low scheduling weight.

The investigation followed the [Maya tuning guide](https://github.com/mw00/project-maya/blob/main/docs/SETTINGS.md)
and a [24 GB GPU / 64 GB RAM report](https://github.com/mw00/project-maya/issues/274).
The latter uses a much newer CPU/GPU and a mostly free machine. Its published
throughput is not an expectation for this host while it serves other workloads.

#### Availability and routing

Run the selected candidate with:

```sh
/Users/macback/Projects/claude-rate-limiter/bin/claude-local flash-next-nothink
# Same checkpoint with the optional refusal-direction projection:
/Users/macback/Projects/claude-rate-limiter/bin/claude-local flash-next-huihui-nothink
# Nanbeige's thinking-enabled profile:
/Users/macback/Projects/claude-rate-limiter/bin/claude-local nanbeige-33b
```

The launcher sets the main, background and subagent model variables, points
Claude Code at `http://claude-auth.pow`, and uses the local-only credential.
Model aliases choose the host: these profiles route to `.195:9292`; `coder-32b`
routes to `.58` with a general-model fallback on `.195`. There is no least-busy
host scheduler and no local-to-cloud fallback. The launcher default is still
`general-nothink`; the new profiles are opt-in. GLM remains an experimental
loopback-only benchmark unit, not a production `claude-local` alias.

The rest of the requested list has **not** received a local benchmark: non-Flash
GLM-5.3, DeepSeek V4.1 Flash 1017 variants, the separate Qwen3.8-27B abliteration
variants including Defiance/Heretic, Venice Uncensored 1.2 and Gemma 4 Venice.
Flash Next's tested Huihui option is a runtime projection of the same checkpoint,
not a separately trained checkpoint. Defiance was inspected, not downloaded and
benchmarked. No result should be inferred for those untested variants.

#### Final service state and evidence

Speech and the normal pool were restored. The authority health endpoint returned
200; LiteLLM was healthy; stt-batch health passed; five real voice WebSocket turns
completed with first-audio median **689.7 ms** after restoration. Earlier ten-turn
medians were 636.5 ms before and 639.5 ms during the Flash Next test. The restored
five-turn sample includes a cold first turn; the raw measurements are retained.
Flash Next and Nanbeige also passed stt-batch transcription coexistence checks.

The pool was idle with no model loaded, both benchmark units were stopped, the
Maya unit's 36 GiB default was restored, and the temporary tunnel/local key were
removed. No idle voice-offload or multi-GPU policy was installed.

- Current results and complete run metadata: [larger-model-trial-20261025.json](../hosts/gpu-195/bench/larger-model-trial-20261025.json).
- Earlier trials: [model-trial-20261025.json](../hosts/gpu-195/bench/model-trial-20261025.json).
- Harness: [claude-code-trial.py](../hosts/gpu-195/bench/claude-code-trial.py).
- Streaming speed probe: [model-speed-trial.py](../hosts/gpu-195/bench/model-speed-trial.py).
- Exact model revisions, runtime pins, deployment details and earlier evidence follow below.

### Local Claude Code model trials — 2026-10-25

The Claude authority now sends named local models to the shared LiteLLM router.
`claude-rate-limiter/bin/claude-local` pins main/background models and uses the
`local-only` token, which rejects cloud model requests. The default remains
`general-nothink`. `.58:9292` timed out during these checks.

Swift 1.5 Qwen3.8-27B W4A16 is available as `swift-27b` and
`swift-27b-nothink` on .195 GPU1, via the existing llama-swap pool. Model revision
`9dba8a05877150d587215a519ce6befec3c9978a`; vLLM 0.32.0, text only,
32k context, one sequence, utilization 0.86, eager mode, TTL 300 s. Its matrix
set excludes all other pool models; stt-batch stays resident. Startup reported
16.83 GiB of weights and 41,642 tokens of KV capacity. First cold start took
about 110 s; a warm 128-token sample measured 13.65 decode tokens/s and 335 ms
to first token. GPU1 total used memory was about 23,555 MiB with stt-batch.

LiteLLM drops client reasoning effort and sets Swift's thinking profile to
`medium`: its template accepts low/medium/xhigh and rejects Claude Code's high.
The nothink profile disables thinking. Background requests use the same model's
nothink alias, preventing repeated swaps back to general.

`hosts/gpu-195/bench/claude-code-trial.py` runs two small file-edit tasks through
Claude Code with isolated configuration and Read/Edit/Write tools. External
Python assertions check generator/range handling and an LRU cache. This is a
single-run compatibility/correctness smoke test, not a repository benchmark.
The first interval wording was ambiguous about adjacent integers and was
excluded; the recorded reruns explicitly define shared endpoints.

| Profile | Interval assertions | Cache assertions | Task seconds |
|---|---|---|---|
| general-nothink (Qwen3-14B AWQ) | fail | fail | 56.54 (cold), 9.55 |
| swift-27b-nothink | pass | pass | 44.34, 41.36 (warm) |
| swift-27b (medium) | fail | pass | 108.03, 57.39 (warm) |

Swift medium still merged (1,2) with (3,4), contradicting the explicit example.
The 14B run mishandled generators and broke the cache constructor. Do not use
these two tasks to infer a broad model ranking. Voice first-audio median over
10 turns was 693.0 ms before, 629.3 ms with Swift resident and during its coding
trial; stt-batch health remained OK.

Publisher evidence: https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-27b
reports matched BF16 results, not this AWQ/32k setup. Its coding gains are a
reason to trial the model, not measured gains on our hardware.


Bonsai 2 follow-up (same date): `bonsai-27b` / `bonsai-27b-nothink` use
PrismML's PQ2_0 GGUF at revision `b072e1d3b35a0a630cece372c2127528e0994386`
(about 7.2 GB on disk, chosen for prompt speed instead of the 5.9 GB PTQ1_0
packing). The pool image includes the SHA256-verified CUDA 13.3 archive from
`PrismML-Eng/llama.cpp`, release `prism-b10826-c9c34bc`. The existing CUDA 13
runtime supplies its user-space libraries; CDI injects the host driver at run
time. The previous pool image is retained as `localhost/llm-pool:pre-bonsai-20261025`.
The model uses text-only 32k context, one slot, full GPU offload, flash attention,
medium reasoning (or disabled on the nothink alias), publisher sampling settings,
and a 300 s TTL. Its matrix set is exclusive within the pool.

First load plus a two-token reply took about 3.5 s. GPU1 used 11,681 MiB total,
including stt-batch: roughly 9 GiB incremental for the model, runtime and 32k KV.
Coding runs generated approximately 55–64 tokens/s. Voice first-audio median was
621.8 ms over ten turns during this trial, compared with 693.0 ms before the
model trials. No voice containers were restarted.

Bonsai nothink passed the interval assertions in 68.35 s with file tools, but
looped on the cache task until the 240 s limit. A separate run with `--shell`
exposes Bash and asks the model to run Python tests. It also timed out on the
interval task after repeated Bash calls and self-written tests that contradicted
the requested behavior. This is evidence of a problem in these trials, not an
estimate of a general success rate. The runtime's /apply-template confirmed
that enable_thinking=false closes the thinking block, so the alias does disable
reasoning. Both profiles remain opt-in; general-nothink is unchanged.

The publisher's 98.2% headline is a 20-benchmark aggregate and excludes separate
coding-agent evaluations: Terminal-Bench 2.1 is 52.8 vs 69.7 for Qwen3.8-27B,
and SWE-bench Verified is 60.8 vs 80.6. Source (section 4 / appendix B):
https://github.com/PrismML-Eng/Bonsai-demo/blob/main/bonsai-2-27b-whitepaper.pdf
The publisher also documents tool-call loops:
https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/blob/main/KNOWN_ISSUES.md

To reproduce a coding smoke test from the Mac:
`python3 hosts/gpu-195/bench/claude-code-trial.py bonsai-27b-nothink ~/Projects/claude-rate-limiter/bin/claude-local --shell`
The runner saves a live JSONL trace, final CLI result, generated files and external
assertion output in a temporary directory. Each case has a 240-second deadline;
a timeout is a failed agent run even if its partially written code happens to pass.

Bonsai's Bash-enabled cache task passed the independent assertions in 56.62 s
(seven turns). The Bash-enabled interval case timed out at 240 s. Machine-readable
results are in `hosts/gpu-195/bench/model-trial-20261025.json`.

A separate warm Bonsai 128-token streaming sample measured 66.93 decode tokens/s,
766 ms to first token, and 2.66 s total. Thinking mode also completed a tool
round-trip through the Anthropic-compatible proxy: multiply(17,23), tool result
391, then a correct final answer. This confirms protocol compatibility, not coding
reliability.

Weight prefetch (inside the pool container, before the first request):
```sh
podman exec -e HF_HUB_OFFLINE=0 llm-pool python3 -c 'from huggingface_hub import hf_hub_download; hf_hub_download(repo_id="prism-ml/Ternary-Bonsai-2-27B-gguf", filename="Ternary-Bonsai-2-27B-PQ2_0.gguf", revision="b072e1d3b35a0a630cece372c2127528e0994386")'
podman exec -e HF_HUB_OFFLINE=0 llm-pool python3 -c 'from huggingface_hub import snapshot_download; snapshot_download(repo_id="ukisai/Swift-1.5-Qwen3.8-27b-W4A16-AWQ", revision="9dba8a05877150d587215a519ce6befec3c9978a")'
```
Normal serving remains offline. Rebuilding only the pool and restarting only
`llm-pool.service` leaves the voice services running.

Post-image-change regression check: general-nothink loaded and answered in
38.59 s, then measured 82.79 decode tokens/s and 60 ms to first token for a warm
128-token stream. The added llama.cpp runtime did not break the existing vLLM
profile. The pool was unloaded after testing.

### Larger offloaded models, 2026-10-25

File size alone was too restrictive a filter. Strata keeps Qwen3.8 Flash Next's
experts in host RAM, caches hot experts on GPU1, and reads its n-gram table from
the NVMe. The tested machine is an i7-7700K (4 cores/8 threads), 62 GiB usable
RAM and one available 24 GiB RTX 3090; GPU0 remains assigned to voice. .58 was
unreachable during this trial.

Installed opt-in profiles: `flash-next`, `flash-next-nothink`,
`flash-next-huihui`, `flash-next-huihui-nothink`. All use the same engine and
weights, exclusive within the pool; Huihui enables a per-request projection,
not a separately fine-tuned checkpoint. The launcher pins background requests
to the selected variant's thinking-off alias. Routes go through the existing
Claude authority and LiteLLM to .195:9292. No fallback or default change.

- Weights: ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF, IQ2_XS,
  revision `ed59f92082b1e93c0e96d60a8b11aab089b52f09`.
- Engine: Strata 0.1.48 from container release 0.2.3, pinned digest in the
  pool Containerfile. The engine and its private Python runtime are copied into
  the pool image; no host Python packages are installed.
- Huihui vector: alesha-pro/Qwen3.8-Flash-Next-abliterated-GSQ-RCO-Strata-GGUF,
  revision `d4af3be5701549435e0770d625f79dd2def1358f`, SHA256
  `59f9ae8b4372107ae79044278a4406bdfe8f8861fe599aa5848515f0d072be38`.
  Projection uses layers 4–44, strength 1.0, with explicit off/on request filters.
- Prepared files live at `/var/lib/powos/models/strata`, mounted as `/data`.
  `flash-next.json` is a separate, credential-free runtime config installed with
  the pool YAML. A clean host must prepare the pinned weights and draft layer
  before selecting this profile; normal serving does not download them.
- The pool's host RAM cap is now 48 GiB and its CPU cap four logical CPUs at low
  shares (256). Flash Next measured about 39.4 GB container memory and 23,839 MiB
  total GPU1 usage including stt-batch. Idle TTL is five minutes.

Two small Claude Code tasks use Read/Edit/Write/Bash and independent assertions,
32k context, 4k output limit and a 600-second case deadline. Both standard and
Huihui thinking-off profiles passed through the production proxy. The interval
prompt was clarified to explicitly require a **list of tuples** after an earlier
Huihui answer returned a tuple: that earlier failure is not counted against it.
These are smoke tests with profile defaults, not a broad or deterministic coding
ranking. Raw results, revisions and earlier runs are retained in
`hosts/gpu-195/bench/larger-model-trial-20261025.json`.

| Profile | Interval fix | LRU cache fix | Short-prompt decode median | Longer-input TTFT |
|---|---:|---:|---:|---:|
| general-nothink | fail, 23.05 s | fail, 32.49 s | 82.42 tok/s | 1.81 s |
| flash-next-nothink | pass, 29.15 s | pass, 25.42 s | 67.87 tok/s | 4.10 s |
| flash-next-huihui-nothink | pass, 24.51 s | pass, 20.56 s | 75.59 tok/s | 4.06 s |

Decode medians use three 128-token samples. The longer prompt has 10,315
characters and asks for a short log summary. The earlier standalone Strata run
measured 109.17 tok/s; use the deployed profile's measurements above for planning.
First pool load plus a small answer took 36.94 s. Voice first-audio latency was
636.5 ms before and 639.5 ms during the Qwen trial (10 turns each).

The experimental `strata-bench` and `maya-bench` units have no boot activation,
use GPU1 only, and conflict with the normal pool while active. Their API ports
bind loopback and are accessed through SSH. Stop a benchmark unit and start
`llm-pool.service` to restore normal serving. The Strata unit prepared the Qwen
files; the Maya unit is for GLM-5.3-Flash Maya-S24 CPU/GPU/NVMe offload trials.


Nanbeige trial added the same day: `nanbeige-33b` / `nanbeige-33b-nothink`.
The upstream is [Nanbeige4.3-33B](https://huggingface.co/Nanbeige/Nanbeige4.3-33B),
a dense Llama architecture. The pinned Bartowski Q4_K_S GGUF is 19,740,519,552
bytes, revision `9beb68421fdf7be095093a6888325fa2c83ddd38`, SHA256
`b61162b5c20e31cd19d92607d2c2237950e8f3dcb307b3d7ca792c9a65eeffe5`.
It uses the existing Prism llama.cpp binary, all layers on GPU1, 32k context,
Q4_0 K/V cache, one sequence and 128-token microbatches. Total GPU1 use measured
22,861 MiB including stt-batch, leaving 1,317 MiB free. The chat template requests
XML tools and preserved reasoning; the non-thinking alias explicitly disables
thinking. Its model-card scores use high thinking effort, so those scores are
not comparable to this non-thinking smoke test.

Nanbeige's warm short-prompt decode median was 37.23 tok/s, short TTFT 38.4 ms,
and longer-input TTFT 3.92 s. First load plus a short answer took 12.46 s.
Concurrent short speech transcription succeeded (155.1 ms median, five samples).
Flash Next also passed short (67.0 ms median, five samples) and 13.71-second
(224.1 ms, one measured sample after warm-up) transcription checks while loaded.
These speech runs used the `stt.pow` route: stt-batch is not on the `voice` network.


`nvidia-smi topo -m` reports **NV4** between the two 3090s on .195. Maya can
split a model across local GPUs and pipeline GLM work, but this trial exposes
only GPU1. A full two-card comparison needs a separate voice allocation plan;
48 GiB of physical VRAM is not 48 GiB currently available to the coding pool.
The current router chooses a host for a whole request and does not distribute
inference between .195 and .58.


Nanbeige non-thinking passed the cache task in 191.53 s but timed out on intervals
at 600 s. It repeatedly repaired its own tests, initially edited a mistyped path,
and triggered context compaction. A fresh thinking-enabled interval retest passed
in 258.32 s. Reasoning blocks were present in the trace even though LiteLLM's
aggregate usage reported zero `thinking_tokens`; use the trace, not that counter,
to identify the mode. This gives 1/2 non-thinking tasks and 1/1 thinking retest,
not a complete thinking-mode score.


GLM-5.3-Flash Maya-S24 trial: pinned weights
`peasantsmith/GLM-5.3-Flash-Maya-GGUF@f16ee4ba50d8fd2bb726ea1862ca6ca14ba188da`,
three shards totaling 94,701,676,224 bytes. Project Maya v1.1.28 is built from
`6afa525bbabc3a8f5fd165f89e9bc72155d9bd39` for SM86. Pack preparation must put
the pack **inside the shard directory**, because its native references use
`../<shard-name>`. The launcher must pass the bundled
`/opt/maya/data/expert-profile-glm.bin`, as upstream setup does; omitting it
leaves uniform per-layer slots and an unsuitable initial expert placement.

The initial diagnostics omitted that profile: 36 GiB pinned experts with speech
running gave a 4.04 tok/s median; pausing voice-agent, voice-llm, voice-stt,
voice-tts and stt-batch permitted 46 GiB and a larger GPU1 cache. Those early
runs are retained as diagnostics, not representative final Maya results.
A 42 GiB configuration also loaded with speech running and 7.5 GiB MemAvailable,
but was not speed-tested. All runs still expose **GPU1 only**.

With the profile corrected and speech paused, the final 46 GiB run measured
6.73 tok/s median, short TTFT 381.6 ms, and longer-input TTFT 16.79 s. It holds
about 52.8 GB in the container, with a 52 GiB cap; the host retained about 10 GiB
MemAvailable. The default benchmark unit remains 36 GiB (safe beside speech);
46 was a temporary live override, not an automatic idle policy. The native
Maya Anthropic API is reached through an SSH tunnel for the agent trials.

Sources for the tuning investigation:
[Maya settings](https://github.com/mw00/project-maya/blob/main/docs/SETTINGS.md)
and [24 GB GPU / 64 GB RAM report](https://github.com/mw00/project-maya/issues/274).
The reference machine has a much newer CPU/GPU and more free expert-cache memory;
its performance is not a promise for this i7-7700K host. CPU quota throttling in
our baseline was only 0.48 seconds across 3,073 periods, so the CPU cap was not
relaxed. Logs instead showed about 200 ms/token in disk waits before tuning.


The corrected Maya configuration passed both independent Claude Code checks:
intervals **596.03 s**, cache **498.32 s**, within a 600 s deadline each.
The native Anthropic endpoint honored Claude Code's thinking request despite
`MAX_THINKING_TOKENS=0` and the server's fallback effort `none`: reasoning blocks
and `thinking` engine phases are present in the trace. Thus these are **thinking
agent results**, while the OpenAI speed probe explicitly disabled thinking.
They are not an equal-mode accuracy comparison with the non-thinking profiles.
GPU1 negotiated PCIe 3.0 x8 during inference; individual tool-prompt reads moved
tens of GB over PCIe at about 4.7 GB/s. The two-GPU Strata trial follows.


### Two-GPU Strata trial (2026-10-26; exploratory)

The installed Strata 0.1.48 engine supports a layer split, but the `llm-pool`
quadlet had exposed only host GPU1 and `flash-next.json` selected container GPU0.
For this trial, the container was temporarily given both 3090s and Strata was
configured with `gpu: [0, 1]`. `nvidia-smi topo -m` reports NV4 between them.
The test used Flash Next IQ2_XS, the 131,072-token context, int8 KV and Huihui
projection; benchmark requests disabled thinking, used temperature 0 and capped
output at 256 tokens.

Initial short-request smoke samples: single GPU, 98.24 and 101.18 tok/s
(median **99.71**); dual GPU with the voice LLM running, 73.67 and 107.99 tok/s
(median **90.83**). These two-sample arms are exploratory. The split used layers
0-10 on GPU0 and 11-47 on GPU1, while GPU0's voice workloads left only **475
MiB** free after load; Strata warned that memory pressure could page and stall
long prompts.

With only `voice-llm.service` stopped (voice STT and TTS remained up), the split
balanced at layers 0-23 / 24-47. Strata reported **94% of profiled experts
resident**. A live 119,139-token Claude prompt was read in 35 seconds (about
3,400 prompt tok/s); the response was generating at about 110 tok/s in the
available log sample. This is a live-workload observation, not a matched A/B
benchmark. For a matched short coding probe, both cards were tested with the
voice LLM stopped, the same two prompts, temperature 0, thinking off, Huihui
projection on and a 256-token cap. After a clean model reload and warmup, the
single-GPU repeat measured **110.58 tok/s median** (four requests); the dual-GPU
repeat measured **139.78 tok/s median** (four requests), a **26%** increase in
this small sample. Median TTFT was 0.401 s versus 0.224 s. A separate, already
warm dual-GPU run measured 165.03 tok/s median, showing material run-to-run
spread; these numbers are directional, not a robust benchmark. Cold model load
took 31.7 s single-GPU and 35.6 s dual-GPU, excluded from decode medians.

After loading the split, the engine reported only **474 MiB free on GPU0 and
424 MiB on GPU1**, still below its own recommended reserves. Thus the split
works and both cards participate, and the matched sample improved decode speed,
but the 128k profile leaves too little headroom for safe permanent use. The
voice LLM was stopped temporarily and then restarted; the deployed pool and
queue were restored to GPU1-only. Full measurements are in
[`dual-gpu-trial-20261026.json`](../hosts/gpu-195/bench/dual-gpu-trial-20261026.json).

### Request-idle voice GPU lease

The voice LLM's idle timer measures time since the last request through its
OpenAI API gateway. After 300 seconds with no requests, the gateway calls vLLM
`/sleep?level=1`, which offloads model weights to host RAM. The next voice API
request checks llama-swap's global GPU memory metrics. If Flash Next is running
on GPU1 only, voice wakes on GPU0 immediately, even while that coding request is
active. If Flash Next holds both cards, the gateway waits for its normal
five-minute TTL to release GPU0 before waking voice. The gateway never
force-unloads Flash Next. If it cannot verify that GPU0 has been released within
30 minutes, it returns a retryable 503 and leaves the local session untouched.

The gateway alone publishes port 8100. vLLM stays private on `voice.network`
because its development sleep/wake endpoints are unauthenticated. Other pool
models stay on GPU1. Flash Next checks the gateway's heartbeat state when it
starts: it uses GPU1 while voice is awake or the state is stale, and GPUs 0+1
only while the gateway confirms voice is asleep. The gateway refreshes that
state every 15 seconds during idle, so a crashed gateway fails closed to GPU1.

This is a launch-time lease, not continuous GPU migration: when voice wakes,
the dual-GPU engine is unloaded. The next Flash Next launch can lease both
cards again if voice has returned to idle. The dual split has under 0.5 GiB
free per card in the trial, so this mode is suitable only when the voice LLM
has fully offloaded; voice STT/TTS and unrelated GPU workloads still affect
available memory. The gateway uses an 8 GiB GPU0 reserve threshold; unknown
metrics fail closed and keep waiting. Runtime behavior should be observed after
deployment.

Live wake check on 26 October: with Flash Next still running on GPU1 and GPU0
using 4.1 GiB for voice STT/TTS, `GET /v1/models` through the gateway returned
200 in 1.09 seconds. The voice LLM woke on GPU0 (about 13.3 GiB total use), and
the Flash Next process stayed running on GPU1. This confirms the two workloads
can overlap when Flash Next has a single-GPU lease. It is still one model
generation slot: the two-slot trial above was 45.6% slower in aggregate, so
additional agent and subagent requests share the fair queue rather than
overcommitting the engine.
