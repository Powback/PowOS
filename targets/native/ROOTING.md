# Rooting the OnePlus Open — what we did, step by step

Done 2026-10-15/16 on the Mac Studio. Phone: OnePlus Open CPH2551 **EEA**, OxygenOS **16.0.5.1301 (EX01)**, Android 16,
security patch 2026-09-01, kernel 5.15.197-android13-8, active slot **b**, serial `8e5d600d`.
Result: bootloader unlocked, Magisk 30.7 root, stock OxygenOS otherwise untouched, full partition backup.
What it is for: [PLAN.md](PLAN.md). This file is the journey + the gotchas, so it can be repeated.

## 0. Before anything
- **Never downgrade** firmware, in either slot (OnePlus anti-rollback can brick; the Open's EU builds were ARB 0 at
  the time — Bartixxx32/OnePlus-antirollchecker — but don't rely on it).
- Unlocking **wipes the phone**: do it before putting anything on it.

## 1. Tools on the Mac
- `adb` from Homebrew's `android-platform-tools` works, but **its `fastboot` was killed by macOS on launch**
  (exit 137, no output — code-signing/quarantine refusal). Use Google's official platform-tools instead:
  ```
  curl -fsSL -o pt.zip https://dl.google.com/android/repository/platform-tools-latest-darwin.zip && unzip pt.zip
  ./platform-tools/fastboot --version     # 37.0.1 worked
  ```
- Plug the phone into one of the **Mac's own USB-C ports**: through the USB 2 hub, backups ran at ~12 MB/s.

## 2. Developer options
Settings → About device → tap **Build number** 7× → Developer options → **USB debugging** on, **OEM unlocking** on.
Accept the "Allow USB debugging" prompt (tick "always allow").
Check: `./phone.sh info` (model CPH2551, `ro.boot.flash.locked 1` before unlocking).
(The OEM-unlock state isn't readable over adb on OxygenOS — the bootloader tells you.)

## 3. Unlock
```
adb reboot bootloader
fastboot getvar unlocked          # no
fastboot flashing unlock
```
**Gotcha: the confirmation appears on the INNER screen.** With the phone folded nothing seems to happen. Unfold it,
volume keys to "Unlock the bootloader", power. It wipes and reboots into setup; redo step 2 (USB debugging).
Check: `ro.boot.flash.locked 0`, `ro.boot.verifiedbootstate orange`.

## 4. Stock images of the exact build
Root needs the stock `init_boot` of the **installed** build. Ways that did NOT work:
- `fastboot fetch` from fastbootd — OnePlus's fastbootd doesn't implement it.
- Oxygen Updater's API — refuses requests not from its app (403).

What worked: CruelKernel/oneplus_kernel_patcher publishes images extracted from each build. Release
`CPH2551_16.0.5.1301(EX01)` (OTA `CPH2551_11.H.23_3230_202609102312`) → `backup/8e5d600d/stock-16.0.5.1301-EX01/`:
```
gh release download 'CPH2551_16.0.5.1301(EX01)' --repo CruelKernel/oneplus_kernel_patcher \
  -p init_boot.img -p boot.img -p vbmeta.img -p vendor_boot.img -p vendor_dlkm.img -p dtbo.img
```
Trust: each matched GitHub's asset sha256, and after root `boot.img` was **byte-identical to the phone's `boot_b`**
(`07dba7ac…`). Their pre-patched Magisk image was NOT used.

## 5. Root (Magisk)
- Official Magisk from topjohnwu/Magisk (v30.7, sha256 checked against the release).
- Patched the stock init_boot **on the phone, over adb, with Magisk's own script** — no app taps:
  `tools/magisk-patch.sh Magisk-v30.7.apk stock/init_boot.img backup/8e5d600d/magisk-init_boot-16.0.5.1301.img`
  (it reported header v4, patch level 2026-09 = the phone's — a good sign the stock image is genuine).
- Flash to the **active slot** only:
  ```
  adb reboot bootloader
  fastboot flash init_boot_b backup/8e5d600d/magisk-init_boot-16.0.5.1301.img
  fastboot reboot
  adb install Magisk-v30.7.apk
  ```
- **Gotcha: open the Magisk app once — it asks for "additional setup" and a reboot.** Until then `su` isn't on PATH
  (it exists at `/debug_ramdisk/su`) and root requests fail silently.
- First root request from adb: tap **Grant** on the phone (≈10 s timeout).

## 6. Backup
```
ALL=1 ./phone.sh backup      # → backup/8e5d600d/<partition>.img + .sha256 (checked against the phone's own sha256)
```
- 133 partitions: everything except `userdata` and the raw LUN nodes (`sda`…). Includes the irreplaceable
  **persist, modemst1, modemst2, fsg** (IMEI / modem calibration — unique to this unit) and `super` (17 GiB).
- **Not `userdata`**: encrypted with keys held in the phone's TEE (gone after a wipe/relock) — a raw copy is useless.
  Use Android-level backups for user data.
- Gotchas fixed in `phone.sh`: `adb` reads stdin, so the loop stopped after the first partition (now reads the list
  on fd 3); Magisk's su path (see 5).
- The Mac was nearly full (backup ≈ 23 GiB): copy to the NAS — `~/nas/PowCache/backups/oneplus-open-8e5d600d/`
  (autofs, NOT under /Volumes) — and re-verify the checksums there.

## 7. Netflix (and other DRM apps) after unlocking
Symptom: Netflix says **"Sorry, we could not reach the Netflix service … (15001) (-93)"** — it looks like a network
error but isn't (DNS through Pi-hole resolved every Netflix name; allowing `ichnaea-web.netflix.com` and
`logs.netflix.com` there changed nothing). logcat shows the real cause:
```
QCOM-OEMCrypto: generate_derived_keys_from_wrapped_rot ... Error
WVCdm: OEMCrypto_GenerateDerivedKeys failed: status = 25
WVCdm: GetProvisioningRequestInternal] Failed to prepare provisioning request: status = 342
MediaDrm-JNI: Failed to get provision request: ERROR_DRM_GENERIC_PLUGIN
```
- **Why:** Widevine **L1** (hardware DRM in the Qualcomm TEE, `/odm/lib64/liboemcrypto.so`) is only provisioned when
  the phone proves a **locked** bootloader. The bootloader tells the TEE before Android starts; root can't change
  that. Netflix doesn't fall back to L3 by itself.
- **Fix (SD, ~480p):** hide the L1 library so Widevine uses its software **L3**: `rooted/rooted.sh widevine-l3`
  (`targets/native/widevine-l3.sh`): a bind mount of an empty file (with the library's SELinux label,
  `vendor_file`, or the HAL can't open it) over the library, installed as a Magisk post-fs-data script so it applies
  at every boot before the Widevine HAL starts. Nothing on any partition changes. Verified 2026-10-16: Netflix plays.
- **HD** needs Widevine L1 = a locked bootloader (loses root/PowOS rooted mode), or spoofing the locked state with a
  leaked OEM keybox (revoked regularly — not used).
- Undo: `rooted/rooted.sh widevine-l3 remove`.

## Undo / recover
| want | do |
|---|---|
| Netflix back to L1 attempts | `rooted/rooted.sh widevine-l3 remove` |
| remove root | `fastboot flash init_boot_b backup/8e5d600d/stock-16.0.5.1301-EX01/init_boot.img` |
| take an OTA, keep root | install the OTA, then Magisk → Install → "Install to inactive slot (after OTA)", reboot |
| restore a partition | `fastboot flash <name> backup/8e5d600d/<name>.img` (from the matching build only) |
| relock the bootloader | only after flashing ALL stock images of the installed build — relocking with modified partitions bricks; wipes the phone |
