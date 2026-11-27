# Password and passkey autofill - decision (2026-11-27)

Board task `password-and-passkey-autofill-from-powauth` (stock-parity-gaps.md row "Password / passkey autofill",
ranked gap 12). Rule it has to keep: PowAuth owns secrets; PowOS stores no credential in its own DB or plain files;
sized for ~4 devices.

## Decision

**The vault is PowPass** (`~/Projects/PowPass`, its own repo; deployed as `powpass-powpass-1`, `https://powpass.pow`,
LAN/VPN only, local CA). **PowPass's own Android app (`pow.powpass`) is the fill provider.** PowOS adds no second
vault and no second AutofillService; it shows whether PowPass fills on this phone and takes the user to the one
place that turns it on (settings tile "passwords", `system/Passwords.kt`).

Why: everything the task asked PowOS to build already exists for this vault, in the owner's own project:

| asked for | where it already is |
|---|---|
| vault behind PowAuth SSO | PowPass: sign-in through PowAuth (OIDC, PKCE; client `powpass` in `PowStation/config/authelia/configuration.yml`), master password unlocks the vault. Deployed from PowPass's branch `worktree-powpass-powauth-oidc` (11-23). |
| end-to-end encryption | PowPass "protocol 2" (`docs/ZERO_KNOWLEDGE.md` on that branch, server side started 11-26 in f26e098): `auth_key`/KEK/DEK all derived in the client, the server keeps a verifier, the wrapped DEK and ciphertext only. |
| AutofillService (apps + Chrome), save-on-submit, biometric unlock | `PowPass/android`: `autofill/PowPassAutofillService.kt`, `AutofillSaveActivity.kt`, `AutofillUnlockActivity.kt`, `ui/Biometrics.kt` + `crypto/QuickUnlock.kt`; matching rules shared with the web vault (`vault/UrlMatch.kt`: exact host for browsers, exact package for apps). |
| passkeys | `PowPass/android/credentials/PowPassCredentialProviderService.kt` (API 34+, gated at runtime; minSdk 26), WebAuthn in `passkey/WebAuthn.kt`, exact `rp_id` matching. Passkeys sync as vault items. |
| install on every phone | PowApps publishes it: `http://android.pow/apk/powpass.apk` (+ `.ver`), built by android-app-dev `make build PROJECT=powpass`. |

Building the same in the PowOS app would be a rewrite of a feature the owner already has (rule: reuse, never
reimplement; projects stay in their own repo), and Android lets exactly one autofill service and one credential
provider set be picked, so two would fight for the slot.

## Options considered

1. **Account realm secrets** (`/v1/account/secret`, 4018c5d7; `devices/AccountSecrets.kt`). Rejected. One value per
   (app, name), meant for a Hue key; AES-GCM *in the realm with the realm's key*, so the realm can read every value
   (same HACK the drop key carries, DEVICES.md "Clipboard and Send to"); plain HTTP on the LAN leg. Not a vault (no
   items, URLs, history, TOTP, passkeys, web/extension clients) and not end-to-end.
2. **Vaultwarden** (Bitwarden-compatible). Rejected. End-to-end, but a second password manager next to PowPass, a new
   server to deploy, and PowOS would have to speak Bitwarden's crypto/sync protocol or ship the Bitwarden app - which
   is not PowAuth-signed-in and owns its own accounts.
3. **PowPass** (chosen). Already deployed, PowAuth sign-in, Android autofill + passkey provider written (with
   emulator tests), end-to-end protocol designed and in progress in its own repo. Zero new server components.

## What PowOS ships (v1, this commit)

- `targets/android/app/.../system/Passwords.kt` (+ `PasswordsTest`): reads Settings.Secure `autofill_service` /
  `credential_service` (no root) and says one of: PowPass missing / installed but not picked / filling. Tap: opens
  PowPass when it fills; Android's "Passwords, passkeys & accounts" page (`android.settings.CREDENTIAL_PROVIDER`,
  API 34; all three phones are 14+) while it isn't picked - Android lets only the service's own app request to be
  picked (`ACTION_REQUEST_SET_AUTOFILL_SERVICE` is caller-package only); the PowApps store (or the APK link) while it
  is missing.
- Settings tile "passwords" (`shell/ui/screens.tsx`, state `SettingsState.passwords` from `ShellScreens.settings()`),
  findable from search ("password", "passkey", "autofill", "keychain").
- No credential, token or vault key is stored or handled by PowOS.

## Blockers - in PowPass's repo, not PowOS (for the PowPass owner/agent)

1. **The Android app can't reach the deployed server.** `net/PowPassClient.kt` talks `http://powpass.pow`; since
   84eb1ea the server answers HTTP with `307 -> https://powpass.pow/` signed by the local CA, and
   `HttpURLConnection` won't follow http->https, and the network security config trusts system CAs only. Fix in
   PowPass: base URL `https://powpass.pow` + the local CA as a trust anchor in `res/xml/network_security_config.xml`
   (pinned to `powpass.pow`), drop the cleartext exception.
2. **Protocol 2** moves item crypto to the client; the Android app must take the same `auth_key`/KEK/DEK path
   (ZERO_KNOWLEDGE.md "Order of work" step 4). Note that doc says "Android: WebView over https://powpass.pow" -
   the native AutofillService/CredentialProvider can't run in a WebView, so the native client must keep its own
   crypto (port of `web/src/lib/crypto.ts`, KATs shared) or the autofill story is lost.
3. **PowAuth sign-in on Android**: the native app signs in with username + master key; with OIDC it needs a
   Custom Tabs PKCE flow against PowAuth (client `powpass` needs an app redirect URI such as
   `pow.powpass:/oauth2redirect`). PowStation config change - owner approval, not deployed by this task.
4. PowPass main is behind its deployed branch (`worktree-powpass-powauth-oidc` not merged).

## Needs the user

- On each phone, once: Settings > passwords tile > pick **PowPass** for passwords and passkeys (Android asks the
  user; no app can pick itself silently without root/WRITE_SECURE_SETTINGS).
- Approve the PowPass work above (merge its OIDC/HTTPS branch, the Android HTTPS/CA fix, the app redirect URI in
  PowAuth). No server deploy is needed for PowOS's part.

## Next steps

- Rooted phones: PowOS could set `autofill_service` / `credential_service` itself once PowPass is installed (like
  `DefaultKeyboard` sets the IME) - only after blocker 1, or it would pick a provider that can't log in.
- Keep PowPass at its latest PowApps build the way `DefaultKeyboard` keeps the swipe keyboard (generalise that
  installer instead of copying it) once the app works against the live server.
- Linux side (Plasma/Chrome on PowOS Linux): PowPass's browser extension.
