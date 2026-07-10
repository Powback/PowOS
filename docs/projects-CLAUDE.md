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

## Browser CLI — one-shot Playwright commands

The `cb-mcp-stdb` container (Powpanion-STDB compose) ships a real
command-line Playwright inside it — the same engine the MCP server drives,
but exposed as a shell CLI you can invoke for one-off jobs. No MCP, no
JSON-RPC, no SSE session bookkeeping.

The binary lives at `/app/node_modules/.bin/playwright` in the container.
Use it via `docker exec`:

```bash
# Screenshot a page (writes into the container, copy out afterwards)
docker exec cb-mcp-stdb /app/node_modules/.bin/playwright \
  screenshot --wait-for-timeout 2000 https://example.com /tmp/shot.png
docker cp cb-mcp-stdb:/tmp/shot.png ./shot.png

# Same for a PDF
docker exec cb-mcp-stdb /app/node_modules/.bin/playwright \
  pdf https://example.com /tmp/page.pdf

# Interactive record — actions get printed as Playwright JS/Python/etc.
docker exec -it cb-mcp-stdb /app/node_modules/.bin/playwright \
  codegen https://example.com
```

Handy flags on `screenshot`:

| Flag                                | Purpose                                    |
|-------------------------------------|--------------------------------------------|
| `--browser chromium\|firefox\|webkit` | Which engine (default chromium)            |
| `--viewport-size 1280,720`          | Set viewport before capture                |
| `--full-page`                       | Whole scrollable page, not just viewport   |
| `--wait-for-selector <sel>`         | Delay capture until the selector renders   |
| `--wait-for-timeout <ms>`           | Fixed sleep before capture                 |
| `--device "iPhone 15 Pro"`          | Emulate a device                           |
| `-b chromium`                       | Short form of `--browser`                  |

Full list: `docker exec cb-mcp-stdb /app/node_modules/.bin/playwright screenshot --help`.

### One-line alias

Save the friction — drop into `~/.bashrc` on any box running Powpanion-STDB:

```bash
browser() { docker exec cb-mcp-stdb /app/node_modules/.bin/playwright "$@"; }
```

Then it's just:

```bash
browser screenshot https://powpanion-stdb.pow /tmp/x.png
browser pdf https://powpanion-stdb.pow /tmp/x.pdf
browser codegen https://powpanion-stdb.pow
```

### When you actually want the MCP path

Only when you need session persistence, multi-step DOM interaction driven
by a program, or the pooled instances the MCP server manages. For "give
me a screenshot / PDF / recording of a URL," the Playwright CLI above is
faster and simpler. The MCP-over-SSE path is documented below.

## Concurrent browser (Playwright farm)


The Powpanion-STDB compose stack ships `cb-mcp-stdb` — a Chromium/Firefox/WebKit
farm behind an MCP-over-SSE endpoint. It's the fastest way to script real
browser work (headless page fetches, form fills, screenshots, DOM assertions)
from any other service on this box. Up to 25 concurrent instances.

### Endpoint

From another container on the same compose network:
```
http://cb-mcp-stdb:3000/
```

From the host once Powpanion-STDB is up (`docker compose up -d` in
`~/Projects/Powpanion-STDB`):
```
http://localhost:3000/
```

Three HTTP surfaces:

| Path | Method | Purpose |
|---|---|---|
| `/health` | GET | JSON `{status, sessions, maxSessions}` — cheap liveness |
| `/sse` | GET | Open an MCP session over Server-Sent Events. First `data:` line contains `sessionId=` |
| `/message?sessionId=<id>` | POST | Send JSON-RPC 2.0 into an existing session |

### Interactive: MCP Inspector (recommended)

```
npx @modelcontextprotocol/inspector http://localhost:3000/sse
```
Opens a browser UI on `http://localhost:5173` with a tool picker, form-based
input, and live output. Use this to figure out what tools exist and what
arguments they take — no JSON-RPC to hand-craft.

### From another compose project on this box

