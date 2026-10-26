#!/bin/bash
# Run on gpu-195. Sequential cards, disposable container, no service restarts.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=${1:?usage: bench.sh before|after}
[[ $LABEL == before || $LABEL == after ]] || exit 2
CACHE=${GPU_UNLOCK_CACHE:-$HOME/.cache/powos-gpu-unlock}
mkdir -p "$CACHE/bench"
IMAGE_FILE="$CACHE/bench/image-id"
if [[ $LABEL == before ]]; then
    if [[ ! -e "$IMAGE_FILE" ]]; then
        podman image inspect localhost/llm-pool:latest --format '{{.Id}}' > "$IMAGE_FILE"
    fi
fi
IMAGE=$(cat "$IMAGE_FILE")
for gpu in 0 1; do
    OUT="$LABEL-gpu$gpu.json"
    if [[ -e "$CACHE/bench/$OUT" ]]; then
        echo "Keeping existing $OUT (archive the bench directory to start fresh)"
        continue
    fi
    podman run --rm --network=none --device nvidia.com/gpu=all --security-opt label=disable \
        --userns=keep-id --user "$(id -u):$(id -g)" --cpus=2 --memory=4g --pids-limit=256 \
        -e CUDA_VISIBLE_DEVICES=0,1 -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
        -v "$HERE:/bench:ro" -v "$CACHE/bench:/results" --entrypoint python3 "$IMAGE" \
        /bench/bench.py run --gpu "$gpu" --label "$LABEL" --output "/results/$OUT"
done
if [[ $LABEL == after ]]; then
    for gpu in 0 1; do
        python3 "$HERE/bench.py" compare "$CACHE/bench/before-gpu$gpu.json" "$CACHE/bench/after-gpu$gpu.json"
    done
fi
