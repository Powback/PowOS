# Debloat audit: OnePlus Open (OxygenOS 16) + PowOS rootfs

Audit of 2026-10-23, **read-only**: nothing was disabled, removed or blocked, and no Pi-hole setting was changed.
`tools/phone/debloat.sh` holds the changes as a script with a dry-run default. It has not been run. The user
decides what to apply.

Device: CPH2551, `CPH2551_16.0.5.1301(EX01)` (Android 16), rooted (Magisk), kernel `5.15.180-o-g298ff0fe2773-dirty`.
PowOS: an Arch Linux ARM chroot (`/data/powos/root`) without systemd as PID 1.

## 0. Summary

| | Android | PowOS |
|---|---|---|
| Inventory | 446 packages (417 system, 29 user; 3 already disabled) | 935 pacman packages (123 explicit, 1 orphan, 7 foreign); 25 session autostarts |
| Proposed | **30 disable, 44 uninstall-for-user-0**, 12 risky (opt-in) | **25 packages to remove (closure: 150 packages, ~800 MB)**, 3 autostarts off, baloo off, 4 "replace" items |
| RAM resident in the proposed set (PSS at audit time) | **~666 MB** (disable 564 + uninstall 102), +115 MB if the risky set is included | ~170 MB RSS of session daemons (kdeconnectd, kaccess, gmenudbusmenuproxy, baloo_file) |
| Disk | user-0 removal frees nothing on /system (the APKs stay; only dexopt and data caches go) | **~800 MB** in /usr from packages, +~775 MB more from locale/doc NoExtract (a replace item) |
| Telemetry stopped | statistics.rom, HeyTap ads and cloud-control, OAID, SAU silent installer, Facebook and Microsoft preloads | kdeconnect LAN broadcasts; a DNS leak around Pi-hole (resolv.conf `1.1.1.1`) |

**Top offenders**

