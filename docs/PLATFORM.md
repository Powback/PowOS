# PowOS platform contracts

PowOS connects the owner's servers, desktops, consoles and phones; watches and XR devices can use a paired
device as their gateway. PowStation is the shared server deployment. PowAuth manages the accounts using
exposed services. Access to an application does not grant fleet administration or access to other datasets.

The executable contract is `powos.platform/v1`, implemented by `lib/apps/powos-platform`. Compose remains the
source of truth for containerized projects. Native app manifests and working GPU Quadlets stay native; their
existing PowOS units are the common inventory. Do not convert them merely to achieve one file format.

## Commands

From a project on the Mac, use `../PowStation/bin/pow-compose` (adjust the relative path for nested projects).
The wrapper calls the same adapter as `PowOS/bin/pow-compose` and `powos platform`.

```sh
../PowStation/bin/pow-compose check
../PowStation/bin/pow-compose plan --json
../PowStation/bin/pow-compose units --output /tmp/my-project-units
../PowStation/bin/pow-compose register
../PowStation/bin/pow-compose status --json
../PowStation/bin/pow-compose up -d
```

`check` and `plan` render the actual merged Compose model locally; they do not contact the Docker daemon.
`units` exports reviewed manifests. `register` writes them through the existing `powos units register` API;
it does not start containers. `status` adds live container state and reports an error if the runtime is unavailable.
`up/start/restart/run/create/unpause/scale` validate the contract, target host and LAN hostname ownership before
invoking the engine. `POW_COMPOSE_FORCE=1` bypasses only DNS collisions, never contract or target-host errors.
Read-only engine commands such as `logs`, and recovery commands such as `stop`, pass through unchanged.

Global Compose options precede the command and are included in both preflight and execution:

```sh
../PowStation/bin/pow-compose -f docker-compose.yml -f local.override.yml --profile worker check
../PowStation/bin/pow-compose -f docker-compose.yml -f local.override.yml --profile worker up -d
```

`powos compose` already means widget/app composition. Do not repurpose it for Docker Compose.

The runtime must provide Docker Compose v2 JSON config output, or Podman Compose with YAML config output and
PyYAML in its runtime. The adapter never installs dependencies. Its reports omit environment values, commands
and secret contents. A failed engine render does not echo potentially secret-bearing stderr.

## Fleet inventory

From `~/Projects`:

```sh
PowStation/bin/pow-compose fleet --manifest PowOS/config/platform-fleet.json --json
```

The manifest lists the eight adopted Compose projects. The checker detects duplicate unit IDs, duplicate
hostnames and conflicting published ports on the same declared host. It is a configured inventory, not a claim
that every service is running, and does not scan arbitrary retired projects or remote hosts automatically.
Extend the manifest deliberately. Do not add the retired Create/CCT server alongside Create 1.21 on port 25565.

## Contract shape

Keep structured policy under the **top-level** `x-pow`. The Compose version on PowStation drops per-service
extensions from JSON output, so `services.app.x-pow` cannot be the runtime source of truth.

```yaml
services:
  app:
    image: my-app
    volumes:
      - state:/data
    labels:
      io.powos.unit: my-app.app
      powos.autosleep: "never"

volumes:
  state: {}

x-pow:
  schema: powos.platform/v1
  owner: user
  host: powstation
  lifecycleAuthority: powstation-autosleep
  services:
    app:
      role: application
      lifecycle:
        policy: always
      access:
        exposure: device-local
        authentication: application
  datasets:
    app-state:
      role: state
      mounts:
        - service: app
          target: /data
      cleanup: never
      backup: required
```

`io.powos.unit` is an existing ownership label. Every service must have a unique valid ID and corresponding
`x-pow.services` entry. `register` produces matching unit records; `powos units` prefers a registered service's
unit over its legacy aggregate Compose-project row. Keep the actual Compose project name and volume names.

Every persistent mount must have exactly one dataset declaration referencing the actual service/target.
Supported roles are `state`, `durable`, `scratch`, `cache`, `source`, `secret-state`, `borrowed-state`, `derived`,
and `runtime`. A runtime mount is a socket, cgroup or similar host interface, not content storage. Borrowed
state must be mounted read-only. State, durable content, source, credentials and borrowed state require
`cleanup: never`. No role causes this adapter to delete files. Existing paths remain in place.

`backup: required` is an unresolved operational requirement, not a backup job. `existing-application-policy`
records the existing SpaceTimeAI backup path, without asserting that a current backup succeeded. A `budget`
field is advisory and explicitly reported as unenforced. There is no filesystem quota or shared reservation
manager yet. Do not interpret a Docker volume label as a quota.

## Sleep and dependencies

On PowStation, the existing controller uses `powos.autosleep.*`:

| Policy | Required runtime configuration |
|---|---|
| `always`, `job`, `application-managed` | `powos.autosleep=never`; job execution/restarts remain application-owned |
| `http-idle` | `powos.autosleep=on`, matching group/idle labels, `allownonrunning=true`, `autosleep@file` on every HTTP router |
| `follow-group` | `on`, matching group, `activity=requests`, an HTTP wake owner in the same project |

