# shellcheck shell=bash
# GATE_REMOTE=<ssh host> (sourced by dev/gate.sh and dev/preview.sh): the gate's headless-Chromium runs - the scene run
# (gate.mjs) and the widget sweep's browser passes (preview.mjs) - go to an idle LAN box instead of the Mac, whose CPU
# is the agents' (11-01: the full ship gate took 780-952 s at Mac load 15-20, 36% of ship gates failed under load).
# Same image and tag (the remote's native arch: amd64 on the x86 boxes), same command, same env; the output streams
# back over ssh and the exit status is the container's, so gate.sh's retry, summary and "gate: pass" are unchanged.
# tsc and the lints stay local (light, and they need shell/node_modules).
#   The remote keeps, under ~/.cache/powos-gate-remote: run/<slot>/ (the composed shell, rsynced per run - a delta, the
#   slot's dir is reused so it stays warm), tx/ (gate.mjs's transpile cache, shared, kept between runs) and the image.
#   Registered on the remote as unit powos-gate-remote (units/gpu-58/powos-gate-remote.json -> ~/.config/powos/units.d).
# Unreachable (ssh BatchMode, 5 s) -> the gate runs locally and says so. Non-interactive ssh keys only.
#   GATE_REMOTE=powos@192.168.50.58   the 9950X3D box (32 threads, idle most of the day)
#   GATE_REMOTE=0 / unset             local, as before
GR_HOST="" GR_ROOT=".cache/powos-gate-remote" GR_PLATFORM="" GR_IMAGE="" GR_PREFIX=""
GR_SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

# gr_init IMAGE: GR_HOST set when the remote answers and has the image; else empty (local) with a line saying why.
gr_init() {
  local want=${GATE_REMOTE:-} arch
  [ -n "$want" ] && [ "$want" != 0 ] || return 0
  if ! arch=$(perl -e 'alarm 15; exec @ARGV' "${GR_SSH[@]}" "$want" uname -m 2>/dev/null); then
    echo "gate: remote $want unreachable - running locally"; return 0
  fi
  case $arch in x86_64) GR_PLATFORM=linux/amd64 ;; aarch64|arm64) GR_PLATFORM=linux/arm64 ;; *) GR_PLATFORM="" ;; esac
  # podman (the PowOS boxes) refuses short names without a TTY: the fully qualified name of the same image.
  case $1 in */*/*) GR_IMAGE=$1 ;; */*) GR_IMAGE=docker.io/$1 ;; *) GR_IMAGE=docker.io/library/$1 ;; esac
  local unit; unit=$(dirname "${BASH_SOURCE[0]}")/../../units/gpu-58/powos-gate-remote.json
  if ! perl -e 'alarm 300; exec @ARGV' "${GR_SSH[@]}" "$want" "mkdir -p $GR_ROOT/run $GR_ROOT/tx ~/.config/powos/units.d &&
      find $GR_ROOT/tx -type f -mtime +7 -delete 2>/dev/null; find $GR_ROOT/run -mindepth 1 -maxdepth 1 -name 'ship.*' -mmin +120 -exec rm -rf {} + 2>/dev/null;
      docker image inspect $(printf %q "$GR_IMAGE") >/dev/null 2>&1 || docker pull -q $(printf %q "$GR_IMAGE") >/dev/null" 2>/dev/null; then
    echo "gate: remote $want couldn't prepare (no docker/podman or no image) - running locally"; return 0
  fi
  [ -f "$unit" ] && rsync -q -e "${GR_SSH[*]}" "$unit" "$want:.config/powos/units.d/" 2>/dev/null || true
  GR_HOST=$want
  echo "gate: remote: browser runs on $GR_HOST ($GR_PLATFORM)"
}

# gr_push SRC DEST [rsync args]: SRC (a dir: its contents) to ~/GR_ROOT/DEST on the remote, mirrored.
gr_push() {
  local src=$1 dest=$2; shift 2
  perl -e 'alarm 300; exec @ARGV' "${GR_SSH[@]}" "$GR_HOST" "mkdir -p $GR_ROOT/$(dirname "$dest")" &&
    if [ -d "$src" ]; then rsync -a --delete "$@" -e "${GR_SSH[*]}" "$src/" "$GR_HOST:$GR_ROOT/$dest/"
    else rsync -a "$@" -e "${GR_SSH[*]}" "$src" "$GR_HOST:$GR_ROOT/$dest"; fi
}
# gr_pull SRC DEST: ~/GR_ROOT/SRC (a dir) back into DEST, mirrored.
gr_pull() { rsync -a --delete -e "${GR_SSH[*]}" "$GR_HOST:$GR_ROOT/$1/" "$2/"; }

# gr_run NAME ARGS...: `docker run --rm ARGS` on the remote as container NAME, its output here, its exit status ours.
# A remote path in a -v is written @/rel (under GR_ROOT). Names start with GR_PREFIX (set by the caller, in the shell
# that will clean up: gr_run often runs in a pipeline's subshell) so an interrupted gate's containers are removed
# (gr_cleanup), not left running on the remote.
gr_run() {
  local name=$1 a out=() home; shift
  home=$(perl -e 'alarm 15; exec @ARGV' "${GR_SSH[@]}" "$GR_HOST" 'echo $HOME') || return 2
  for a in "$@"; do out+=("${a//@\//$home/$GR_ROOT/}"); done
  # keep-id: the image's user (chrome, 1000) is the remote user, so it can write /cache; label=disable: SELinux.
  perl -e 'alarm 3600; exec @ARGV' "${GR_SSH[@]}" "$GR_HOST" "$(printf '%q ' docker run --rm --name "$name" --userns keep-id \
    --security-opt label=disable ${GR_PLATFORM:+--platform "$GR_PLATFORM"} "${out[@]}")"
}
gr_cleanup() {
  [ -n "$GR_HOST" ] && [ -n "$GR_PREFIX" ] || return 0
  perl -e 'alarm 30; exec @ARGV' "${GR_SSH[@]}" "$GR_HOST" \
    "docker ps -aq --filter name=^$GR_PREFIX | xargs -r docker rm -f >/dev/null 2>&1; true" 2>/dev/null || true
}
