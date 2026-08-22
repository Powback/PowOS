#!/usr/bin/env bash
# variants.sh - locate GPU-variant images carried ON the install media, so a
# machine can be installed with the RIGHT variant completely offline.
#
# THE PROBLEM
# `bootc install` writes the image it is given. The live USB carries exactly
# one variant's filesystem, so installing a different one used to mean pulling
# it from the registry — i.e. needing network at install time, on a machine
# that may not even have a working network driver yet. That is unacceptable for
# an installer.
#
# THE FIX
# The USB's POWOS-DATA partition carries an OCI layout holding every published
# variant. The installer imports the chosen variant off that layout and runs
# `bootc install` from it — no registry, no network. See the "Installing"
# section below for why it containerises rather than using --source-imgref
# (short version: --source-imgref does not work here, and it was tried).
#
# The INSTALLED system is still pointed at the registry via --target-imgref, so
# a later `bootc upgrade` works normally once the machine has network. Offline
# install, online updates.
#
# An OCI layout addresses blobs by digest, so the layers the variants share are
# stored ONCE. Three variants cost far less than three times one.

# Where the layout lives, relative to the POWOS-DATA mount point. Several
# candidates because POWOS-DATA may be mounted at its btrfs root (where the
# tree is @powos/...) or already inside the @powos subvolume, depending on how
# it got mounted. Checked in order; first hit wins.
POWOS_VARIANTS_SUBDIRS=("${POWOS_VARIANTS_SUBDIR:-@powos/variants}" "powos/variants" "variants")
# Registry the installed system should track. Overridable for forks/mirrors.
POWOS_VARIANTS_REPO="${POWOS_VARIANTS_REPO:-ghcr.io/powback/powos}"
# Where we mount POWOS-DATA if it is not already mounted.
POWOS_VARIANTS_MNT="${POWOS_VARIANTS_MNT:-/run/powos/variants-src}"

pv__log()  { echo "[variants] $*"; }
pv__warn() { echo "[variants] $*" >&2; }

# Mount point of the POWOS-DATA partition, mounting it read-only if needed.
# Prints the path, or nothing when there is no such partition.
pv_data_mount() {
    local dev mp
    dev=$(blkid -L POWOS-DATA 2>/dev/null || true)
    [[ -n "$dev" ]] || return 1

    mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null | head -1)
    if [[ -n "$mp" ]]; then printf '%s\n' "$mp"; return 0; fi

    # Not mounted yet — mount read-only. Read-only on purpose: the installer
    # only ever reads from here, and the stick may be shared/removable.
    mkdir -p "$POWOS_VARIANTS_MNT" 2>/dev/null || return 1
    if mount -o ro "$dev" "$POWOS_VARIANTS_MNT" 2>/dev/null; then
        printf '%s\n' "$POWOS_VARIANTS_MNT"; return 0
    fi
    return 1
}

# Directory of the OCI layout on the media, or nothing.
# POWOS_VARIANTS_DIR overrides everything (tests, and installing from a path
# the user supplies).
pv_variants_dir() {
    if [[ -n "${POWOS_VARIANTS_DIR:-}" ]]; then
        [[ -f "$POWOS_VARIANTS_DIR/index.json" ]] || return 1
        printf '%s\n' "$POWOS_VARIANTS_DIR"; return 0
    fi
    local mp dir sub
    mp=$(pv_data_mount) || return 1
    for sub in "${POWOS_VARIANTS_SUBDIRS[@]}"; do
        dir="$mp/$sub"
        if [[ -f "$dir/index.json" ]]; then printf '%s\n' "$dir"; return 0; fi
    done
    return 1
}

# Tags present in the layout, one per line. An OCI index records each image's
# tag in the org.opencontainers.image.ref.name annotation.
pv_list() {
    local dir
    dir=$(pv_variants_dir) || return 1
    python3 - "$dir/index.json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for m in d.get("manifests", []):
    ref = (m.get("annotations") or {}).get("org.opencontainers.image.ref.name")
    if ref:
        print(ref)
PY
}

# Is variant $1 available on the media?
pv_have_variant() {
    local want="$1" t
    [[ -n "$want" ]] || return 1
    while IFS= read -r t; do
        [[ "$t" == "$want" ]] && return 0
    done < <(pv_list)
    return 1
}

# --source-imgref value for variant $1 (bytes read from the media).
pv_source_imgref() {
    local want="$1" dir
    dir=$(pv_variants_dir) || return 1
    pv_have_variant "$want" || return 1
    printf 'oci:%s:%s\n' "$dir" "$want"
}