Point your container at the browser farm the same way any other cross-project
service is reached — via the `traefik` network + Pi-hole DNS (see the
"Rules of engagement" section for the pattern). The browser farm is a
`.pow`-resolvable service; use `cb-mcp-stdb` as the hostname on the compose
network, or configure via env:
```yaml
services:
  my-tester:
    environment:
      BROWSER_MCP_URL: http://cb-mcp-stdb:3000
    networks:
      - default
      - traefik
      - powstation_dns   # so `.pow` names resolve inside the container
```

Inside your service, use an MCP client library (`@modelcontextprotocol/sdk`
for Node, `mcp` for Python). It's the same API a Claude agent uses.

### Scripted / one-shot: raw curl

For shell scripts, the SSE + POST choreography works but is fiddly. Sketch:
```bash
mkfifo /tmp/cb.sse
curl -sN http://localhost:3000/sse > /tmp/cb.sse &
sid=$(grep -m1 'sessionId=' /tmp/cb.sse | sed 's|.*sessionId=||')

post() {
  curl -sf -X POST -H 'Content-Type: application/json' \
    "http://localhost:3000/message?sessionId=$sid" -d "$1"
}
post '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"shell","version":"0"}}}'
post '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_create_instance","arguments":{}}}'
grep -m1 '"id":2' /tmp/cb.sse   # response arrives on the SSE stream
```
Wrap in a `browser-call` helper if you use it more than twice. `mcp-inspector`
does the same choreography with a UI — worth using unless you specifically
need the shell path (CI, cron, out-of-cluster jobs).

### The tools you'll actually call

Full list is baked into `mcp-server/browser/src/tools.ts` in the
Powpanion-STDB tree (49 total in `--tools full`, 15 in `--tools agent`, ~39
in `--tools standard`). The commonly-used ones:

- **Session**: `browser_create_instance`, `browser_list_instances`,
  `browser_close_instance`, `browser_close_all_instances`
- **Navigation**: `browser_navigate`, `browser_go_back`, `browser_go_forward`
- **Interaction**: `browser_click`, `browser_click_at`, `browser_fill`,
  `browser_hover`, `browser_focus`, `browser_keyboard_press`,
  `browser_keyboard_type`, `browser_drag_and_drop`
- **Inspection**: `browser_get_page_info`, `browser_get_markdown`,
  `browser_get_element_text`, `browser_get_element_attribute`,
  `browser_get_console_logs`, `browser_get_cookies`
- **Diagnostics**: `browser_screenshot`, `browser_annotate` (highlights
  what a locator matched — great for debugging bad selectors),
  `browser_evaluate` (arbitrary JS in the page context)
- **Bookmarklets**: `browser_bookmarklet_save/list/run/delete` — persist
  a JS snippet per profile and run it later without re-uploading

Screenshots come back as base64 PNGs on the tool response — decode with:
```
jq -r '.result.content[0].data' | base64 -d > shot.png
```

### Config knobs (docker-compose command:)

Change these in `~/Projects/Powpanion-STDB/docker-compose.yml`:
```
--max-instances 25          # concurrent cap; new SSE sessions get 503 past this
--headless true             # false to see Chromium windows (needs X)
--browser chromium          # or firefox / webkit
--tools agent               # agent | standard | full — smaller surface = safer for automation
--sse-port 3000
--omniparser-url http://omniparser:8000       # optional UI-element detection sidecar
--egress-proxy-url http://egress-proxy:8080   # domain-enforcement firewall for leased contexts
```
Env-var equivalents: `OMNIPARSER_URL`, `EGRESS_PROXY_URL`, `POWPANION_URL`,
`BROWSER_MCP_TOKEN`. Set via the compose `.env`.

### Ops

- Sessions that never call `browser_close_instance` are reaped after
  `--instance-timeout` (default 30 min). `curl /health` shows the live count.
- `docker compose restart concurrent-browser` drops every open session.
- If `/health` is 503-ing, you're at `--max-instances`. Bump the flag or
  kill leaked sessions with `browser_close_all_instances`.

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
