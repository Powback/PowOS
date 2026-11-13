# powos-gpu-fan: quiet fans + power cap for gpu-195's 3090s

The two ASUS RTX 3090 blowers (subsystem `1043:87b3`) stop their fans when cool, but after any load the vBIOS curve
holds them at 53-77% for minutes, and near 100% under load. NVML can't set below 30%, so this never replaces the
silent fan-stop. It only takes over when the stock curve is louder than it needs to be.

| state | fans |
|---|---|
| cool, vBIOS fans off | left alone (0%) |
| vBIOS fan faster than the curve at >= 52 C, or > 15 points above it (a stopped fan is never taken over) | curve: 30% at 50 C, 35% at 58, 50% at 65, 65% at 72, 80% at 78, 100% at 83 C; up at once, down 2%/tick with 3 C hysteresis |
| <= 47 C for 30 s | handed back to the vBIOS (fan-stop); if it spins straight up, taken back and retried after 120 s |
| >= 87 C | 100%, then the vBIOS curve until it is below 77 C |
| any NVML error, stop, crash | vBIOS curve, default power limit (also `ExecStopPost=... reset`) |

Power cap: 250 W per card (default 350 W, range 100-375 W). LLM decode is memory-bound, so it costs a few percent.

Power profiles (2026-11-09, user ask "gpu-195 runs loud"). Measured that day, read-only: GPU0 at 0% util drew
155 W at 86 C with both fans at 100% and the SM clock held at 1740 MHz (P2: voice-llm, STT and TTS contexts stay
resident, so the card can't drop to P8 or be powered down); GPU1 ran the Qwenputer loop at 63-100% util, 156-188 W,
72 C, fans 70-88%. Both cards were in SW thermal slowdown. Per card, every tick:

| profile | when | power limit | graphics clock |
|---|---|---|---|
| busy | util > `idle_util` (2%), applied on the next tick (2 s) | `power_limit_w` 250 W | uncapped |
| idle | util <= 2% for `idle_after_s` (60 s) | `idle_power_limit_w` 150 W | capped at `idle_min_clock_mhz`-`idle_max_clock_mhz` (210-1000 MHz) |
| performance | mode `performance` | driver default 350 W | uncapped |

Mode, persisted in `/etc/powos/gpu-fan-mode`: `auto` (default, the table above), `quiet` (idle profile always),
`performance` (busy at the default limit). `sudo powos-gpu-fan mode quiet`; `powos-gpu-fan mode` shows it. A card
holding resident contexts can't be powered off, so the idle profile is the power-down for a held card. Any NVML
error in the power path uncaps the clocks and keeps the busy limit; stop/reset restores default limits and clocks.

```sh
sudo bash hosts/gpu-195/gpu-fan/install.sh            # install/update, enable at boot, start (idempotent)
python3 /usr/local/bin/powos-gpu-fan status           # temps, fans, power (no root)
journalctl -u powos-gpu-fan -f                        # take-over / hand-back log
sudo bash hosts/gpu-195/gpu-fan/install.sh --remove   # back to stock
```

Tune in `/etc/powos/gpu-fan.json` (any key of `DEFAULTS` in `powos-gpu-fan`), e.g.
`{"power_limit_w": 280, "take_c": 55}`, then `sudo systemctl restart powos-gpu-fan`.

Files live in `/usr/local/bin` (= `/var/usrlocal` on Bazzite) and `/etc`, which survive rpm-ostree updates and
reboots. Registered unit: `units/gpu-195/gpu-fan.json`.
