# System-owned per-user authorized_keys

This directory is read by sshd in addition to `~USER/.ssh/authorized_keys`
(see `../sshd_config.d/50-powos-authorized-keys-dir.conf`).

## Why this directory exists

Individual PowOS installs will grant external systems SSH access for
infrastructure jobs — e.g. a PowStation host tunneling the Docker/Podman API
over SSH for its pihole-sync to discover services. Putting those keys in
`~USER/.ssh/authorized_keys` works but requires you to trust the user account
not to remove them, and there is no clean "system default" separate from a
user's own keys.

Files here are owned by root, mode 644 — the user cannot remove or alter them
without sudo, and they're easy to version-control in the image.

## Usage

To grant a caller SSH access as user `powos`, drop their pubkey at
`/etc/ssh/authorized_keys.d/powos`. The filename must match the target username.

Restrict what the key can do with `command="…"` and `restrict` options:

```
command="socat - UNIX-CONNECT:/run/user/1000/podman/podman.sock",restrict ssh-ed25519 AAAA... user@host
```

This particular restriction proxies the SSH stdio to the user's Podman
socket — nothing else. Perfect for remote Docker/Podman API access without
opening a network port.

## Do NOT ship keys inside the image

Each installation is a separate trust domain. Baking a specific pubkey into
the image would grant every PowOS install access to whoever holds the private
key. Instead, each PowOS operator installs their own key here after first boot
(one `sudo tee` command).