# --target-imgref value for variant $1 (what the installed system tracks).
pv_target_imgref() {
    local want="$1"
    [[ -n "$want" ]] || return 1
    printf '%s:%s\n' "$POWOS_VARIANTS_REPO" "$want"
}

# Human summary for the installer UI.
pv_describe() {
    local dir tags
    if ! dir=$(pv_variants_dir); then
        echo "no offline variant store on this media"
        return 0
    fi
    tags=$(pv_list | tr '\n' ' ')
    echo "offline variants on media: ${tags:-none} (${dir})"
}

# ── Installing ────────────────────────────────────────────────────────────
#
# bootc install MUST run INSIDE a podman container of the image being
# installed. This is not a style choice — all three forms were tried on real
# hardware with bootc 1.16.4:
#
#   bootc install to-disk ...                  -> "Either --source-imgref must
#                                                  be defined or this command
#                                                  must be executed inside a
#                                                  podman container."
#   bootc install --source-imgref oci:...      -> "Creating source info from a
#   bootc install --source-imgref containers-storage:...  given imageref:
#                                                  Multiple commit objects
#                                                  found" (both transports)
#   podman run <image> bootc install to-disk   -> "Installation complete!"
#
# So the installer containerises. The image must be resolvable in the DEFAULT
# containers-storage, because bootc inside the container reads the storage.conf
# shipped in that image (which references /usr/lib/containers/storage as an
# additional image store); pointing podman at an alternate --root makes the
# reference fail to resolve to an image ID.

# Local tag used for an image imported off the media.
POWOS_VARIANT_LOCAL_TAG="${POWOS_VARIANT_LOCAL_TAG:-localhost/powos-variant}"

# Make variant $1 available in the default containers-storage, importing it
# from the media if needed. Prints the image reference to run.
pv_prepare_image() {
    local want="$1" src ref
    ref="${POWOS_VARIANT_LOCAL_TAG}:${want}"

    # Already imported (e.g. a retry, or a previous install in this session).
    if podman image exists "$ref" 2>/dev/null; then
        printf '%s\n' "$ref"; return 0
    fi

    src=$(pv_source_imgref "$want") || return 1

    # Fail FAST if the unpack cannot fit. Unpacked a variant is ~13.5GB against
    # ~5.7GB compressed, and container storage is wherever
    # /var/lib/containers lives. Without this the install copies blobs for
    # several minutes and only then dies with "no space left on device", having
    # burned the time and left a half-written store behind — which is exactly
    # what happened on a Steam Deck whose medium root is 25.9GB.
    local need_mib=15000 have_mib store_dir=/var/lib/containers
    [[ -d "$store_dir" ]] || store_dir=/var
    have_mib=$(df -BM --output=avail "$store_dir" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [[ -n "$have_mib" ]] && (( have_mib < need_mib )); then
        pv__warn "not enough room to unpack '$want': $store_dir has ${have_mib}MiB free, need ~${need_mib}MiB."
        pv__warn "container storage lives on $(findmnt -no SOURCE --target "$store_dir" 2>/dev/null || echo "$store_dir")."
        pv__warn "on install media this should be POWOS-DATA — check the medium's /etc/fstab entry for /var/lib/containers."
        return 1
    fi
    pv__log "importing $want off the media into local storage (no network)..." >&2
    # Unpacked, this is ~13.5GB per variant against ~5.7GB compressed on the
    # media. A live system whose /var is small will fail here — callers should
    # relocate container storage onto the media first (see pv_storage_hint).
    skopeo copy "$src" "containers-storage:$ref" >&2 || return 1
    printf '%s\n' "$ref"
}

# Where container storage should live so an import has room. The media's
# @powos/containers is created by install-to-usb.sh for exactly this.
pv_storage_hint() {
    local mp
    mp=$(pv_data_mount) || return 1
    printf '%s\n' "$mp/@powos/containers"
}

# Run `bootc install to-disk` for image $1 onto device $2; remaining args are
# passed through to bootc.
pv_bootc_install() {
    local image="$1" target="$2"; shift 2
    podman run --rm --privileged --pid=host \
        --security-opt label=type:unconfined_t \
        -v /dev:/dev \
        -v /var/lib/containers:/var/lib/containers \
        "$image" \
        bootc install to-disk "$@" "$target"
}
