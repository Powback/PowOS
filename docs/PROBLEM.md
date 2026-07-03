# The Windows-on-PowOS Problem — why the "seamless bare-metal Windows" ideal has a hard limit

This document exists so we stop re-deriving the same wall. It states the goal,
the invariant that constrains it, every escape route we considered, why each
fails, and the design we landed on.

## The dream

From a running PowOS, jump to Windows and back with **no reboot, no data loss,
both sessions resuming exactly where they were** — and have Windows run **kernel
anti-cheat** games (EAC/BattlEye/Vanguard, e.g. Arc Raiders) — while Windows
lives in a **single file** (no dedicated partition, never touching PowOS or
Linux partitions).

That is four wishes at once:
1. Windows resumes its session across the switch (hibernation).
2. Windows in a **file**, not a partition.
3. Anti-cheat works.
4. No reboot / instant switch.

## The invariant that breaks it

> **On one physical machine, at any instant, exactly one thing owns the hardware.**

Everything below is a consequence of this single line.

- If **PowOS is running** (to serve a disk, host a hypervisor, keep a mapping
  alive), then Windows is a **guest** → that's a VM/hypervisor → **anti-cheat
  detects it and blocks** (masking it is a ban risk, not a fix).
- If **Windows owns the metal** (anti-cheat is happy), then PowOS has handed off
  the CPU via UEFI `ExitBootServices` and is **gone** — nothing survives to serve
  a file, sustain a mount, or catch a hibernation image.

`ExitBootServices` is the specific cliff: the last thing a bootloader does before
the OS kernel takes over. It **terminates all firmware boot services**, one-way.
Any software thin enough to remain resident past it and keep faking a disk *is* a
hypervisor — which lands you back in the anti-cheat branch.

## Every escape route, and why it dies

### A. Native VHD boot + hibernation ("just enable it / patch a flag")
Windows can bare-metal boot from a VHD/VHDX file (`bootmgr` mounts it) — but
**cannot hibernate** from one. Not a policy flag:
- `winresume.efi` (the resume loader) has **no code to read a file-backed disk**.
  `bootmgr` learned to parse a VHD; `winresume` never did. Force hibernate on and
  the machine saves the image but **cannot wake** — resume can't reach
  `hiberfil.sys` through the VHD.
- Fixing it means adding VHD parsing to a **Microsoft-signed** boot binary
  (Secure Boot rejects a patched one) **and** shipping a **signed boot-start
  storage driver** that rides inside the hibernation image.
- Proof it's genuinely hard: **Microsoft ships native VHD boot, owns the source
  and the signing keys, and still didn't wire up hibernation through it.** If it
  were a flag, their own feature would use it.

### B. A PowOS "boot stage" that mounts the VHD as a disk for Windows
A UEFI driver PowOS installs can open the file and present it as a Block I/O
device — and this works for `bootmgr`/`winresume`, which do disk I/O **through
firmware services**. It dies at `ExitBootServices`: the Windows **kernel** then
talks to storage through its **own** drivers, re-enumerates real hardware, finds
only the physical USB, and can't find its boot volume →
`INACCESSIBLE_BOOT_DEVICE`. The mapping must *also* exist as a signed boot-start
kernel driver inside Windows → back to (A)'s signing wall → test-signing is
refused by anti-cheat.

### C. "PowOS serves the hdd and the Windows instance" (iSCSI / storage server)
This is exactly how datacenters do diskless Windows: a server holds the image,
Windows boots over the network with its **own signed** iSCSI driver, the server
serves storage throughout — and it can even hibernate. **It works only because
the server is a DIFFERENT machine.** On one box, "PowOS serves while Windows runs
bare metal" requires PowOS to be present during a bare-metal Windows session —
forbidden by the invariant. If PowOS stays up to serve, Windows is a guest →
anti-cheat blocks (that's just VM mode, which we already have).

### D. Custom driver to make hibernation-on-VHD work
Two signed binaries would need new code (`winresume` VHD reader + a boot-start
VHD storage driver). The only unsigned path (test-signing mode) sets a flag that
**kernel anti-cheat explicitly refuses to run under**. Dead for the one workload
bare-metal Windows exists to serve.

## The triangle (pick two)

```
        file-backed ───────── hibernation
              \                    /
               \   requires an unsigned/nonexistent
                \  driver → anti-cheat refuses
                 \                /
                  anti-cheat compatible
```

- **file + anti-cheat**  → native VHD boot, **cold boot** on metal (no resume).
- **hibernation + anti-cheat** → a **real partition** (Windows sees plain metal).
- **file + hibernation** → custom signed driver stack → **anti-cheat dies**.

No point satisfies all three. Confirmed independently by the anti-cheat vendors
(block VMs and test-signed kernels) and by Microsoft (shipped native VHD boot
without hibernation).

## What we chose — and why it's fine

**File design** (user's hard requirement: never dedicate a partition, never let
Windows touch PowOS/Linux partitions). Windows lives in a single VHDX on the
`POWOS-GAMES` NTFS partition. Its only contact with anything real is the shared
ESP (backed up before install, restorable in one command). Two run modes off the
**same file**:

| Session type | Mode | Reboot? | Session resume? |
|---|---|---|---|
| Anti-cheat games (Arc Raiders) | bare-metal native VHD boot | yes, **~20s cold** | n/a — you quit the game to switch anyway |
| Windows apps / non-AC games | VM (`powos vm windows`, `--gpu`) | **none** | ✅ instant save/restore, or hibernate in-guest |

**The entire residual cost is a ~20-second cold boot, only for anti-cheat
sessions — precisely the sessions with no live state worth resuming.** PowOS's
*own* session always survives the switch via PowOS-side S4 hibernation
(unaffected by any of the above — it's Linux writing its own RAM to swap).

Net: zero partitions sacrificed, zero pre-committed space (thin VHDX grows on
demand), Windows is one snapshottable/deletable file, seamless mode needs no
reboot, and the metal path costs 20 seconds for anti-cheat only. The partition
design's sole advantage — bare-metal hibernation — would have protected exactly
the sessions that least need it.

## If this ever changes

Only two things could reopen it, neither in our control:
- Microsoft adds VHD support to `winresume` (unlikely; they've had years).
- An anti-cheat vendor officially blesses a specific hypervisor attestation
  (some are experimenting with this) — which would make **VM mode** anti-cheat
  safe, collapsing the whole problem: then everything runs in the VM, no reboot,
  full resume, no compromise. That is the future worth watching, not a driver
  hack.

See also: `docs/WINDOWS.md` (the implementation), `docs/DUAL-BOOT-VM.md`
(reciprocal VM), `docs/HIBERNATION.md` (PowOS-side session resume).
