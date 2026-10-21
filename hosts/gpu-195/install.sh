#!/bin/bash
# hosts/gpu-195/install.sh - (re)deploy the realtime voice path on the GPU server gpu-195 (192.168.50.195).
# Run as the user powos on the box, from the PowOS checkout (~/Projects/PowOS, `git pull` first). Idempotent.
#
#   GPU0: voice-stt (faster-whisper large-v3-turbo, whisper-fast) + voice-tts (Kokoro) + voice-llm (vLLM Qwen3-8B-AWQ), resident
#   GPU1: stt-batch (the same whisper-fast, for files and dictation: http://stt.pow), resident
#         llm-pool (llama-swap + vLLM: general Qwen3-14B-AWQ / vision Qwen2.5-VL-7B-AWQ / embed bge-m3, http://llm-gpu.pow),
#         each model loaded on first request, unloaded after 10 idle minutes
#   CPU:  voice-agent (VoiceAgent backend, /ws) + voice-web (Astro UI)
#
# Everything is a rootless podman quadlet (~/.config/containers/systemd -> systemd --user, linger on, so it starts at
# boot) and a registered unit (units/gpu-195/*.json -> powos units). GPUs come from CDI: the image's
# nvidia-cdi-refresh writes /var/run/cdi/nvidia.yaml at boot and on driver changes, so no /etc/cdi copy (it would go
# stale on the next driver update). VoiceAgent is built into images from its git checkout (no bind-mounted code, no
# --reload). Plan and measurements: docs/GPU-SERVERS-PLAN.md.
#
#   ./install.sh            install/update config, rebuild the VoiceAgent images, register units, (re)start
#   ./install.sh --no-build skip the image builds
#   bench: podman run --rm --network voice --security-opt label=disable -v "$PWD/bench:/bench:ro" \
#              localhost/voiceagent-backend:latest python /bench/voice-bench.py all
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
VA="${VOICEAGENT_DIR:-$HOME/Projects/VoiceAgent}"
QUADLETS="$HOME/.config/containers/systemd"
CONF="$HOME/.config/voiceagent"
POOLCONF="$HOME/.config/llm-pool"

mkdir -p "$QUADLETS" "$CONF" "$POOLCONF" /var/lib/powos/models/{hf,torch,vllm} /var/lib/powos/voiceagent
install -m 644 "$HERE"/quadlets/* "$QUADLETS"/
install -m 644 "$HERE/voiceagent.env" "$CONF/voiceagent.env"
install -m 644 "$HERE/llm-pool/config.yaml" "$POOLCONF/config.yaml"
if [[ ! -s "$CONF/secrets.env" ]]; then
    # The LiteLLM provider refuses to start with an empty key, even while unused (DEFAULT_LLM_PROVIDER=vllm).
    echo "missing $CONF/secrets.env (mode 600): LITELLM_API_KEY=<the LiteLLM key>" >&2
    exit 1
fi
chmod 600 "$CONF/secrets.env"

if [[ "${1:-}" != "--no-build" ]]; then
    [[ -d "$VA/.git" ]] || { echo "no VoiceAgent checkout at $VA (git clone it, branch server-gpu195)" >&2; exit 1; }
    podman build -t localhost/voice-stt-fast:latest "$VA/services/whisper-fast"
    podman build -t localhost/voiceagent-backend:latest "$VA/VoiceAgentWeb/services/voice-agent"
    podman build -t localhost/voiceagent-web:latest "$VA/VoiceAgentWeb"
    podman build -t localhost/llm-pool:latest "$HERE/llm-pool"
fi

loginctl show-user "$USER" -p Linger | grep -q yes || loginctl enable-linger "$USER"
systemctl --user daemon-reload
for m in "$REPO"/units/gpu-195/*.json; do
    python3 "$REPO/lib/apps/powos-units" register "$m"
done
systemctl --user start voice-stt.service voice-tts.service voice-llm.service stt-batch.service llm-pool.service
systemctl --user restart voice-agent.service voice-web.service
echo "voice path up: http://voiceagent.pow (Traefik on .100), backend :9000, stt :8000, tts :8880, llm :8100; stt.pow :8001; llm-gpu.pow :9292"