`deepSleep: off` must match `powos.autosleep.hibernate=off`. Freeze/pause retains memory. Do not advertise
CRIU recovery as working; it remains disabled by the existing controller. Healthchecks can delay wake after
pause, and direct published ports bypass the Traefik wake middleware. These constraints are unchanged.

Infrastructure, state stores, SpaceTimeAI and Android infrastructure remain protected. Minecraft needs
player/bot/world-job activity plus protocol-aware wake and save-flush handling before it may sleep. Media
needs playback/download/unpack/transcode activity. CPU idleness alone is not proof these jobs are finished.
Their contracts retain `always`/`job`; future-policy notes do not enable those features.

On PowOS container hosts the existing label is `io.powos.autosleep`; it is not interchangeable with
PowStation's labels. This adapter supports explicit `never` exclusions there and rejects portable HTTP/group
sleep policies until a tested adapter exists. Native apps retain `autosleep` manifests and the existing local
sleep daemons. GPU model pools retain application-managed unloading. Never let two controllers sleep one workload.

Dependency metadata is inventory only. It does not implement cross-project startup, leases, wake, migration
or failover. Compose `depends_on` is not a fleet dependency scheduler.

## Access and PowAuth

PowAuth is the local Authelia fork; PowStation runs `powauth:latest` as service `authelia`. Keep the existing
middleware name `authelia@docker`. Authentication and network exposure are separate dimensions.

Adopted projects use `authentication: existing` to preserve their audited application/route behavior, including
native clients and explicit bypasses. New public browser services should declare PowAuth and include the middleware:

```yaml
traefik.http.routers.my-app-pub.middlewares: authelia@docker,autosleep@file
```

For `authentication: powauth`, the adapter checks every declared HTTP router has this auth middleware and that
auth precedes wake. Use it only when every route is meant to have that policy; a mixed LAN/public service can
retain `existing` with explicit route labels. Changing `x-pow.access` never edits PowAuth ACLs or exposes a port.
Anonymous internet access needs an explicit reason. Do not broadly cache API, authenticated, streaming or
personalized responses. Do not create a PowAuth bypass solely to make an integration pass.

## Host identity and offline operation

The PowStation wrapper supplies `POW_PLATFORM_HOST=powstation` and `POW_SELF_IP=192.168.50.100`, the bridged VM's
service address. The Mac is `.99`. Other devices configure their own engine/identity in
`~/.config/pow-compose.conf` or `/etc/pow-compose.conf` (system config wins):

```sh
POW_PLATFORM_HOST=desktop
POW_SELF_IP=192.168.50.58
POW_COMPOSE_ENGINE='podman-compose'
```

These are explicit target-context declarations, not automatic verification of the selected engine's physical
machine. Set them correctly when using remote Docker contexts. Contract `host` must match for starts and
registration. Register units on the host whose registry owns the workloads; the Mac owns PowStation's Docker
inventory. Do not install PowStation service manifests into a phone's registry.

Essential boot files, runtime images, network configuration, recovery access, trust keys and selected offline
assets must be local. DNS, ingress, PowAuth and PowCDN must start without fetching their own prerequisites
from PowCDN. A central inventory outage must not stop already-running local workloads.

## PowCDN and the storage boundary

PowCDN remains unimplemented. Publication notes identify candidates; the checker rejects `powcdn.enable=true`
until there is a real controller. No CDN host, object store, NAS export, asset migration or cache allocation was
created by this integration. Follow `../../PowCDN/docs/ROADMAP.md` for the storage/backend validation work.

The NAS share named PowCache contains durable content and backups as well as caches. Never clear the whole
share. PowStorage remains off limits for Mac mounts/exports. Local scratch, Colima free space, NAS capacity
and each device's cache require separate accounting. There is no shared admission manager yet; the configured
SABnzbd and request-reconciler floors remain their existing independent checks.

## Rollout and validation

The adopted Compose files carry policy and ownership labels. Existing containers do not acquire new labels
until recreated by their normal deployment workflow. Unit manifests under `units/powstation/` are generated
review artifacts until registered; `powos platform register` performs registration without a container restart.
Never bulk-recreate DNS, ingress, authentication, game servers or databases to refresh labels.

Changes to Compose policy require `pow-compose check`, the fleet check, and refreshed generated units. Generated
manifests never contain credentials or destructive data-removal commands. Regenerate a project with:

```sh
../PowStation/bin/pow-compose units --output ../PowOS/units/powstation
```

For the adopted fleet's initial registration, run `bash PowStation/scripts/register-platform-units.sh` from
`~/Projects` on the Mac. It checks the full fleet before registering any project and does not recreate containers.
It requires write access to the Mac's PowOS unit registry. `POWOS_UNITS_DIR=/tmp/test-registry` selects an isolated
registry for testing; doing that does not activate the real host registry.

Tests: `python3 test/tier1/test-platform.py` and `python3 test/tier1/test-units-registry.py` from PowOS. The normal
tier-1 runner discovers both automatically. Runtime status, application readiness and restore tests remain
separate evidence. Historical files in `examples/platform-contract` are proposals; live project Compose files
and this document supersede their draft schema.
