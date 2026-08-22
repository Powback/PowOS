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
    pv_media_storage_mount || true
    pv__log "importing $want off the media (no network)..." >&2
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

# Container storage ON THE MEDIA, created if needed.
#
# Unpacking a variant costs ~13.5GB. A live medium's root holds the OS and has
# nowhere near that free — on a Steam Deck stick it is 25.9GB with the system
# already in it, so the import died with "no space left on device" after
# copying blobs for several minutes. POWOS-DATA is the rest of the device
# (terabytes on a large drive), and install-to-usb already creates
# @powos/containers for exactly this.
#
# Prints "<graphroot>|<runroot>" so callers can point both skopeo and podman at
# it. Fails (silently) when there is no writable media, leaving the classic
# behaviour untouched for a normal installed system.
POWOS_MEDIA_RUNROOT="${POWOS_MEDIA_RUNROOT:-/run/powos-containers}"
POWOS_CONTAINERS_STORAGE="${POWOS_CONTAINERS_STORAGE:-/var/lib/containers/storage}"

# Put container storage ON THE MEDIA by bind-mounting it over the canonical
# path, rather than pointing tools at a different one.
#
# Why a bind and not --root/--runroot: bootc resolves its own image and then
# re-execs itself in the HOST mount namespace, and both steps assume the
# canonical /var/lib/containers/storage. Overriding the graph root produced
# "no such object <digest>"; mounting the graph elsewhere produced "Re-exec in
# host mountns: exec: No such file or directory". A bind keeps every path where
# the tools expect it and moves only the BYTES.
#
# Needed because unpacking a variant costs ~13.5GB while a live medium's root
# holds the OS — on a Steam Deck stick that is 25.9GB with the system already in
# it, so the import died with "no space left on device" after minutes of
# copying. POWOS-DATA is the rest of the device.
#
# Best-effort: on an installed system there is no media and the classic path is
# left completely untouched.
pv_media_storage_mount() {
    local store
    store=$(pv_storage_hint 2>/dev/null) || return 1
    mkdir -p "$store" 2>/dev/null || return 1
    [[ -w "$store" ]] || return 1
    mkdir -p "$POWOS_CONTAINERS_STORAGE" 2>/dev/null || true
    # Already bound (retry, or a second variant in the same session).
    findmnt -no TARGET "$POWOS_CONTAINERS_STORAGE" >/dev/null 2>&1 && return 0
    mount --bind "$store" "$POWOS_CONTAINERS_STORAGE" 2>/dev/null || return 1
    pv__log "container storage relocated onto the media ($store)" >&2
}

pv_prepare_image() {
    local want="$1" src ref
    ref="${POWOS_VARIANT_LOCAL_TAG}:${want}"

    # Already imported (e.g. a retry, or a previous install in this session).
    local _ms _g _r
    if _ms=$(pv_media_storage 2>/dev/null); then
        _g="${_ms%%|*}"; _r="${_ms##*|}"
        if podman --root "$_g" --runroot "$_r" image exists "$ref" 2>/dev/null; then
            printf '%s\n' "$ref"; return 0
        fi
    elif podman image exists "$ref" 2>/dev/null; then
        printf '%s\n' "$ref"; return 0
    fi

    src=$(pv_source_imgref "$want") || return 1
    local ms graph runroot dest
    if ms=$(pv_media_storage); then
        graph="${ms%%|*}"; runroot="${ms##*|}"
        dest="containers-storage:[overlay@${graph}+${runroot}]${ref}"
        pv__log "importing $want off the media into storage ON THE MEDIA ($graph)..." >&2
    else
        dest="containers-storage:$ref"
        pv__log "importing $want off the media into local storage (no network)..." >&2
    fi
    # Unpacked, this is ~13.5GB per variant against ~5.7GB compressed on the
    # media. A live system whose /var is small will fail here — callers should
    # relocate container storage onto the media first (see pv_storage_hint).
    skopeo copy "$src" "$dest" >&2 || return 1
    printf '%s\n' "$ref"
}

# Where container storage should live so an import has room. The media's
# @powos/containers is created by install-to-usb.sh for exactly this.
pv_storage_hint() {
    local mp
    mp=$(pv_data_mount) || return 1
    printf '%s\n' "$mp/@powos/containers"
}

# Container storage ON THE MEDIA, created if needed.
#
# Unpacking a variant costs ~13.5GB. A live medium's root holds the OS and has
# nowhere near that free — on a Steam Deck stick it is 25.9GB with the system
# already in it, so the import died with "no space left on device" after
# copying blobs for several minutes. POWOS-DATA is the rest of the device
# (terabytes on a large drive), and install-to-usb already creates
# @powos/containers for exactly this.
#
# Prints "<graphroot>|<runroot>" so callers can point both skopeo and podman at
# it. Fails (silently) when there is no writable media, leaving the classic
# behaviour untouched for a normal installed system.
POWOS_MEDIA_RUNROOT="${POWOS_MEDIA_RUNROOT:-/run/powos-containers}"
pv_media_storage() {
    local store
    store=$(pv_storage_hint 2>/dev/null) || return 1
    mkdir -p "$store" 2>/dev/null || return 1
    [[ -w "$store" ]] || return 1
    mkdir -p "$POWOS_MEDIA_RUNROOT" 2>/dev/null || return 1
    printf '%s|%s\n' "$store" "$POWOS_MEDIA_RUNROOT"
}

# Run `bootc install to-disk` for image $1 onto device $2; remaining args are
# passed through to bootc.
pv_bootc_install() {
    local image="$1" target="$2"; shift 2
    # Deliberately plain: bootc re-execs in the host mount namespace and
    # resolves its own image through the canonical storage path, so nothing
    # here may move those paths. pv_media_storage_mount has already put the
    # storage bytes on the media underneath /var/lib/containers/storage.
    podman run --rm --privileged --pid=host \
        --security-opt label=type:unconfined_t \
        -v /dev:/dev \
        -v /var/lib/containers:/var/lib/containers \
        "$image" \
        bootc install to-disk "$@" "$target"
}
