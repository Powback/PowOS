#!/bin/bash
# services.sh - overview of containerized workloads (podman/distrobox) and the
# container-backed systemd services, plus who's actually on the GPU. This is the
# "what are my gsplat / TTS / STT / dev boxes doing" panel, distinct from
# `powos overview` (which is the OS/system panel).
#
#   powos services            # human panel
#   powos services --json      # machine-readable (widgets)
#
# Read-only, non-root.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# Does this container have GPU access? (distrobox --nvidia, CDI, or --device)
svc_gpu_access() { podman inspect "$1" 2>/dev/null | grep -qi 'nvidia' && echo yes || echo no; }
# dev box (distrobox) vs a plain service container
svc_kind() { podman inspect "$1" --format '{{index .Config.Labels "manager"}}' 2>/dev/null | grep -qi distrobox && echo dev || echo service; }

svc_containers_human() {
    echo -e "  ${BOLD}Containers (podman)${NC}"
    local any=0 line name image status ports gpu kind
    while IFS='|' read -r name image status ports; do
        [[ -z "$name" ]] && continue
        any=1
        gpu="$(svc_gpu_access "$name")"; kind="$(svc_kind "$name")"
        image="${image##*/}"            # short image name
        printf "    ${GREEN}●${NC} %-16s %-28s ${DIM}%s${NC}\n" "$name" "$image" "$status"
        printf "      ${DIM}kind:%s  gpu:%s  ports:%s${NC}\n" "$kind" "$gpu" "${ports:-none}"
    done < <(podman ps --format '{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}' 2>/dev/null)
    [[ $any -eq 0 ]] && echo -e "    ${DIM}(none running)${NC}"
    # stopped ones worth noting
    local stopped; stopped="$(podman ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
    [[ -n "$stopped" ]] && echo -e "    ${DIM}stopped: $stopped${NC}"
}

svc_systemd_human() {
    echo -e "  ${BOLD}Container services (systemd)${NC}"
    local found=0 u load active scope
    for scope in "--user" ""; do
        while read -r u load active _; do
            [[ -z "$u" ]] && continue
            found=1
            if [[ "$load" == "not-found" ]]; then
                printf "    ${YELLOW}⚠${NC} %-28s ${YELLOW}stale (not-found — cleanup?)${NC} %s\n" "$u" "${scope:-system}"
            elif [[ "$active" == "failed" ]]; then
                printf "    ${RED}✗${NC} %-28s ${RED}failed${NC} %s\n" "$u" "${scope:-system}"
            else
                printf "    ${GREEN}●${NC} %-28s %s %s\n" "$u" "$active" "${scope:-system}"
            fi
        done < <(systemctl $scope list-units --type=service --all --plain --no-legend 2>/dev/null \
                 | grep -iE 'speaches|whisper|piper|tts|stt|ollama|comfyui|gsplat|\.container|podman-' \
                 | grep -vE 'podman-user-wait|podman-auth|podman-restart|podman\.service' \
                 | awk '{print $1, $2, $3}')
    done
    [[ $found -eq 0 ]] && echo -e "    ${DIM}(no container-backed services)${NC}"
}

svc_gpu_human() {
    command -v nvidia-smi >/dev/null 2>&1 || return
    local name mem util procs
    name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
    mem="$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1)"
    util="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null | head -1)"
    echo -e "  ${BOLD}GPU${NC}  $name"
    printf  "    vram: %s   util: %s\n" "${mem:-?}" "${util:-?}"
    procs="$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader 2>/dev/null)"
    if [[ -n "$procs" ]]; then
        echo "$procs" | while IFS=',' read -r pn pm; do printf "    ${DIM}• %s (%s)${NC}\n" "${pn##*/}" "$(echo "$pm"|xargs)"; done
    else
        echo -e "    ${DIM}• no compute processes${NC}"
    fi
}

cmd_services() {
    [[ "${1:-}" == "--json" ]] && { svc_json; return; }
    echo -e "${BOLD}PowOS Services${NC}"
    echo    "════════════════════════════════════════"
    svc_containers_human; echo
    svc_systemd_human;    echo
    svc_gpu_human
    echo
    echo -e "  ${DIM}Run a GPU workload:  powos cuda enter  ·  or a quadlet in ~/.config/containers/systemd/${NC}"
}

svc_json() {
    python3 -c '
import json, subprocess
def sh(c):
    try: return subprocess.run(c, capture_output=True, text=True, timeout=8).stdout
    except Exception: return ""
conts=[]
for ln in sh(["podman","ps","--format","{{.Names}}|{{.Image}}|{{.Status}}|{{.Ports}}"]).splitlines():
    p=ln.split("|")
    if len(p)>=1 and p[0]:
        insp=sh(["podman","inspect",p[0]])
        conts.append({"name":p[0],"image":p[1] if len(p)>1 else "","status":p[2] if len(p)>2 else "",
                      "ports":p[3] if len(p)>3 else "","gpu": "nvidia" in insp.lower()})
gpu={}
g=sh(["nvidia-smi","--query-gpu=name,memory.used,memory.total,utilization.gpu","--format=csv,noheader"]).strip()
if g:
    f=[x.strip() for x in g.split(",")]
    gpu={"name":f[0],"mem_used":f[1] if len(f)>1 else "","mem_total":f[2] if len(f)>2 else "","util":f[3] if len(f)>3 else ""}
    gpu["procs"]=[{"name":l.split(",")[0].strip(),"mem":l.split(",")[1].strip()}
                  for l in sh(["nvidia-smi","--query-compute-apps=process_name,used_memory","--format=csv,noheader"]).splitlines() if "," in l]
print(json.dumps({"containers":conts,"gpu":gpu}, indent=2))'
}
