# External references (PowOS)

One row per external reference used in a research doc or sent by the user. Newest first.

| date | reference | what it gave | used in |
|---|---|---|---|
| 2026-11-12 | https://github.com/ValveSoftware/wine/tree/experimental_11.0 (dlls/ntdll/unix/env.c, programs/wineboot/wineboot.c, programs/services/services.c) | first process of a session runs `wineboot --init` and waits; wineboot waits for services.exe, which signals after starting every auto-start service | broforce-engine-init.md lever 1 |
| 2026-11-12 | https://github.com/ValveSoftware/Proton/blob/experimental_11.0/proton | `waitforexitandrun` runs `wineserver -w` before the game; `run` doesn't | broforce-engine-init.md lever 1 |
| 2026-11-12 | https://github.com/dnSpy/dnSpy-Unity-mono/tree/master/unity-2017.4.7/mono/mini | Unity 2017.4.7 Mono: AOT loader hook always installed, loads `<assembly>.dll.dll` (GUID + build-info checked), Win32 AOT compiler path | broforce-engine-init.md lever 2 |
| 2026-11-12 | https://github.com/FEX-Emu/FEX (eff9f45: Config.json.in, FEXCore/include/FEXCore/Utils/SHMStats.h) | defaults of the code cache / DiskCache / SMC / TSO options; ProfileStats per-thread counters (JIT time, SMC, DiskCache hits) | broforce-engine-init.md lever 3, measurement 1 |
| 2026-11-12 | https://fex-emu.com/FEX-2610/ | disk cache 1 GB cap, in-memory buffer, prune on update; no startup numbers | broforce-engine-init.md lever 3 |
| 2026-11-12 | https://github.com/FEX-Emu/FEX/pull/6072 | (search snippet) WoW64 code-cache load fix, FEXOfflineCompiler process-all on Windows | broforce-engine-init.md lever 3 |
| 2026-11-12 | https://www.linuxcompatible.org/story/fex26111-stable-patch-ships-with-codecache-rework-and-steam-frame-crash-fix | (search snippet) FEX-2611.1 code-cache keying shared across Linux/WoW64/ARM64EC | broforce-engine-init.md lever 3 |
| 2026-11-12 | https://windowsforum.com/news/valve-enables-fex-code-cache-for-proton-on-arm-plans-steam-pre-caching.451345/ | Proton Experimental (ARM) has the FEX cache on; Steam pre-caching planned, no timetable or numbers | broforce-engine-init.md lever 3 |
