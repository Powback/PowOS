#!/bin/bash
# containers-sync.sh — sync PowOS↔PowStation container discovery.
#
# WHAT THIS DOES (whole flow in one place, no manual steps)
#
# PowStation runs an infrastructure Traefik + Pi-hole + pihole-sync stack. Its
# pihole-sync watches Docker labels on any host you register via
# REMOTE_DOCKER_HOSTS and creates DNS entries so `service.pow` on your LAN
# resolves to the correct host. To watch this PowOS box, powstation's
# pihole-sync needs to reach the local podman socket — but exposing an
# unauthenticated TCP socket over the LAN is a full-container-control CVE
# waiting to happen. Instead we tunnel the Docker API over SSH with a
# purpose-locked key (see sshd_config.d/50-powos-authorized-keys-dir.conf).
#
# This script wires up both ends idempotently:
#   1. Verifies SSH access to <powstation-target> works with the user's
#      existing keys.
#   2. Ensures powstation has a pihole-sync keypair at
#      ~/Projects/PowStation/pihole-sync/config/id_pihole_sync_ed25519.
#      Generates one if missing.
#   3. Fetches the pubkey and installs it at /etc/ssh/authorized_keys.d/$USER
#      on this PowOS box, restricted to `socat` forwarding to the user podman
#      socket — no shell, no port forwarding. The key can ONLY be used to run
#      Docker/Podman API calls.
#   4. Reloads sshd.
#   5. Updates powstation's .env to include this host in REMOTE_DOCKER_HOSTS.
#   6. Restarts pihole-sync so it picks up the new host immediately.
#
# The key restriction is command="socat - UNIX-CONNECT:$SOCKET",restrict
# which forces every SSH invocation with that key to run exactly one command
# regardless of what the client asks for. See sshd_config(5) AUTHORIZED_KEYS.
#
# Everything is idempotent — safe to run repeatedly. Rerun after a powstation
# key rotation to install the new pubkey.

set -euo pipefail

# Path under $HOME on the target machine to the PowStation working tree.
POWSTATION_TREE="${POWSTATION_TREE:-Projects/PowStation}"

cmd_containers_sync() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        cat >&2 <<USAGE
Usage: powos containers sync <user@powstation-host>

Wires up this PowOS box so PowStation's pihole-sync discovers its
Traefik-labeled containers via SSH-tunneled Docker API. No manual key
handling needed — the script does both ends.

Example:
  powos containers sync macback@192.168.50.100

Environment:
  POWSTATION_TREE  Path under \$HOME on the target to the PowStation working
                   tree. Default: Projects/PowStation.
USAGE
        return 1
    fi

    local user="${USER:-$(id -un)}"
    local self_host
    self_host=$(hostname -I | awk '{print $1}')
    local self_name
    self_name=$(hostname -s)
    local key_dir="\$HOME/$POWSTATION_TREE/pihole-sync/config"
    local key_file="\$HOME/$POWSTATION_TREE/pihole-sync/config/id_pihole_sync_ed25519"

    echo "→ Verifying SSH access to $target..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$target" true 2>/dev/null; then
        cat >&2 <<HELP
✗ Cannot SSH to $target with the current user keys.
  Set up passwordless SSH first, then re-run:
    ssh-copy-id $target
HELP
        return 2
    fi

    echo "→ Ensuring pihole-sync keypair exists on powstation..."
    ssh "$target" bash -s "$POWSTATION_TREE" <<'REMOTE_EOF'
set -euo pipefail
tree="$1"
key_dir="$HOME/$tree/pihole-sync/config"
mkdir -p "$key_dir"
chmod 700 "$key_dir"
if [[ ! -f "$key_dir/id_pihole_sync_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N "" -C "pihole-sync@$(hostname -s)" -f "$key_dir/id_pihole_sync_ed25519"
    echo "  generated new pihole-sync keypair on powstation"
fi
gi="$key_dir/.gitignore"
grep -qxF id_pihole_sync_ed25519 "$gi" 2>/dev/null || printf 'id_pihole_sync_ed25519\nknown_hosts\n' >> "$gi"
REMOTE_EOF

    echo "→ Fetching pubkey from powstation..."
    local pubkey
    pubkey=$(ssh "$target" "cat \$HOME/$POWSTATION_TREE/pihole-sync/config/id_pihole_sync_ed25519.pub")
    if [[ -z "$pubkey" ]]; then
        echo "✗ Empty pubkey received from powstation" >&2
        return 3
    fi

    # Rootless podman socket for this PowOS user.
    local podman_sock="/run/user/$(id -u)/podman/podman.sock"
    local restricted='command="socat - UNIX-CONNECT:'"$podman_sock"'",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty,restrict '"$pubkey"

    echo "→ Installing pubkey to /etc/ssh/authorized_keys.d/$user (restricted to podman socket)..."
    local akd="/etc/ssh/authorized_keys.d"
    local akf="$akd/$user"
    sudo mkdir -p "$akd"
    local pubkey_base
    pubkey_base=$(echo "$pubkey" | awk '{print $2}')
    if [[ -f "$akf" ]] && sudo grep -qF "$pubkey_base" "$akf" 2>/dev/null; then
        sudo sed -i "\|$pubkey_base|d" "$akf"
    fi
    echo "$restricted" | sudo tee -a "$akf" >/dev/null
    sudo chmod 644 "$akf"

    echo "→ Reloading sshd..."
    sudo systemctl reload sshd

    echo "→ Registering this host ($self_name) in powstation's REMOTE_DOCKER_HOSTS..."
    ssh "$target" bash -s "$POWSTATION_TREE" "$user" "$self_host" "$self_name" <<'REMOTE2_EOF'
set -euo pipefail
tree="$1"; u="$2"; ip="$3"; name="$4"
envfile="$HOME/$tree/.env"
touch "$envfile"
entry="${name}=ssh://${u}@${ip}"
current=$(grep -E '^REMOTE_DOCKER_HOSTS=' "$envfile" | tail -1 | cut -d= -f2- | tr -d '"' || true)
# strip any prior entry with the same name= to make the operation idempotent
new=$(echo "$current" | tr ',' '\n' | grep -v "^${name}=" | paste -sd, -)
if [[ -n "$new" ]]; then
    new="$new,$entry"
else
    new="$entry"
fi
sed -i.bak '/^REMOTE_DOCKER_HOSTS=/d' "$envfile"
rm -f "$envfile.bak"
echo "REMOTE_DOCKER_HOSTS=\"$new\"" >> "$envfile"
echo "  set: REMOTE_DOCKER_HOSTS=\"$new\""
REMOTE2_EOF

    echo "→ Writing /etc/pow-compose.conf so pow-compose knows where to check DNS..."
    # pow-compose uses this to SSH into powstation for DNS lookups when the
    # local resolver doesn't know .pow (i.e. every fresh PowOS box).
    echo "POW_STATION_HOST=\"$target\"" | sudo tee /etc/pow-compose.conf >/dev/null
    sudo chmod 644 /etc/pow-compose.conf

    echo "→ Restarting pihole-sync on powstation..."
    ssh "$target" "cd \$HOME/$POWSTATION_TREE && docker compose up -d pihole-sync" 2>&1 | tail -5

    cat <<DONE

✓ Done. This PowOS box's labeled containers will show up in powstation's
  pihole-sync as DNS entries pointing to $self_host.

  Tail powstation's sync log to watch discovery:
    ssh $target 'cd $POWSTATION_TREE && docker compose logs -f pihole-sync'
DONE
}
