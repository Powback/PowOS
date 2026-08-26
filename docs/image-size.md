# Image size: what is stripped, what is optional, what must never go

## Build args

| arg | default | effect |
|---|---|---|
| `POWOS_LOCALES` | `en_US nb_NO` | keep only these languages. `""` keeps all 700. **886M → 454M** |
| `POWOS_ICON_THEMES` | `""` | empty = derive from look-and-feel defaults (**205M → 165M**). Set = YOUR list is authoritative, reference union skipped (**→ 111M**). `hicolor`/`breeze_cursors`/`Adwaita` are a floor in both modes |
| `POWOS_EXTRAS` | `""` | packages to `rpm -e`. Removes nothing unless set |
| `POWOS_BREW` | `bundled` | `fetch` drops the 126M payload — **but there is no runtime re-add yet**, see below |

Applied unconditionally: `/usr/share/doc`, `man`, `help`, unreferenced wallpapers
(**−532M**). Deck-only: `nvidia`/`intel`/`i915` firmware (**437M → 203M**).

Total ≈ **1.36 GB**.

## DO NOT STRIP

Everything here looked removable and was not. Each cost real debugging, and the
evidence was always one command away.

| | why |
|---|---|
| `ath10k` firmware | **the wifi.** LCD Deck (Jupiter) = Qualcomm Atheros QCA6174 |
| `qcom` firmware | OLED Deck (Galileo) = WCN6855 |
| `rtl_nic` firmware | **USB-C dock ethernet** (Realtek RTL8153). A docked Deck needs it |
| `mediatek` firmware | MediaTek USB adapters. "The Deck has no MediaTek silicon" is true of built-in hardware and irrelevant to what gets plugged in |
| `llvm15` (198M) | **OpenCL's pinned toolchain.** `libRusticlOpenCL`, `libopencl-clang`, `libLLVMSPIRVLib`, `libigc` all load it by path. Unowned by rpm and `--whatrequires` shows nothing, because they `dlopen` it |
| `libwebkit2gtk-4.1` (90M) | **required by Lutris** |
| `hicolor` icons | `breeze` declares `Inherits=hicolor`. Removing it breaks icon lookup everywhere, not just one theme |
| `breeze_cursors`, `Adwaita` | cursor theme; GTK fallback. A KDE-only keep-list misses both |
| CJK fonts (409M) | renders Japanese/Chinese **Steam titles** |
| `locale` C / POSIX | the fallback every program lands on |
| `godot-runner` | has a reverse dependency. `rpm -e` refuses it; a `rm` would not have |

## The rule

**`rpm -e`, never `rm`.** rpm refuses when something depends on the package, and
takes its systemd units with it. Deleting a binary leaves its units pointing at
nothing — a failed unit every boot. `tailscale` ships three.

**"Nothing references it" has been wrong six times here.** grep and
`rpm -q --whatrequires` both miss `dlopen`, unpackaged trees, and runtime paths.
Verify by removing it and booting, not by reading metadata.

## Homebrew has no re-add path yet

`POWOS_BREW=fetch` drops the payload, but `lib/install-router.sh` only probes
`command -v brew` — nothing installs it. So `powos install -m brew <pkg>` simply
reports brew unavailable, permanently. Default is therefore `bundled` until
`ensure_brew()` exists.

Contrast `POWOS_EXTRAS`, which is safe precisely because its targets are rpm
packages: `powos install cosign` genuinely restores them.

## Not removable

`lto-dump` (39M) belongs to `gcc`. `bun` (77M) is unowned by any package.

## Testing

`test-image-invariants.sh` runs **inside a built image** and asserts on the
filesystem: firmware that must survive, `hicolor`, locale fallback, sleep-policy
coherence, and that no enabled unit points at a missing binary.

Prefer it over the Containerfile-grep tests (`test-firmware-trim`,
`test-sleep-policy`, `test-image-trim`). Those assert the right text was typed,
which is not the same as the build having done it — a `RUN` that silently no-ops
leaves them green. It caught a real orphan the moment it was written.

## Verify

```bash
# what a build actually did — each trim prints one line
grep -E '^(sleep|firmware|locales|icons|brew|extras):' /var/tmp/fb-image.log

# what a built image contains
podman run --rm --entrypoint /bin/bash <image> -c 'du -sh /usr/share/* | sort -rh | head'
```

The build fails loudly if `amdgpu`, `ath10k`, `qcom` or `hicolor` went missing,
or if a tailscale unit survived without its binary.
