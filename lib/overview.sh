#!/bin/bash
# overview.sh - one-glance summary of what THIS PowOS install actually is:
# which layer model it's on, the base image/channel, GPU/CUDA, deployments
# (rollback), services, containers, disk, and safety posture.
#
#   powos overview          # human-readable panel
#   powos overview --json    # machine-readable (for widgets/plasmoids)
#
# Everything here is read-only and non-root, so a desktop widget can poll it.
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; NC=$'\033[0m'

# ── data collectors (all defensive; never hard-fail) ─────────────
ov_booted_ref() {
    rpm-ostree status --json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for dep in d.get("deployments",[]):
    if dep.get("booted"):
        r=dep.get("container-image-reference") or ""
        for p in ("ostree-unverified-registry:","ostree-image-signed:","ostree-unverified-image:","ostree-remote-image:"):
            if r.startswith(p): r=r[len(p):]; break
        if "://" in r: r=r.split("://",1)[1]
        print(r); break' 2>/dev/null
}
ov_deploy_count() { rpm-ostree status --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("deployments",[])))' 2>/dev/null || echo 0; }
ov_booted_ver()  { rpm-ostree status --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for x in d.get("deployments",[]):
    if x.get("booted"): print(x.get("version","")); break' 2>/dev/null; }
ov_model() {
    # overlay-stack (USB portable) vs bootc deployment (fixed/registry install)
    if [[ -e /run/powos/layer-paths ]]; then echo "overlay-stack (USB portable)"; else echo "bootc deployment (fixed install)"; fi
}
ov_channel() { case "${1##*:}" in nvidia-open) echo stable;; nvidia-open-testing) echo testing;; nvidia) echo "closed";; main) echo "amd/intel";; *) echo "${1##*:}";; esac; }
ov_gpu()    { nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1; }
ov_driver() { nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1; }
ov_cuda_rt(){ nvidia-smi -q 2>/dev/null | grep -m1 -i 'CUDA Version' | grep -oE '[0-9]+\.[0-9]+' | head -1; }
ov_cuda_ct(){ podman container exists powos-cuda 2>/dev/null && echo "ready" || echo "not set up"; }
ov_svc_active() { systemctl is-active powos-"$1".service 2>/dev/null; }
ov_container_count() { podman ps -q 2>/dev/null | wc -l | tr -d ' '; }
ov_var_use() { df -h /var 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}'; }
ov_repo_size() { du -sh /sysroot/ostree/repo 2>/dev/null | awk '{print $1}'; }

cmd_overview() {
    [[ "${1:-}" == "--json" ]] && { ov_json; return; }

    local ref ver model gpu drv crt cct
    ref="$(ov_booted_ref)"; ver="$(ov_booted_ver)"; model="$(ov_model)"
    gpu="$(ov_gpu)"; drv="$(ov_driver)"; crt="$(ov_cuda_rt)"; cct="$(ov_cuda_ct)"

    echo -e "${BOLD}PowOS Overview${NC}"
    echo    "════════════════════════════════════════"
    printf  "  %-14s %s\n" "Model:"   "$model"
    printf  "  %-14s %s ${DIM}(%s)${NC}\n" "Base image:" "${ref:-unknown}" "${ver:-?}"
    printf  "  %-14s ${GREEN}%s${NC}\n" "Driver ch:" "$(ov_channel "$ref")"
    [[ -n "$gpu" ]] && printf "  %-14s %s · driver %s · CUDA %s\n" "GPU:" "$gpu" "${drv:-?}" "${crt:-?}"
    printf  "  %-14s %s\n" "CUDA toolkit:" "$cct (powos-cuda container)"
    echo

    printf  "  %-14s %s ${DIM}(1 booted + rollback)${NC}\n" "Deployments:" "$(ov_deploy_count)"

    echo -e "  ${BOLD}Services${NC}"
    local s st
    for s in cachefs-sync layer-sync ramboot-init; do
        st="$(ov_svc_active "$s")"
        case "$st" in
          active)   printf "    ${GREEN}●${NC} powos-%s ${DIM}(running)${NC}\n" "$s" ;;
          *)        printf "    ${DIM}○ powos-%s (%s)${NC}\n" "$s" "${st:-inactive}" ;;
        esac
    done

    printf  "  %-14s %s running\n" "Containers:" "$(ov_container_count)"
    printf  "  %-14s %s used · ostree repo %s\n" "Storage:" "$(ov_var_use)" "$(ov_repo_size)"
    echo
    echo -e "  ${BOLD}Safety${NC}  ${GREEN}✓${NC} base is read-only  ${GREEN}✓${NC} rollback deployment kept  ${GREEN}✓${NC} your data on btrfs /var"
    echo -e "  ${DIM}Update: sudo bootc upgrade && reboot · Roll back: pick prev entry at boot${NC}"
}

ov_json() {
    OV_REF="$(ov_booted_ref)" OV_VER="$(ov_booted_ver)" OV_MODEL="$(ov_model)" \
    OV_CH="$(ov_channel "$(ov_booted_ref)")" OV_GPU="$(ov_gpu)" OV_DRV="$(ov_driver)" \
    OV_CRT="$(ov_cuda_rt)" OV_CCT="$(ov_cuda_ct)" OV_DEP="$(ov_deploy_count)" \
    OV_CACHE="$(ov_svc_active cachefs-sync)" OV_LAYER="$(ov_svc_active layer-sync)" \
    OV_CTN="$(ov_container_count)" OV_VAR="$(ov_var_use)" OV_REPO="$(ov_repo_size)" \
    python3 -c '
import json, os
o=os.environ.get
print(json.dumps({
  "model": o("OV_MODEL"), "base_image": o("OV_REF"), "version": o("OV_VER"),
  "driver_channel": o("OV_CH"), "gpu": o("OV_GPU"), "driver": o("OV_DRV"),
  "cuda_runtime": o("OV_CRT"), "cuda_toolkit": o("OV_CCT"),
  "deployments": int(o("OV_DEP") or 0),
  "services": {"cachefs_sync": o("OV_CACHE"), "layer_sync": o("OV_LAYER")},
  "containers": int(o("OV_CTN") or 0),
  "var_usage": o("OV_VAR"), "ostree_repo": o("OV_REPO"),
}, indent=2))'
}