| Kind | Who | Measured |
|---|---|---|
| RAM | `com.google.android.apps.wellbeing` | 166 MB PSS, resident without being used |
| RAM | OPlus "smart" stack: `pantanal.ums` (3 processes), `htms` (`:ovads` + `:cloudctrl`), `heytap.accessory`, `smartsidebar`, `assistantscreen`, `deepthinker` | 76 + 65 + 46 + 44 + 36 + 31 MB PSS |
| RAM (PowOS) | resident Steam (`powos-steam-resident`: steam + 9 steamwebhelpers) | ~1.25 GB PSS. This is a deliberate trade for instant game start (see §2.4) |
| RAM (PowOS) | plasmashell | 434 MB PSS |
| CPU at idle (Android) | WireGuard 28 % of one core, system_server 15 % | These are traffic, not bloat (powos-perf: WireGuard CPU is agents' adb and claude uploads). OEM services together use <3 % (subsys 0.6, cosa 0.4, nas 0.4, Urcc 0.9) |
| CPU at idle (PowOS) | `powos-padd` 7.3 %, Xwayland 8.8 %, steam 24 % | Measured while Broforce was open. `powos-padd` needs a re-check on a clean idle |
| Wakeups | none worth acting on | In the 5 h on battery (since the 18:05 reset): the top partial wakelock was PowOS's own `andromarchy:session` (7m56s), then SystemUI AOD 1 min. OPlus `athena` was 151 ms |
| Network/telemetry | `com.oplus.statistics.rom` | **14.3 MB uploaded in 8 days**, active in 83 of the ~96 two-hour buckets, open TLS sockets to Akamai while idle |
| Network/telemetry | HeyTap remote config `mdp-appconf-euex.heytapdl.com` | **935 DNS queries in 14 days** (~67/day) |
| Network/telemetry | Microsoft Link to Windows (`mobile.pipe.aria.microsoft.com`) | 1,836 queries in 14 days (Pi-hole already blocks it). Shared with the user's S25, see §3.1 |

**Caveats that change how to read the numbers:**
- The phone had been up for 44 minutes. batterystats covers the 5 h 15 m on battery since the 18:05 reset. CPU and wakelock
  totals are therefore short-window. netstats covers since setup (OEM apps from 2026-10-15), and Pi-hole covers 14 days.
- Broforce (Steam app 274190) was running through the PowOS sample, so the PowOS CPU numbers include it.
- PSS is a snapshot. Many of these processes are in Android's cached state and lmkd reclaims them under pressure. The
  saving is real (no restart churn, no wakeups), but the full 666 MB is not always resident.
- In Pi-hole, the OnePlus and the user's Samsung S25 Ultra share one client: both VPN peers are NATed to
  `172.30.0.3` (the WireGuard container). Domains are attributed to the OnePlus only when they are OPlus-, HeyTap- or
  OnePlus-specific, or when they came from the OnePlus's own LAN address `192.168.50.36`. See §3.

## 1. Android (OxygenOS 16)

Sources: `pm list packages -f -s|-3 -U`, `pm list packages -d|-u`, `ps -A`, `dumpsys meminfo` (PSS per process),
`dumpsys batterystats` (+ `--checkin`), `dumpsys netstats --uid --full` (per-UID bytes since setup), `dumpsys package`
(granted permissions), role holders, 12 snapshots of `/proc/net/{tcp,udp}{,6}` over 2 min (owner UID per socket),
`cpu.sh 60` (idle=786 s, screen awake), `ss -tunp` from the chroot.

**What PowOS relies on (KEEP, guarded in the script):**
- `com.android.launcher`: the gesture and recents provider. oplushook's LSPosed scope hooks into it.
- The tile targets in `QuickSettings.kt` / `control.tsx`: `com.oplus.battery`, `com.oplus.screenrecorder`,
  `com.oplus.eyeprotect`, `com.oneplus.oshare`, `com.oplus.linker`, `com.oplus.cast`, plus the Wallet and SystemUI
  controls.
- Role holders: PowOS holds HOME and ASSISTANT. Google Dialer, Google Messages, Chrome and OnePlus Gallery hold the other roles.
- Google TTS (speech), WebView/Chrome, Magisk, WireGuard, telephony/IMS (`org.codeaurora.ims`, `vendor.qti.*`,
  `com.qualcomm.qti.*`), the camera with its HAL services and `com.coloros.ocs.opencapabilityservice`, the GPU driver
  package, keyguard/AOD, and the security/permission apps (`safecenter`, `securitypermission`).
- `com.oplus.ota` stays installed. Never disable or remove it with pm (anti-rollback: an OTA has to be a deliberate act).
  Turn off auto-download in Settings > System update instead (it has already pulled 186 MB).
- `com.oplus.apprecover` stays: it is OnePlus's own way to restore removed system apps, a second undo path.

**Uninstall-for-user-0 vs disable.** `pm uninstall -k --user 0` hides the app for the user and drops its data and
dexopt output. The APK stays on `/system|/product|/my_*`, so `cmd package install-existing` restores it and a factory
reset restores everything. Neither form touches a partition, OTA, the modem, persist or EFS. Services that run as
shared uid 1000 (`com.heytap.mcs`, `crashbox`, `onetrace`, `sau*`) are only ever **disabled**, never uninstalled.

**VPN bypass found:** the OS excludes five OEM UIDs from the WireGuard VPN: `com.heytap.accessory`, `com.oplus.cast`,
`com.oplus.linker`, `com.oneplus.oshare` and `com.oneplus.backuprestore`. They use wlan0 directly. Their DNS goes to the
wlan resolvers `192.168.50.100` then **`192.168.50.1`**. The router is a second resolver, so when Pi-hole is slow,
queries bypass it. See §3.4.


#### SAFE TO DISABLE (`pm disable-user --user 0`, undo `pm enable`) - 30 packages

| Package | Vendor | What it is | Running / PSS MB | Net rx/tx MB | Why / effect of removing |
|---|---|---|---|---|---|
| `com.google.android.apps.wellbeing` | Google | Digital Wellbeing | yes, 166 | - | 268 MB RSS/heavy resident process; loses Bedtime/Focus modes and the screen-time dashboard |
| `com.oplus.pantanal.ums` | OPlus | Pantanal "fluid cloud"/smart services (3 processes incl. :track) | yes, 76 | 1.6/0.5 | ~75 MB PSS across :track/:uiSetting; usage stats |
| `com.heytap.htms` | HeyTap/OPPO | HeyTap Mobile Services (:ovads ad process, :cloudctrl remote config) | yes, 65 | 3.4/1.1 | two resident processes ~64 MB PSS; ad SDK host; breaks only HeyTap/OnePlus-account cloud features |
| `com.heytap.accessory` | HeyTap | accessory/wearables connector (excluded from VPN) | yes, 46 | - | 46 MB PSS resident, opens UDP ports, FINE_LOCATION + REQUEST_INSTALL_PACKAGES; disable if no OnePlus watch/buds |
| `com.coloros.smartsidebar` | ColorOS | Smart Sidebar (edge panel) | yes, 44 | - | 2 processes ~42 MB PSS; turn off if the edge panel is not used |
| `com.coloros.assistantscreen` | ColorOS | Shelf (left-of-home panel) | yes, 36 | - | 35 MB PSS; PowOS is home, the shelf is never shown |
| `com.oplus.statistics.rom` | OPlus | OPlus ROM statistics (DCS analytics uploader) | yes, 33 | 16.3/14.3 | top telemetry: 14.3 MB up in 8 days, ~every 2 h; holds PACKAGE_USAGE_STATS; live Akamai TLS sockets at idle; no feature depends on it |
| `com.oplus.deepthinker` | OPlus | DeepThinker: usage/location behaviour prediction | yes, 31 | - | 30 MB PSS; FINE_LOCATION + usage; feeds "smart" battery/suggestions |
| `com.heytap.mcs` | HeyTap/OPPO | HeyTap message center (OEM marketing push) | yes, 25 | 21.9/4.6 (uid 1000, shared) | OEM push only; 25 MB PSS; Google FCM unaffected |
| `com.oplus.metis` | OPlus | Metis context engine (usage + location) | yes, 13 | - | 13 MB PSS; FINE_LOCATION + PACKAGE_USAGE_STATS |
| `com.oplus.cota` | OPlus | COTA: carrier customisation over the air | yes, 12 | 0.6/0.2 | pushes carrier/region app bundles; 12 MB PSS resident |
| `com.oplus.sau` | OPlus | SAU: silent System App Update | yes, 12 | 21.9/4.6 (uid 1000, shared) | installs/updates OEM apps silently (sau-server-eu.allawnos.com); OTA itself is com.oplus.ota |
| `com.oplus.stdid` | OPlus | MSA/OAID advertising-ID provider | yes, 6 | 21.9/4.6 (uid 1000, shared) | ad identifier for HeyTap ad SDKs |
| `com.android.hotwordenrollment.okgoogle` | Google | "Ok Google" hotword enrollment | no | - | PowOS is the assistant |
| `com.android.hotwordenrollment.xgoogle` | Google | "Ok Google" hotword enrollment | no | - | PowOS is the assistant |
| `com.coloros.activation` | ColorOS | device activation/warranty reporting | no | 0.0/0.0 | phones home the activation once; nothing after setup needs it |
| `com.coloros.bootreg` | ColorOS | boot registration wizard | no | - | READ_PHONE_STATE; setup-only |
| `com.coloros.colordirectservice` | ColorOS | Color Direct / screen recognition (AI) | no | 0.1/0.0 | - |
| `com.coloros.systemclone` | ColorOS | System Clone (second space) | no | - | holds INSTALL_PACKAGES |
| `com.cota.notification` | OPlus | COTA notifications | no | - | companion of com.oplus.cota |
| `com.google.android.feedback` | Google | Google feedback reporter | no | - | - |
| `com.oneplus.account` | OnePlus | OnePlus account | no | - | only if no OnePlus/HeyTap cloud is used |
| `com.oplus.beaconlink` | OPlus | beacon link (BLE beacon scanning) | no | - | - |
| `com.oplus.crashbox` | OPlus | crash/ANR collector + uploader | no | 21.9/4.6 (uid 1000, shared) | system uid; uploads logs |
| `com.oplus.dmp` | OPlus | DMP data/search indexing platform | no | - | - |
| `com.oplus.melody` | OPlus | OnePlus Buds companion | no | - | only if no OnePlus buds |
| `com.oplus.onetrace` | OPlus | OneTrace performance tracing/uploader | no | 21.9/4.6 (uid 1000, shared) | system uid |
| `com.oplus.sauhelper` | OPlus | SAU: silent System App Update | no | 21.9/4.6 (uid 1000, shared) | installs/updates OEM apps silently (sau-server-eu.allawnos.com); OTA itself is com.oplus.ota |
| `com.oplus.stdsp` | OPlus | MSA/OAID advertising-ID provider | no | - | ad identifier for HeyTap ad SDKs |
| `com.qualcomm.qti.devicestatisticsservice` | Qualcomm | device statistics service | no | - | local stats collector |

#### SAFE TO UNINSTALL FOR USER 0 (`pm uninstall -k --user 0`, undo `cmd package install-existing`) - 44 packages

| Package | Vendor | What it is | Running / PSS MB | Net rx/tx MB | Why / effect of removing |
|---|---|---|---|---|---|
| `com.microsoft.appmanager` | Microsoft | Link to Windows (+ cross-device services) | yes, 31 | 1.0/0.2 | 31 MB PSS; in.appcenter.ms / dcg.microsoft.com / events.data telemetry; keep only if Phone Link is used |
| `com.heytap.pictorial` | HeyTap | Lock-screen magazine (wallpaper carousel with ads) | yes, 31 | 0.1/0.0 | 30 MB PSS resident |
| `com.nearme.instant.platform` | OPPO | Quick Apps (instant mini-app platform) | yes, 19 | - | 19 MB PSS resident; downloads + runs remote mini-apps |
| `com.facebook.appmanager` | Meta | Facebook App Manager / Services / Installer | yes, 15 | - | preinstalled installer: INSTALL_PACKAGES + DELETE_PACKAGES; ~20 MB PSS resident; no Facebook app installed |
| `com.facebook.system` | Meta | Facebook App Manager / Services / Installer | yes, 6 | - | preinstalled installer: INSTALL_PACKAGES + DELETE_PACKAGES; ~20 MB PSS resident; no Facebook app installed |
| `com.android.bookmarkprovider` | AOSP | easter egg / partner bookmarks / basic screensaver | no | - | - |
| `com.android.dreams.basic` | AOSP | easter egg / partner bookmarks / basic screensaver | no | - | - |
| `com.android.egg` | AOSP | easter egg / partner bookmarks / basic screensaver | no | - | - |
| `com.android.email.partnerprovider` | AOSP | easter egg / partner bookmarks / basic screensaver | no | - | - |
| `com.android.providers.partnerbookmarks` | AOSP | easter egg / partner bookmarks / basic screensaver | no | - | - |
| `com.coloros.childrenspace` | ColorOS | Kid Space | no | - | - |
| `com.coloros.compass2` | ColorOS | Compass | no | - | FINE_LOCATION |
| `com.coloros.floatassistant` | ColorOS | Quick Ball floating button | no | - | - |
| `com.coloros.ocrscanner` | ColorOS | OCR scanner | no | - | - |
| `com.coloros.operationManual` | ColorOS | user manual | no | - | - |
| `com.coloros.translate` | ColorOS | Translate | no | - | - |
| `com.coloros.translate.engine` | ColorOS | Translate | no | - | - |
| `com.coloros.video` | ColorOS | video player | no | - | - |
| `com.facebook.services` | Meta | Facebook App Manager / Services / Installer | no | 0.0/0.0 | preinstalled installer: INSTALL_PACKAGES + DELETE_PACKAGES; ~20 MB PSS resident; no Facebook app installed |
| `com.google.android.apps.bard` | Google | Gemini | no | - | optional |
| `com.google.android.apps.googleassistant` | Google | Google Assistant shell | no | - | PowOS holds the ASSISTANT role |
| `com.google.android.projection.gearhead` | Google | Android Auto | no | - | optional: keep if the car uses it |
| `com.google.ar.core` | Google | ARCore / Lens | no | 0.0/0.0 | optional; camera AR effects |
| `com.google.ar.lens` | Google | ARCore / Lens | no | - | optional; camera AR effects |
| `com.heytap.mydevices` | HeyTap | My Devices | no | - | - |
| `com.microsoft.deviceintegrationservice` | Microsoft | Link to Windows (+ cross-device services) | no | - | 31 MB PSS; in.appcenter.ms / dcg.microsoft.com / events.data telemetry; keep only if Phone Link is used |
| `com.microsoftsdk.crossdeviceservicebroker` | Microsoft | Link to Windows (+ cross-device services) | no | - | 31 MB PSS; in.appcenter.ms / dcg.microsoft.com / events.data telemetry; keep only if Phone Link is used |
| `com.oneplus.backuprestore` | OnePlus | Clone Phone (excluded from the VPN) | no | - | dormant; reinstall from Play/OnePlus if migrating |
| `com.oneplus.brickmode` | OnePlus | Zen Mode | no | - | - |
| `com.oneplus.membership` | OnePlus | Red Cable Club / membership | no | 0.4/0.1 | talks to memberapi-eu.oneplus.com |
| `com.oneplus.store` | OnePlus | OnePlus Store (shop) | no | - | - |
| `com.oplus.aimemory` | OPlus | AI Mind Space / AI Writer | no | - | - |
| `com.oplus.aiwriter` | OPlus | AI Mind Space / AI Writer | no | - | - |
| `com.oplus.appsense` | OPlus | content portal / app-suggestion feeds | no | - | recommendations ("app suggestions") |
| `com.oplus.consumerIRApp` | OPlus | IR remote app | no | - | optional: keep if the IR blaster is used |
| `com.oplus.contentportal` | OPlus | content portal / app-suggestion feeds | no | - | recommendations ("app suggestions") |
| `com.oplus.eid` | OPlus | China eID / secure-payment wallet shell | no | - | China-market features |
| `com.oplus.games` | OPlus | Games space (game launcher overlay) | no | - | PACKAGE_USAGE_STATS; PowOS has its own games; keep com.oplus.cosa (scheduler) |
| `com.oplus.logkit` | OPlus | log kit (bug-report uploader UI) | no | 21.9/4.6 (uid 1000, shared) | dormant; uploads logs on demand |
| `com.oplus.securepay` | OPlus | China eID / secure-payment wallet shell | no | - | China-market features |
| `com.oplus.upgradeguide` | OPlus | "what's new" upgrade guide | no | - | - |
| `com.oppo.quicksearchbox` | OPPO | global search (app suggestions, usage stats) | no | 0.1/0.0 | PACKAGE_USAGE_STATS; PowOS has its own search |
| `net.oneplus.forums` | OnePlus | OnePlus Community | no | - | - |
| `net.oneplus.widget` | OnePlus | OnePlus widgets | no | - | PowOS has its own widgets |

#### RISKY (not applied by default; `--risky` disables, never uninstalls) - 12 packages

| Package | Vendor | What it is | Running / PSS MB | Net rx/tx MB | Why / effect of removing |
|---|---|---|---|---|---|
| `com.oplus.phonemanager` | OPlus | Phone Manager (cleaner, privacy scan, battery pages) | yes, 57 | - | 57 MB PSS resident, PACKAGE_USAGE_STATS, opens netstats sessions; also hosts Settings pages (storage cleanup, battery) - test before keeping it off |
| `com.oplus.aiunit` | OPlus | AI unit (camera/gallery AI models), AON presence sensor | yes, 38 | 0.5/0.1 | 38 MB PSS; camera portrait/AI eraser and AON gestures use it |
| `com.oplus.athena` | OPlus | Athena background-process killer / memory manager | yes, 13 | 21.9/4.6 (uid 1000, shared) | kills background apps (PowOS session included); off = Android lmkd alone decides; watch memory behaviour after |
| `com.qualcomm.location` | Qualcomm | IZat location / XTRA GNSS assistance | yes, 6 | - | GPS fix time; may send coarse location to Qualcomm |
| `com.aiunit.aon` | OPlus | AI unit (camera/gallery AI models), AON presence sensor | no | - | 38 MB PSS; camera portrait/AI eraser and AON gestures use it |
| `com.google.android.adservices.api` | Google | Privacy Sandbox ad services / on-device personalisation (mainline APEX) | no | - | mainline modules: turn off in Settings > Privacy > Ads instead of pm |
| `com.google.android.federatedcompute` | Google | Privacy Sandbox ad services / on-device personalisation (mainline APEX) | no | - | mainline modules: turn off in Settings > Privacy > Ads instead of pm |
| `com.google.android.ondevicepersonalization.services` | Google | Privacy Sandbox ad services / on-device personalisation (mainline APEX) | no | - | mainline modules: turn off in Settings > Privacy > Ads instead of pm |
| `com.google.mainline.adservices` | Google | Privacy Sandbox ad services / on-device personalisation (mainline APEX) | no | - | mainline modules: turn off in Settings > Privacy > Ads instead of pm |
| `com.google.mainline.telemetry` | Google | Privacy Sandbox ad services / on-device personalisation (mainline APEX) | no | - | mainline modules: turn off in Settings > Privacy > Ads instead of pm |
| `com.oplus.romupdate` | OPlus | ROM update: cloud config push for many components | no | 0.1/0.1 | feature switches for battery/thermal/network come from it; off = stale defaults |
| `com.oplus.wallpapers` | OPlus | wallpaper app + downloads (258 MB downloaded) | no | 258.5/2.6 | keyguard/system wallpaper picker; set wallpapers first |

#### KEEP - 360 packages

| Group | Count | Notes |
|---|---|---|
| AOSP/OEM / resource overlay | 87 | no process; no saving; `android.auto_generated_characteristics_rro`, `android.autoinstalls.config.oneplus`, `android.connectivity.base.overlay`, `android.framework.res.rro.oneplus`, `android.frameworkres.overlay`, `android.frameworkres.overlay.Network` ... |
| OPlus / OEM system service (telephony/display/sensors/security/network glue) | 81 | left alone: system service with no tracker evidence; `com.oplus.subsys`, `com.oplus.nas`, `com.oplus.exsystemservice`, `com.oplus.powermonitor`, `com.oplus.safecenter`, `com.oplus.notificationmanager` ... |
| AOSP / core platform | 68 | `com.android.systemui`, `com.android.phone`, `com.android.wallpaper.livepicker`, `com.android.nfc`, `com.android.providers.calendar`, `com.android.keychain` ... |
| Google / GMS / Play / mainline / Google app | 47 | `com.google.android.gms`, `com.google.android.googlequicksearchbox`, `com.google.android.youtube`, `com.google.android.apps.photos`, `com.google.android.gm`, `com.google.android.calendar` ... |
| Qualcomm / modem/IMS/telephony/display/GPU stack | 25 | `vendor.qti.frameworks.utils`, `org.codeaurora.ims`, `com.qti.qcc`, `com.qti.dcf`, `com.qti.dpmserviceapp`, `com.qti.qualcomm.datastatusnotification` ... |
| user / user-installed app | 22 | user's choice; `com.powos.app`, `com.topjohnwu.magisk`, `com.swipekeyboard`, `com.wireguard.android`, `com.powapps.debug`, `com.google.android.apps.chromecast.app` ... |
| Google / Play Store, TTS (PowOS speech), Wallet tile, browser/WebView, dialer/SMS roles, keyboard | 9 | `com.google.android.webview`, `com.google.android.apps.messaging`, `com.android.vending`, `com.android.chrome`, `com.google.android.apps.walletnfcrel`, `com.google.android.tts` ... |
| OPlus / targets of PowOS quick-settings tiles | 6 | QuickSettings.kt / control.tsx use them; `com.oplus.battery`, `com.oplus.linker`, `com.oneplus.oshare`, `com.oplus.eyeprotect`, `com.oplus.cast`, `com.oplus.screenrecorder` |
| OPlus / camera + its capability service; COSA/app booster scheduler | 4 | `com.oplus.camera`, `com.oplus.cosa`, `com.coloros.ocs.opencapabilityservice`, `com.oplus.appbooster` |
| OnePlus / Notes / Recorder / Weather | 4 | user apps: user's choice (weather.service feeds the lock-screen clock widget); `com.coloros.weather.service`, `com.oneplus.note`, `com.oneplus.soundrecorder`, `net.oneplus.weather` |
| OnePlus / Calculator / Clock (alarms) / Files / Gallery (SYSTEM_GALLERY role) | 4 | `com.oneplus.calculator`, `com.oneplus.deskclock`, `com.oneplus.filemanager`, `com.oneplus.gallery` |
| OPlus / OnePlus launcher: recents + gesture provider (oplushook scope) | 1 | PowOS needs it: LSPosed hooks run inside it; `com.android.launcher` |
| Google / Files by Google | 1 | `com.google.android.apps.nbu.files` |
| OPlus / System update (OTA) | 1 | KEEP installed (anti-rollback: never side-step OTA by pm); turn off auto-download in Settings > System update; `com.oplus.ota` |

## 2. PowOS (Arch Linux ARM rootfs)

Sources: `pacman -Qe/-Qd/-Qdt/-Qm/-Qi`, `pacman -Rsp` (removal closures, print-only), `/etc/xdg/autostart`,
`/etc/systemd/{system,user}/*.wants`, a 60 s per-process CPU and RSS sample, `ss -tunp/-tulpn`, `du`, and `units/phone/*.json`.

### 2.1 What it is

- 935 packages, 123 of them explicit. 731 were installed on 2026-10-13 (the Andromarchy base install), and ~60 more
  arrived 10-15 to 10-20. There is no systemd PID 1, so the `*.wants` symlinks (sshd, networkd, resolved, timesyncd,
  getty) are inert: nothing starts them. The real starters are powos-start.sh, the supervisor, and XDG autostart.
- **The copied Fedora list:** this rootfs is not the Fedora-mapped build. `install-powos-android.sh` maps every RPM
  of the PowOS image through `phone-rules.conf`, which would add thousands of packages. The phone carries the
  Andromarchy base plus the session packages instead. No board task named "Games-first ARM manifest" was found on the
  board (`powos-agents-cli task list --all`, 2026-10-23). For that task: the remove list in §2.2 is a good seed for
  phone-rules.conf `skip@phone` lines (dev toolchains, docs, network managers, kdeconnect, lutris), so a rebuild doesn't
  bring them back.
- **Unregistered (no-unmanaged-deps rule):** 103 of the 123 explicit packages are not named in any unit's
  `packages`. `andromarchy-rootfs` covers "the rootfs" only by description. 12 KDE/GNOME autostarts have no unit
  (`baloo_file`, `kaccess`, `kdeconnectd`, `gmenudbusmenuproxy`, `xembedsniproxy`, `polkit-kde`, `powerdevil`,
  `kglobalacceld`, `plasma-fallback-session-restore`, `xdg-user-dirs`, `at-spi`, `gnome-keyring-*`). The binaries
  `powos-firstboot-{apply,disk,notice}` and `powos-virtual-display-portal` are not claimed either. The first three are
  PC-install machinery and do nothing on the phone. Proposal: after the removals, add the remaining explicit set to
  `andromarchy-rootfs.json` `packages`, so that `powos units check` covers it.

### 2.2 Packages

| Package(s) | Class | Disk freed (pacman -Rsp closure) | Why |
|---|---|---|---|
| `okular` | remove | 124 MB (50 pkgs, pulls VLC/phonon) | PDF viewer. Android has one, and nothing in PowOS uses it |
| `cmake`, `meson`(+ninja), `vulkan-headers`, `glm`, `wayland-protocols`, `xorg-font-util`, `xtrans`, `po4a`, `byacc`, `patchelf`, `python-ply` | remove | ~200 MB | dev toolchain and headers. Packages are built on the Mac (build-pkgs.sh, warm builder). `base-devel` stays for yay/makepkg |
| `lutris` | remove | 85 MB (37 pkgs) | PowOS games run through Steam/FEX. Lutris is unused on ARM |
| `mesa-docs` | remove | 49 MB | docs |
| `noise-suppression-for-voice` | remove | 49 MB | no PowOS code or speech path references it |
| `kdeconnect` | remove | 34 MB (12 pkgs) **+ 16 MB PSS resident** | phone-in-phone. It listens on UDP and mDNS on all interfaces and broadcasts on the LAN |
| `python-pip` | remove | 25 MB | uv is the installer (lib/ai/install.sh) |
| `fish`, `glow`(keep), `gum`, `yad` | remove fish/gum/yad | 41 MB | Omarchy leftovers. `glow` stays: lib/ai/clients/claude.sh renders Markdown with it when present |
| `krdp` | remove | 13 MB | KDE RDP server, never started. REMOTE-POWOS uses its own channels |
| `netctl`, `dhcpcd` | remove | 0.7 MB | Android owns the network. android-nm is the bridge |
| `mkinitcpio-busybox` | remove (orphan) | 0.5 MB | the only orphan |
| `brave-origin-bin` | **replace** | 427 MB | registered in `andromarchy-rootfs`. If the desktop's `xdg-open` goes to Android Chrome (android-request), Brave is a second browser plus its own updater. Needs the unit edited, so it is not in the script |
| `noto-fonts-cjk` | keep | (299 MB) | CJK glyphs for Steam, the browser and games. There is no smaller Arch split |
| `/usr/share/locale` 477 MB, `/usr/share/doc` 299 MB | **replace** | ~775 MB | pacman.conf `NoExtract = usr/share/locale/* !usr/share/locale/en* !usr/share/locale/de* !usr/share/locale/locale.alias` and `usr/share/doc/*`, then reinstall the affected packages. Not in the script: it rewrites many packages |
| `/var/cache/pacman/pkg` 189 MB | keep | - | the rollback copy for `debloat.sh undo` (pacman -S from cache). Also, caches are never pruned (user rule) |
| `podman`, `distrobox`, `fuse-overlayfs`, `/var/lib/containers` (533 MB) | keep | - | registered (container-runtime). Containers are in use (catatonit) |
| `flatpak` | keep | - | first-session.sh adds flathub on purpose. It costs only metadata polls (`dl.flathub.org`, 12 queries/14 d) |
| `spectacle`, `xdotool`, `wmctrl` | keep | - | `lib/mods/e2e/shot.py` uses them |
| `uv`, `pyside6`, `qmltermwidget`, `foot`, `fzf`, `tmux`, `scrcpy`, `android-tools`, Steam/FEX/box64, KWin/Xwayland-kgsl, Plasma | keep | - | registered or used by PowOS |
| KDE apps `kate`, `dolphin`, `gwenview`, `ark`, `konsole`, `systemsettings` | keep | - | the desktop mode's apps. 6-38 MB each, nothing resident |

### 2.3 Autostarts and session services (what runs at idle)

Linux session at audit time: 81 processes as the PowOS user, ~1.95 GB RSS (com.powos.app excluded). PSS of the big ones:
Steam ~1.25 GB, plasmashell 434, kwin 196, spacetimedb 95, Xwayland 75, kded6 25. There are also ~13 PowOS Python
daemons at 11-19 MB PSS each (~200 MB).

| Item | Class | RAM | Why / effect |
|---|---|---|---|
| `org.kde.kdeconnect.daemon` | off (autostart Hidden) -> remove package | 60 MB RSS / 16 PSS | see above |
| `baloo_file` | off (`balooctl6 disable`) | 30 MB RSS + 8.3 MB index | file indexer. Nothing in PowOS searches through baloo |
| `kaccess` | off (autostart Hidden) | 51 MB RSS | KDE accessibility keys (sticky keys and the like). Android owns accessibility |
| `gmenudbusmenuproxy` | off (autostart Hidden) | 26 MB RSS | GTK global-menu proxy. There is no global menu here |
| `xembedsniproxy` | keep | 24 MB RSS | Steam's tray icon (XEmbed) |
| `org_kde_powerdevil` | keep (review) | 56 MB RSS / 14 PSS | Android owns power (android-upower is the bridge). Plasma's brightness and lid hooks still talk to it. Test before removing |
| `powos-steam-resident` | keep (decision) | ~1.25 GB PSS | starts Steam silently 60 s after login, so the first game tap skips Steam's ~22 s start. It is frozen out of sight (0 CPU) but stays in RAM. Dropping it frees ~1.25 GB and costs the 22 s |
| PowOS Python daemons (android-tasks, -session-services, -system-services, -nm, -upower, ime-bridge, sleep-gui, plasma-bridge, apps-watch, sleepd, padd, supervisor, agentsd) | **replace** (later) | ~200 MB PSS together | each is a separate CPython (~11-19 MB base). Folding the event-driven ones into one process (asyncio, one interpreter) would save ~120-150 MB. That is design work, not in the script |
| `powos-padd` | keep, re-measure | 14.5 MB RSS, **7.3 % CPU** | the top PowOS CPU at "idle", but a game was open. If it stays above 1 % with nothing open, it is polling and should block on evdev instead |
| `resolv.conf`: `nameserver 1.1.1.1` after `192.168.50.100` | **replace** | - | a DNS leak around Pi-hole (plaintext to Cloudflare whenever Pi-hole is slow). Keep Pi-hole only, as the Pi-hole rule in PowStation already does. See §3.4 |

### 2.4 Expected PowOS savings

Script, `--powos` alone: ~170 MB RSS (kdeconnectd, kaccess, gmenudbusmenuproxy, baloo). With `--powos-packages`:
another ~800 MB of disk. The replace items (locale/doc, Brave, Python consolidation, Steam residency) could add
~1.2 GB of disk and 0.15-1.4 GB of RAM, depending on what the user picks.

## 3. Network & privacy

Sources: netstats per UID (since setup), 12 socket snapshots with their owner UIDs, `ss -tunp` in the chroot, Pi-hole's
FTL database (read-only `pihole-FTL sqlite3 -readonly`, the last 14 days, clients `172.30.0.3` and `192.168.50.36`),
and `dig` + Team Cymru whois (ASN, registry country) + ipinfo (geo country) for every OEM domain and every observed IP.
There is no conntrack table: the WireGuard container has no `nf_conntrack`, so connection-level logs come only from
the phone's socket snapshots.

### 3.1 How the phone's traffic flows (and why attribution is partial)

- The VPN is **split-tunnel**. tun0 routes only `192.168.50.0/24`, `10.13.13.0/24` and `172.30.0.0/24`. Internet
  traffic goes straight out of wlan0. **DNS is the part that goes through Pi-hole**: tun0's resolver is
  `172.30.0.100` for every UID in the VPN.
- Pi-hole sees the VPN as one client, `172.30.0.3` (the WireGuard container). Two peers were active, the OnePlus
  (`10.13.13.7`) and a Samsung S25 Ultra (`10.13.13.2`: Samsung, Instagram, WhatsApp, Facebook domains). **A Pi-hole
  group "for this phone only" needs the phone to have its own client address first.** Options: WireGuard without
  MASQUERADE toward the dns network (Pi-hole then sees `10.13.13.7`), or a per-peer DNS listener. That is a
  PowStation change, so it is only proposed here.
- Outside the VPN, the OnePlus's own LAN address `192.168.50.36` shows up in Pi-hole (357 queries, during VPN gaps
  and for the 5 excluded OEM UIDs).
