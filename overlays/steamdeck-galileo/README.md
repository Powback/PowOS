# Steam Deck Galileo (OLED) Overlay — UNPORTED

**Status: not buildable.** This directory is content-only reference material
for a Steam Deck OLED hardware overlay (package list, pipewire/wireplumber
workaround services, DMI match metadata). It belonged to the legacy
`overlays/` build system (Makefile + `build-overlay.sh` +
`detect-and-enable.sh`), which has been removed — nothing built or consumed
these files, and `build.sh` (a shim to the deleted generic builder) was
removed with it.

The live overlay mechanism is `sources/<name>/` built by
`lib/overlay-manager.sh` (systemd-sysext). To resurrect Steam Deck support,
port this content to a `sources/steamdeck-galileo/` entry with a `source.conf`
and `build.sh`, and wire the DMI match (`DMI_MATCH="Galileo"` in
`metadata.env`) into hardware detection (`lib/hardware-detect.sh` /
`config/profiles/`).
