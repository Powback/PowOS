# GPU servers: the plan (2026-10-21)

PowOS now has real GPU servers on the LAN. This is how inference (voice, LLMs, everything AI) is laid out across
them, how it's run and managed, and the order to build it in. Status: **plan, not built**.

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