- **PowOS's Linux traffic is attributed to Android UIDs.** The session user runs as `com.powos.app`'s UID (10359), and
  root/adb run as uid 0/2000. So PowOS's 12.5 GB upload (claude to claude-auth, agents' adb) sits under com.powos.app
  and com.android.shell. None of it is a tracker.

### 3.2 Where it talks to: OEM, third-party preloads and China flags

All OPlus/HeyTap/OnePlus endpoints the OnePlus resolved in 14 days (query counts are 14-day totals from the two clients):

| Domain | Queries | Resolves to (ASN, geo) | What it is (likely sender) | Data / frequency | Recommendation |
|---|---|---|---|---|---|
| `mdp-appconf-euex.heytapdl.com` (+`-eu`, `-ch`) | 935 + 36 + 2 | Akamai AS20940, DE | HeyTap "MDP" app config (many OPlus apps) | device model/region/app versions; ~67/day | **block** (test: OEM apps fall back to built-in defaults) |
| `cloudconf-app-ch/eu/sg.heytapmobile.com` | 113 + 33 + 1 | AWS eu-west-3 (Paris); `-sg` = **Alibaba AS45102 (CN-registered), Singapore** | HeyTap cloud control (`htms:cloudctrl`) | remote feature switches and ad config, device IDs | **block** + disable htms |
| `obus-dc-eu.heytapmobile.com`, `obus-conf-fr` | 46 + 2 | AWS Paris | OBUS: OPlus big-data upload service (statistics.rom / DCS) | usage events, app usage stats, device IDs; every ~2 h | **block** + disable statistics.rom |
| `cldata-ads-fr`, `stgdata-ads-fr.heytapmobile.com` | 7 + 7 | AWS Paris (`eu-oversea-ad-pub` ELB) | HeyTap ads SDK (`htms:ovads`, pictorial) | ad requests with OAID | **block** |
| `omes-sec.heytapmobile.com` | 9 | AWS Paris | phone-manager "security" cloud scan | installed-app list / hashes | **block** (phonemanager is risky to disable, so block its cloud instead) |
| `shorteuex.push.heytapmobile.com`, `file-intl-push.heytapdl.com`, `conn-service-eu-0{1,2,4,5}` / `-us-0{4,5}.allawnos.com` | 1 + 7 + 30 | AWS Paris / Akamai DE | HeyTap push (`heytap.mcs`): OEM marketing notifications | device token, a persistent connection | **block** + disable mcs (Google FCM `mtalk.google.com` is unaffected) |
| `sau-server-eu.allawnos.com` | 8 | AWS Paris | SAU silent system-app updater | installed versions; can install silently | **block** + disable sau |
| `icosa-service-fr-01.allawnos.com` | 43 | AWS Paris (`lagrange` gateway) | OPlus cloud service gateway (app suggestions/assistant) | app list/usage | block (test) |
| `classify-app-eu.allawnos.com` | 1 | AWS Paris | app classification (games space) | installed packages | block |
| `gateway-eu.oneplus.net`, `memberapi-eu.oneplus.com` | 20 + 19 | AWS Paris | OnePlus account, membership, store | account ID, device | block once store/membership are uninstalled; keep if a OnePlus account is used |
| `routergtest14.oneplus.com` | 10 | NXDOMAIN | an OEM network test (connectivity/router probe) | none (fails) | block (harmless) |
| `acdp-conf-sg.heytapimg.com` | 1 | Akamai DE | config CDN (SG region) | - | block |
| `icota-service-eu`, `component-ota-eu`, `module-dist-fr`, `gauss-otarecruit-eu`, `opex-service-eu`, `rus-service-eu.allawnos.com` | 18 + 5 + 2 + 2 + 2 + 4 | AWS Paris | **OTA / COTA / component and module updates**, ROM-update config | device model, firmware version | **keep** (OTA). Blocking OTA domains hides security updates and is a side door around anti-rollback decisions |
| `calculator-api-fr.allawnos.com` | 1 | AWS Paris | calculator currency rates | none | keep |
| `in.appcenter.ms`, `dcg.microsoft.com`, `mobile.events.data.microsoft.com`, `eu-mobile.events.data.microsoft.com`, `mobile.pipe.aria.microsoft.com` | 19 + 16 + 3 + 1 + 1836 | Microsoft AS8075/8068, US/IE | Link to Windows telemetry (App Center crash/analytics, Aria events). The aria count is mostly the S25 | device and usage events, frequent | uninstall the Microsoft preloads; **block** in.appcenter.ms + events.data |
| Facebook (`graph.facebook.com` 411, `edge-mqtt` 52, ...) | - | Meta AS32934, CH/IT | **the S25's** Instagram/WhatsApp. The OnePlus's Facebook UIDs moved 0 bytes | - | OnePlus: uninstall the 3 Facebook preloads. Not a DNS block (it would break the S25's apps) |

**China flags.** Nothing from the OnePlus went to a mainland-China ASN or a `.cn` domain:
- netstats and the socket snapshots show no CN destination at all.
- The two CN-registered ASNs in the log are `AS45102` Alibaba (Singapore), for `cloudconf-app-sg.heytapmobile.com`
  (1 query, the OnePlus), and `AS4812` China Telecom Shanghai, for `static-alib.licdn.cn`. The second is LinkedIn's
  China CDN, almost certainly the S25's LinkedIn app.
- `redirector.gvt1-cn.com` (82 queries) is Google's China mirror for Chrome/Play component updates. It is served
  by Google AS15169 in Zürich: Google, not OEM.
- None of `coloros.com`, `oppomobile.com`, `heytapmobi.com`, `oneplus.cn`, Baidu, Tencent, Umeng or Alibaba SDK domains
  appeared.
- **Every OEM endpoint is an OPPO/HeyTap/OnePlus property, wherever it is hosted.** The `*.cngw.heytapmobile.com` /
  `*.cngw.oneplus.net` CNAMEs are OPPO's own gateway naming, running in AWS Paris. HeyTap is OPPO's internet-services
  arm, and its EU data sits under OPPO's EU policy. Treat all of it as OEM telemetry, not as "EU-neutral".

**HTTPDNS caveat.** `com.oplus.statistics.rom` held TLS sockets to Akamai `95.100.87.161/.168` and `23.194.190.211`
during both idle samples, and none of those addresses matched a domain it resolved through Pi-hole in the window.
OPlus apps ship HTTPDNS and cached IPs. **A DNS block alone does not stop statistics.rom: disable the package.** The
same holds for anything else in the "disable" column that has its own transport.

### 3.3 Known OEM spyware and spamware on this phone

| Package | Category | What it can send / do | Evidence here | Recommendation |
|---|---|---|---|---|
| `com.oplus.statistics.rom` | analytics (DCS/OBUS) | app usage, device IDs, events | 16.3 MB rx / 14.3 MB tx since 10-15, ~every 2 h; live sockets at idle | disable |
| `com.heytap.htms` (`:ovads`, `:cloudctrl`) | ad SDK host + remote control | ad requests (OAID), remote feature switches | 3.4/1.1 MB; 2 resident processes | disable + DNS block |
| `com.oplus.stdid` / `stdsp` | advertising ID (OAID) | a resettable ad ID for every ad SDK | resident | disable |
| `com.heytap.pictorial` | lock-screen ads ("magazine") | ad impressions, wallpaper downloads | resident 31 MB | uninstall |
| `com.nearme.instant.platform` | "Quick Apps", remote mini-apps | runs downloaded code; recommendations | resident 19 MB | uninstall |
| `com.oppo.quicksearchbox`, `com.oplus.contentportal`, `com.oplus.appsense` | app recommendations ("hot apps") | usage stats, app suggestions | usage-stats permission | uninstall |
| `com.oplus.sau` / `sauhelper` | **silent installer** (system app updates) | installs and updates OEM apps without asking | sau-server-eu queries | disable |
| `com.oplus.cota` / `com.cota.notification` | carrier/region push installer | installs carrier bundles | resident | disable |
| `com.facebook.system` / `appmanager` / `services` | **silent installer** (INSTALL + DELETE_PACKAGES) | installs and updates Facebook apps, "Facebook App Manager" pings | resident, 0 bytes | uninstall |
| `com.coloros.systemclone` | holds INSTALL_PACKAGES | - | dormant | disable |
| `com.heytap.accessory` | wearables bridge, **outside the VPN** | location, REQUEST_INSTALL_PACKAGES | resident 46 MB, open UDP ports | disable unless OnePlus wearables are used |
| `com.oplus.deepthinker`, `com.oplus.metis`, `com.oplus.pantanal.ums(:track)` | behaviour profiling | location + app usage, pattern models | resident ~120 MB together | disable |
| `com.oplus.crashbox`, `onetrace`, `logkit` | log/crash uploaders | logs, which can contain identifiers | shared uid 1000 | disable / uninstall |
| `com.microsoft.*` (3) | cross-device telemetry | App Center + Aria events | 1.0/0.2 MB, telemetry domains | uninstall |
| `com.qualcomm.location` (IZat) | GNSS assist | can send coarse location to Qualcomm XTRA servers | resident 6.5 MB | RISKY: keep (GPS fix time) |
| Carrier apps | - | **none installed** (EX01 build: only `com.android.carrierconfig`, `carrierdefaultapp`, STK) | - | keep |

### 3.4 Worst offenders, ranked

By **data volume** (OEM/telemetry only; Google, the user's apps and PowOS's own traffic excluded):
1. `com.oplus.wallpapers`: 258 MB down (wallpaper downloads; content, not telemetry).
2. `com.oplus.ota`: 186 MB down (OTA package; keep).
3. `com.oplus.statistics.rom`: **14.3 MB up** (telemetry; the largest upload by far).
4. `com.oplus.uxdesign`: 9.5 MB down (theme/UI resources).
5. uid 1000 OEM services (mcs, athena, crashbox, olc, sau...): 21.9 MB down / 4.6 MB up, shared.
6. `com.heytap.htms`: 3.4 / 1.1 MB.
7. `com.oplus.cosa`: 2.9 / 0.8 MB (game-optimizer config).
8. `com.oplus.pantanal.ums`: 1.6 / 0.5 MB.
9. `com.microsoft.appmanager`: 1.0 / 0.2 MB.

By **sensitivity** (what the data can reveal):
1. `statistics.rom` / OBUS: app usage timelines + device IDs, every 2 h.
2. `deepthinker` / `metis` / `pantanal.ums:track`: location + usage behaviour models.
3. `htms:ovads` + `stdid`: ad profiling keyed by OAID.
4. Silent installers (`sau`, `cota`, Facebook system): an install channel nobody approves.
5. `omes-sec` cloud scan: the installed-app list.
6. Microsoft App Center/Aria: device + usage events.
7. `heytap.accessory`: location, outside the VPN.

**DNS leaks around Pi-hole (fix these first, or the blocklist leaks):**
- Android wlan DNS is `192.168.50.100, 192.168.50.1`. The router as second resolver bypasses Pi-hole. It applies
  outside the VPN and for the 5 VPN-excluded UIDs. Fix: DHCP option 6 on the router = Pi-hole only.
- PowOS `/etc/resolv.conf`: `192.168.50.100`, then **`1.1.1.1`**. Fix: Pi-hole only, or `127.0.0.1` via Android's
  resolver.
- Private DNS is off (`private_dns_mode` = null), which is right: DoT would bypass Pi-hole.
- HTTPDNS in OPlus apps (above): fix by disabling the packages.

### 3.5 Proposed DNS blocklist (proposal only, not applied)

For a Pi-hole group bound to the OnePlus's own client (see 3.1 for the prerequisite). Until then the same entries
could go on `192.168.50.36` (LAN). **Checked against:** OTA (all `*ota*`, `icota`, `component-ota`, `module-dist`,
`rus-service`, `opex-service`, `romupdate` hosts kept), push notifications (Google FCM `mtalk.google.com`,
`android.googleapis.com` untouched; only HeyTap's own push is blocked), the camera (no camera endpoint seen; the
camera's AI models are on-device in aiunit), the modem/IMS (carrier config arrives through the SIM/carrier
services and Google's `configupdater`; IMS entitlement goes to the carrier, not OEM hosts), and Google services
(`connectivitycheck.gstatic.com`, `remoteprovisioning.googleapis.com` for keys/Widevine attestation, `time.android.com`,
Play and GMS hosts untouched).

```
# OnePlus Open - OEM telemetry/ads (regex, Pi-hole "regex deny", group: oneplus-open)
(^|\.)obus-[a-z0-9-]+\.heytapmobile\.com$
(^|\.)[a-z0-9-]*ads[a-z0-9-]*\.heytapmobile\.com$
(^|\.)cloudconf-app-[a-z]+\.heytapmobile\.com$
(^|\.)mdp-appconf-[a-z]+\.heytapdl\.com$
(^|\.)omes-sec\.heytapmobile\.com$
(^|\.)[a-z0-9-]*push\.heytapmobile\.com$
(^|\.)file-intl-push\.heytapdl\.com$
(^|\.)conn-service-[a-z]{2}-[0-9]+\.allawnos\.com$
(^|\.)sau-server-[a-z]+\.allawnos\.com$
(^|\.)icosa-service-[a-z0-9-]+\.allawnos\.com$
(^|\.)classify-app-[a-z]+\.allawnos\.com$
(^|\.)acdp-conf-[a-z]+\.heytapimg\.com$
(^|\.)routergtest[0-9]*\.oneplus\.com$
# only after com.oneplus.store/membership are uninstalled and no OnePlus account is used:
(^|\.)memberapi-[a-z]+\.oneplus\.com$
(^|\.)gateway-[a-z]+\.oneplus\.net$
# Microsoft Link to Windows telemetry (exact)
in.appcenter.ms
dcg.microsoft.com
mobile.events.data.microsoft.com
eu-mobile.events.data.microsoft.com
```

**Keep (never block for this phone):** `icota-service-*`, `component-ota-*`, `module-dist-*`, `gauss-otarecruit-*`,
`opex-service-*`, `rus-service-*`, `calculator-api-*` (`*.allawnos.com`), `image01.oneplus.net` (OnePlus image CDN,
harmless), every `*.googleapis.com` / `*.gstatic.com` / `mtalk.google.com` / `time.android.com`, `vpn.powback.com`,
`*.pow`.

### 3.6 Feed for the app-api tracker blocking (docs/APP-API-CAPTURE.md §1b.13, `tools/app-api/appcap_block.py`)

These belong in its seed lists as `tracker`/`analytics` hosts (per-flow blocking catches what DNS can't: HTTPDNS
connections still carry SNI). Domains: the regex block above, plus the host IPs statistics.rom uses without DNS
(Akamai `95.100.87.161`, `95.100.87.168`, `23.194.190.211`: SNI needed, since Akamai shares IPs). Per-app tags:
`com.oplus.statistics.rom` = analytics, `com.heytap.htms` = ads + remote-config, `com.heytap.mcs` = OEM push,
`com.oplus.sau` = silent-installer, `com.microsoft.appmanager` = analytics, `com.facebook.system` = installer.
Mark `*.allawnos.com` OTA hosts and Google's push/attestation hosts as `functional`. Sent to the app-api agent
(powos comms) with a pointer to this section.

## 4. The script: `tools/phone/debloat.sh` (not run)

```
tools/phone/debloat.sh                      # = plan: dry run, prints every adb/pacman command, changes nothing
tools/phone/debloat.sh plan --risky         # the plan with the risky set too
tools/phone/debloat.sh apply                # Android: the 30 disables + 44 user-0 uninstalls
tools/phone/debloat.sh apply --keep com.microsoft.appmanager,com.oplus.consumerIRApp
tools/phone/debloat.sh apply --only disable # disables only
tools/phone/debloat.sh apply --powos        # PowOS: autostarts off + baloo off
tools/phone/debloat.sh apply --powos --powos-packages   # + pacman -Rs of the §2.2 set
tools/phone/debloat.sh undo                 # reverses the newest record exactly
tools/phone/debloat.sh status               # enabled/disabled/removed for every listed package
```

- Records go to `~/.local/state/powos-debloat/<UTC>.state`, one line per change actually made. `undo` reverses only
  those lines: `pm enable`, `cmd package install-existing`, deleting the Hidden autostart overrides,
  `balooctl6 enable`, and `pacman -S --needed` of the removed closure (from the pacman cache).
- It refuses while the phone is in use (idle < 120 s, `tools/phone/idle.sh`) unless `--now`.
- A guard list refuses PowOS's dependencies even if someone adds them to a list (launcher, OTA, telephony,
  SystemUI, GMS, WebView, TTS, the tile targets, the camera, WireGuard, Magisk, PowOS itself).
- Only `pm disable-user/enable/uninstall -k --user 0/install-existing` and the PowOS commands above. No firmware, no
  partition, no `/system` write, no Pi-hole change.
- Suggested order: `apply --only disable`, live with it a day, then `apply --only uninstall`, then the risky set one
  package at a time (`--risky --keep <the others>`).

## 5. Follow-ups (not done here)

- Give the OnePlus its own Pi-hole client identity (PowStation/WireGuard), then load §3.5 as a group.
- Router DHCP DNS = Pi-hole only. PowOS resolv.conf: drop `1.1.1.1`.
- Re-measure `powos-padd` with nothing open. If it is polling, make it block on evdev.
- `andromarchy-rootfs.json`: list the explicit packages that remain after debloating. Seed `phone-rules.conf`
  `skip@phone` with the §2.2 removals, so a rebuild doesn't bring them back.
- Decide on Steam residency and Brave (unit edits).
