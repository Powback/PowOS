#!/bin/bash
# build-image.sh - build the PowOS OS image LOCALLY and optionally deploy it,
# with NO GitHub push and NO cloud CI. Your own machine builds, verifies, and
# switches itself. Local podman caches layers, so rebuilds after a script change
# are fast (no ~15 GB base re-pull) — this is the self-hosted counterpart to the
# build-publish workflow.
#
#   powos build image [variant] [--switch] [--push] [--validate] [--tag REF]
#     variant : nvidia-open (default) | nvidia-open-testing | nvidia | main
#     --switch   rebase THIS system onto the freshly built image + offer reboot
#     --push     push to ghcr.io/<owner>/powos:<variant> (needs 'powos registry login')
#     --validate run build/validate.sh after the build
#     --tag REF  extra tag to apply (e.g. a registry ref to push)
#
# --switch builds into ROOT's container storage (sudo podman) so bootc can read
# it via the containers-storage transport. Plain builds are rootless.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
bi_log()  { echo -e "${CYAN}[build-image]${NC} $*"; }
bi_ok()   { echo -e "${GREEN}[build-image]${NC} $*"; }
bi_warn() { echo -e "${YELLOW}[build-image]${NC} $*"; }
bi_err()  { echo -e "${RED}[build-image]${NC} $*" >&2; }

bi_base_for() {
    case "$1" in
        nvidia-open)         echo "ghcr.io/ublue-os/bazzite-nvidia-open:stable" ;;
        nvidia-open-testing) echo "ghcr.io/ublue-os/bazzite-nvidia-open:testing" ;;
        nvidia)              echo "ghcr.io/ublue-os/bazzite-nvidia:stable" ;;
        main)                echo "ghcr.io/ublue-os/bazzite:stable" ;;
        *)                   return 1 ;;
    esac
}

# Where to build from: an explicit context, else a repo checkout in CWD, else the
# bundled source shipped into the image.
bi_context() {
    if [[ -n "${POWOS_BUILD_CONTEXT:-}" ]]; then echo "$POWOS_BUILD_CONTEXT"
    elif [[ -f "./Containerfile" ]]; then echo "."
    else echo "${POWOS_SRC:-/var/lib/powos/src}"; fi
}

cmd_build_image() {
    local variant="nvidia-open" do_switch=0 do_push=0 do_validate=0 extra_tag=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --switch)   do_switch=1 ;;
            --push)     do_push=1 ;;
            --validate) do_validate=1 ;;
            --tag)      extra_tag="$2"; shift ;;
            -h|--help)
                sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
            nvidia-open|nvidia-open-testing|nvidia|main) variant="$1" ;;
            *) bi_err "Unknown arg: $1"; return 1 ;;
        esac
        shift
    done

    local base ctx img
    base="$(bi_base_for "$variant")" || { bi_err "Unknown variant '$variant'"; return 1; }
    ctx="$(bi_context)"
    img="localhost/powos:$variant"
    [[ -f "$ctx/Containerfile" ]] || { bi_err "No Containerfile in build context '$ctx'"; return 1; }

    # --switch needs the image in ROOT storage so bootc can read it.
    local PODMAN=(podman)
    (( do_switch )) && PODMAN=(sudo podman)

    bi_log "Variant:  $variant   (base: $base)"
    bi_log "Context:  $ctx"
    bi_log "Builder:  ${PODMAN[*]}  →  $img"

    # Vendor upstream bazzite/ (system_files) if the helper is present.
    if [[ -x "$ctx/build/vendor-bazzite.sh" ]]; then
        bi_log "Vendoring bazzite system_files…"
        ( cd "$ctx" && ./build/vendor-bazzite.sh ) || { bi_err "vendor-bazzite failed"; return 1; }
    fi

    bi_log "Building (local layer cache makes repeat builds fast)…"
    local tags=(-t "$img"); [[ -n "$extra_tag" ]] && tags+=(-t "$extra_tag")
    if ! "${PODMAN[@]}" build --layers \
            --build-arg "BASE_IMAGE=$base" \
            -f "$ctx/Containerfile" "${tags[@]}" "$ctx"; then
        bi_err "Build failed."; return 1
    fi
    bi_ok "Built $img"

    if (( do_validate )) && [[ -x "$ctx/build/validate.sh" ]]; then
        bi_log "Running validation ladder…"
        ( cd "$ctx" && ./build/validate.sh ) || bi_warn "validate.sh reported issues (see above)."
    fi

    if (( do_push )); then
        [[ -n "$extra_tag" ]] || { bi_err "--push needs --tag ghcr.io/<owner>/powos:$variant"; return 1; }
        bi_log "Pushing $extra_tag …"
        "${PODMAN[@]}" push "$extra_tag" || { bi_err "push failed (try: powos registry login)"; return 1; }
        bi_ok "Pushed $extra_tag"
    fi

    if (( do_switch )); then
        bi_log "Rebasing this system onto the local image…"
        if ! sudo bootc switch --transport containers-storage "$img"; then
            bi_err "bootc switch failed."; return 1
        fi
        bi_ok "Staged $img. Review: sudo bootc status"
        bi_ok "Old deployment stays as rollback."
        read -rp "Reboot now to apply? [y/N] " a
        [[ "$a" =~ ^[Yy]$ ]] && sudo systemctl reboot
    else
        echo
        bi_ok "Done. Next:"
        echo "  powos build image $variant --switch      # deploy it to THIS machine"
        echo "  ${PODMAN[*]} run --rm -it $img bash       # poke around inside"
    fi
}
