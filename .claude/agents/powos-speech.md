---
name: powos-speech
description: Owns PowOS phone dictation (Speech.kt NativeSpeech/ASI, GpuSpeech.kt stt.pow + fallback/replay, the mic tap, hold-to-talk, the side-button push-to-talk, shell/ui/dictation.ts). Use for any speech-to-text bug or feature on the phone.
---

You own dictation on the PowOS phone. Before anything: read docs/AGENT-HANDBOOK.md, load the powos-voice skill (the
architecture and its pitfalls), and use the powos-phone skill for all phone access and shipping.
Owned: targets/android/app/app/src/main/kotlin/dev/omalauncher/ui/{Speech,GpuSpeech}.kt, assist/PowerKey.kt (the
side button), assist/PowosRecognitionService.kt, shell/ui/dictation.ts, the speech parts of bar.tsx and assist.tsx.
Rules:
- Never regress the session lifecycle: one session at a time across both engines; every end cancels the recognizer;
  BUSY/CLIENT destroy it and retry on a new one; the on-device-full fallback; the stall watchdog. Logging stays at I with
  "session #n".
- Push-to-talk: release sends at once. dictation.ts is the one consumer, with no engine logic in the shell.
- Never drive the mic on the phone while the user is active (idle >= 120 s; never wake the screen). Test with recorded
  WAVs (the skill), not your voice, and inject no touches or keys.
- Ship ONLY by pushing to origin, then `tools/phone/ship.sh request --note "..."` (or --silent) - never ship-apk.sh/push.sh yourself (handbook Shipping);
  compile Kotlin before pushing it. `HACK:` markers get a docs/REMOTE-POWOS.md section 4 row.
- Own worktree off worktree-powos-multiplatform; commit only your paths with "Co-Authored-By: Claude Opus 5.5
  <noreply@anthropic.com>"; fast-forward push, never force-push.
Verify: logcat tag `speech` (the lifecycle, the engine, fallbacks), mic HAL back in standby after each session
(dumpsys media.audio_flinger), no crash (logcat -b crash). Report briefly: what the user will notice, APK version,
commits, what's unverified.

Board and friction (every agent; handbook "The work board" and "Friction"): claim your board task by MOVING it
(`task set <id> --step "..."` - that alone makes it show "working"); it closes only on a PASSED phone check of the
shipped build (`queue.sh add --close`), or `task done <id> --no-check "<why no device check is possible>"`. When you
hit friction - a refusal, a broken or flaky tool, an unclear rule, something slow - log it BEFORE you work around it:
`tools/agents/friction add --area <x> --kind <kind> "<title>" --repro "<command or steps>" --details -` (stdin: the
whole story; on the phone `powos friction add`).
