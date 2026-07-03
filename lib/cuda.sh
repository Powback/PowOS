#!/bin/bash
# cuda.sh - CUDA toolkit as a GPU-passthrough dev container.
#
# On an immutable base you don't bake the ~6 GB CUDA toolkit into /usr. Instead
# CUDA (nvcc, cuDNN, libs) lives in a distrobox that shares your $HOME and gets
# the host NVIDIA driver passed through (--nvidia). You run/compile GPU code
# INSIDE it at native speed; `nvcc` is exported to the host so it feels local.
#
#   powos cuda enable        # create the container (first run pulls ~6 GB)
#   powos cuda enter         # shell inside the CUDA env
#   powos cuda run <cmd...>  # run one command inside (e.g. powos cuda run nvcc -V)
#   powos cuda status        # container + nvcc + GPU visibility
#   powos cuda disable       # remove the container (clean; toolkit is gone)
#
# CONSTRAINTS (be honest):
#   - Needs the NVIDIA driver on the HOST. The container only carries the toolkit;
#     the driver is what talks to the GPU. `enable` warns if nvidia-smi is absent.
#   - RTX 50-series (Blackwell, sm_120) REQUIRES CUDA >= 12.8 to COMPILE for it.
#     The default image below is 12.8 for exactly this reason — don't drop it to
#     12.4 or gaussian-splatting / custom kernels won't target the card.
#   - The toolkit's CUDA version must be <= the host driver's CUDA (forward-compat).
#     Driver 610 (CUDA 13.x) runs a 12.8 toolkit fine.
set -uo pipefail
source "${POWOS_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/common.sh"
POWOS_TAG=cuda


# Fully-qualified on purpose: podman short-name resolution can't prompt in
# non-interactive contexts (scripts, installer) and aborts otherwise.
CUDA_CONTAINER="${POWOS_CUDA_CONTAINER:-powos-cuda}"
CUDA_IMAGE="${POWOS_CUDA_IMAGE:-docker.io/nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04}"
CUDA_PKGS="${POWOS_CUDA_PKGS:-python3 python3-pip git build-essential}"

cuda_host_driver_ok() { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }
# A distrobox IS a podman container of the same name — this is more reliable
# than parsing `distrobox list`.
cuda_exists() { podman container exists "$CUDA_CONTAINER" 2>/dev/null; }
# For NON-interactive/captured calls use `podman exec`, not `distrobox enter`:
# distrobox's enter wrapper dumps the shell environment when its output is piped,
# which corrupts captured output. `enter` is only for the interactive shell.
cuda_x() { podman exec "$CUDA_CONTAINER" bash -c 'export PATH=/usr/local/cuda/bin:$PATH; '"$*" 2>/dev/null; }

cmd_cuda_enable() {
    if ! command -v distrobox >/dev/null 2>&1; then
        perr "distrobox not found (should ship with PowOS)."; return 1
    fi
    if ! cuda_host_driver_ok; then
        pwarn "No working NVIDIA driver on the host (nvidia-smi sees no GPU)."
        pwarn "CUDA needs the driver on the host — fix that first (e.g. an nvidia base image)."
        pwarn "Continuing anyway; the toolkit will install but GPU calls will fail."
    fi
    if cuda_exists; then
        pok "'$CUDA_CONTAINER' already exists — 'powos cuda enter'."
        return 0
    fi
    plog "Creating '$CUDA_CONTAINER' from $CUDA_IMAGE"
    plog "(first run pulls ~6 GB; the toolkit lives in the container, not your OS)"
    if ! distrobox create --name "$CUDA_CONTAINER" --image "$CUDA_IMAGE" \
            --nvidia --additional-packages "$CUDA_PKGS" --yes; then
        perr "distrobox create failed."; return 1
    fi
    # First enter runs distrobox's init (user, home, exports). Do it once now.
    distrobox enter "$CUDA_CONTAINER" -- true >/dev/null 2>&1 || true
    pok "CUDA ready."
    echo "  powos cuda enter            # shell inside"
    echo "  powos cuda run nvcc --version"
    echo "  powos cuda status"
}

cmd_cuda_enter() {
    cuda_exists || { perr "Not set up. Run: powos cuda enable"; return 1; }
    distrobox enter "$CUDA_CONTAINER"
}

cmd_cuda_run() {
    cuda_exists || { perr "Not set up. Run: powos cuda enable"; return 1; }
    [[ $# -gt 0 ]] || { perr "Usage: powos cuda run <command...>"; return 1; }
    distrobox enter "$CUDA_CONTAINER" -- "$@"
}

cmd_cuda_status() {
    echo -e "${BOLD}CUDA (container: $CUDA_CONTAINER)${NC}"
    if cuda_exists; then
        echo -e "  container:  ${GREEN}present${NC}"
        local ver gpu
        ver=$(cuda_x 'nvcc --version | grep -o "release [0-9.]*"' | tail -1)
        gpu=$(cuda_x 'nvidia-smi -L | head -1')
        echo "  toolkit:    ${ver:-unknown} (image: $CUDA_IMAGE)"
        echo "  gpu inside: ${gpu:-not visible (check host driver)}"
    else
        echo -e "  container:  ${YELLOW}not created${NC}  →  powos cuda enable"
    fi
    if cuda_host_driver_ok; then
        echo "  host driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    else
        echo -e "  host driver: ${RED}not detected${NC}"
    fi
}

cmd_cuda_disable() {
    cuda_exists || { pok "Nothing to remove."; return 0; }
    plog "Removing '$CUDA_CONTAINER'…"
    distrobox rm -f "$CUDA_CONTAINER" && pok "Removed. (Your OS was never touched.)"
}

cmd_cuda_usage() {
    cat <<EOF
${BOLD}powos cuda${NC} — CUDA toolkit in a GPU-passthrough container

  powos cuda enable         Create the CUDA dev container (pulls ~6 GB once)
  powos cuda enter          Open a shell inside it (nvcc, python, gpu)
  powos cuda run <cmd...>   Run one command inside (e.g. powos cuda run nvcc -V)
  powos cuda status         Show container / toolkit / GPU visibility
  powos cuda disable        Remove the container

Image: $CUDA_IMAGE
(CUDA 12.8 = required to compile for RTX 50-series / Blackwell.)
EOF
}

cmd_cuda() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        enable|on|create|install) cmd_cuda_enable "$@" ;;
        enter|shell)              cmd_cuda_enter "$@" ;;
        run|exec)                 cmd_cuda_run "$@" ;;
        status|info)              cmd_cuda_status "$@" ;;
        disable|off|rm|remove)    cmd_cuda_disable "$@" ;;
        help|-h|--help)           cmd_cuda_usage ;;
        *) perr "Unknown: cuda $sub"; cmd_cuda_usage; return 1 ;;
    esac
}
