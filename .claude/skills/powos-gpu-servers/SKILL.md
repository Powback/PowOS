---
name: powos-gpu-servers
description: Use when working on the LAN's GPU servers - gpu-195 (2x RTX 3090: voice stack, stt-batch, llm-pool) and .58 (RTX 5090, coder-32b), the llm.pow / llm-gpu.pow / stt.pow / voiceagent.pow routes, model loads, benchmarks, units and fan noise.
---

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
  so run the repo's over ssh with the repo manifest:
  `ssh powos@192.168.50.58 "POWOS_UNITS_DIR=\$HOME/.config/powos/units.d python3 - register /dev/stdin" ...` won't
  work (stdin is the script), so: `scp units/gpu-58/llama-swap-58.json powos@192.168.50.58:/tmp/u.json && ssh
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
