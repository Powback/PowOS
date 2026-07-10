# PowOS Projects — service exposure via Traefik

Every project on this box that wants a hostname (LAN-local `foo.pow` or
public `foo.powback.com`) does it the same way: add Traefik router labels
to the compose service. Nothing else is required — this box already ships:

- A rootless Traefik container on host `:80`, auto-discovering labels
  through the podman socket (see `~/Projects/PowOS/config/etc/containers/systemd/users/traefik.container`).
- A `traefik` bridge network (Quadlet-created) that both Traefik and every
  labelled service must join.
- SSH-tunneled discovery to the PowStation Pi-hole: pihole-sync there sees
  our labels and writes DNS entries pointing `foo.pow` → this host.

## Rules of engagement

- **Every routed container joins the `traefik` external network** in
  addition to its own default network. Traefik cannot proxy to a service
  it can't reach.
- **Bind ports to the container, not the host.** Traefik reaches services
  by container name on the shared network. Don't `-p 80:8080` unless the
  service also needs to be directly reachable from the LAN by IP.
- **Never claim a hostname that already exists on the LAN.** pihole-sync
  runs a hostname-collision guard: if `foo.pow` is already advertised by
  another host and you bring up a container with the same label, your
  container is auto-stopped (first-mover wins) and a webhook fires. The
  `pow-compose` wrapper (installed at `/usr/bin/pow-compose`) can pre-flight
  the check before deploy — it fails loud and refuses `up` on collision.

## LAN-only: `foo.pow` (HTTP)

Cheapest and most common. Pi-hole resolves `foo.pow` on the LAN, LAN
clients hit Traefik on this host, Traefik proxies to your container.

```yaml
services:
  my-app:
    image: whatever
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.my-app.rule=Host(`my-app.pow`)"
      - "traefik.http.routers.my-app.entrypoints=web"
      - "traefik.http.services.my-app.loadbalancer.server.port=3000"
    networks:
      - default
      - traefik
networks:
  traefik:
    external: true
```

Deploy with `docker compose up -d` (or `podman-compose up -d` — same
thing under the hood). Within ≤30 s pihole-sync on powstation writes
`my-app.pow → <this-host-IP>` into Pi-hole; LAN clients see it on their
next DNS query.

## Public with HTTPS: `foo.powback.com`

**HTTP/3 (QUIC) is on automatically** — PowStation's Traefik has `http3: {}`
on `websecure`, and every HTTPS response emits an `alt-svc: h3=":443"` header
so modern browsers upgrade to QUIC on their second connection. Zero config on
your side; falls back to HTTP/2 for older clients.

Not currently self-served from this PowOS box. The public wildcard
`*.powback.com` DNS record points at PowStation, and PowStation's
Traefik is the only one with:

- An open path from Let's Encrypt (port 80 forwarding from the router).
- The ACME `letsencrypt` cert-resolver configured.
- The `acme.json` storage volume.

So for a HTTPS `foo.powback.com` route today, one of two things has to
happen:

1. **Host the service on PowStation** — put the compose file there,
   add both the `.pow` (local HTTP) and `.powback.com` (public HTTPS)
   router labels. That's the pattern described in
   `~/Projects/PowStation/CLAUDE.md`.

2. **Reverse-proxy from PowStation to here** (TODO — not wired yet).
   The plan is:
   - pihole-sync learns to write `foo.powback.com → PowStation` even
     when the labelled container is on PowOS.
   - PowStation Traefik gets a file-provider entry that terminates TLS
     for `foo.powback.com` and forwards to `http://<powos-lan-ip>:80` +
     Host header.
   - PowOS Traefik still routes internally by Host header, so the
     backend selection remains automatic.

   When this ships, a PowOS compose can add both label pairs and both
   just work.

## WebRTC / RTC services — one line

Any service that needs a TURN/STUN server (WebRTC, remote-desktop
streamers, etc.) adds ONE line to its compose file:

```yaml
services:
  my-webrtc-service:
    env_file: /etc/powstation/turn.env
```

That injects three env vars into the container:

| Variable            | What it is                                             |
|---------------------|--------------------------------------------------------|
| `TURN_URL`          | `turn.pow:3478` (LAN-only)                             |
| `TURN_URL_PUBLIC`   | `turn.powback.com:3478` (public)                       |
| `TURN_REALM`        | `powback.com`                                          |
| `TURN_SECRET`       | HMAC-signing key for time-limited TURN credentials     |

The service code mints per-user credentials by HMAC-signing
`<username>:<expiry>` with `TURN_SECRET`, then hands the ICE config to
the browser:

```js
const pc = new RTCPeerConnection({
  iceServers: [
    { urls: `turn:${TURN_URL}?transport=udp`, username, credential },
    { urls: `turn:${TURN_URL_PUBLIC}?transport=udp`, username, credential },
  ],
});
```

The `/etc/powstation/turn.env` file gets installed on this box the
first time you ran `powos containers sync <target>` — it fetches
whatever the PowStation host is currently using. Rotating the secret
on PowStation means re-running the sync command on each PowOS box.

Bridge networking is fine — coturn is the LAN's shared TURN server, so
your service can join the `traefik` network like any other HTTP service
and route its signalling through Traefik normally. No more
`network_mode: host` unless you have another reason to need it.

## What NOT to do

- **Don't add `Host(`foo.powback.com`)` labels here yet.** They will be
  picked up by this box's Traefik (which has no cert), and the certless
  route will win over PowStation's TLS route when DNS resolves through
  Pi-hole. Wait for the split-TLS plumbing above.
- **Don't run a second Traefik on this host.** The Quadlet already
  binds `:80`; a competing Traefik will fight over the port and one
  will fail to start.
- **Don't `docker network create traefik` manually** — the `.network`
  Quadlet in the image creates it exactly the way Traefik expects.
  Manual creation with different subnet/driver options breaks things
  after a reboot.

## Debug checklist

Route doesn't work?

1. `docker inspect <container> --format '{{.NetworkSettings.Networks}}'`
   — must include `traefik`.
2. `docker exec traefik wget -qO- http://localhost:8080/api/http/routers | grep <yourname>`
   — Traefik must know about the router.
3. `dig +short foo.pow` — must return this host's LAN IP within 30 s
   of deploy. If it doesn't, check `~/Projects/PowStation`'s
   pihole-sync logs on PowStation: `docker compose logs pihole-sync`.
4. `curl -H "Host: foo.pow" http://127.0.0.1/` — proves Traefik routes
   locally. If this works but LAN clients can't reach it, DNS not the
   backend is the problem.
