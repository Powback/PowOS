# PowOS AI as the phone's assistant

Goal: holding the power button opens PowOS AI as an overlay on top of the current app, the way Gemini does
today, with the same abilities: it sees and understands the screen, lets you draw or circle a region to crop it,
shares the screen live, and talks (voice in and out). It is built on the platform's own assistant slots, not on
accessibility hooks or Google code. This doc covers how the slot works on the OnePlus Open, how Gemini fills it
(read as a reference for the platform APIs, nothing copied), the PowOS design, and the order to build it in.

Device: OnePlus Open CPH2551, OxygenOS 16 (Android 16, SDK 36), Magisk root. Evidence: read-only `dumpsys`,
`settings get`, `cmd role`, `cmd overlay lookup`, `pm list permissions -f`, `aflags list`, and jadx decompiles
of the device's `services.jar`, `oplus-services.jar`, `SystemUI.apk`, GooglePermissionController, the Google app
(`com.google.android.googlequicksearchbox`, "GSA") and Gemini (`com.google.android.apps.bard`). The pulled files
and decompiles stayed in a local tmp directory and are not in git. Researched 2026-10-19.

The UI rule from [NATIVE-SYSTEM-UI.md](NATIVE-SYSTEM-UI.md) holds here too: the assistant overlay is the web
shell (`shell/`, `ui/powai.tsx`) in a thin native host. Kotlin holds the role, the session window, the
screenshot, the mic and the projection, and nothing else.

## TL;DR

- **Long-press power is already "assistant" on this phone.** `config_longPressOnPowerBehavior=5`
  (`LONG_PRESS_POWER_ASSISTANT`, 500 ms). PhoneWindowManager → `SearchManager.launchAssist` → SystemUI
  `AssistManager` → `VoiceInteractionManagerService.showSessionForActiveService(flags = source | SHOW_WITH_ASSIST |
  SHOW_WITH_SCREENSHOT)`. Whoever holds the **`android.app.role.ASSISTANT`** role with a VoiceInteractionService
  gets that call. Today the holder is GSA.
- **On OnePlus it has to be a VoiceInteractionService, not just an `ACTION_ASSIST` activity.** OnePlus's SystemUI
  (`AssistManagerImpl.beforeStartAssistInternal`) reads the raw `Settings.Secure.assistant` component. If that is
  empty, which it is for an assistant that is activity-only, it logs `opAssistPicker is empty!` and does nothing.
  PowOS's current `ACTION_ASSIST` filter on `PowosAiActivity` is therefore not enough for the power button.
- **The role qualifies a VIS only with `sessionService` + `recognitionService` + `supportsAssist=true`** in its
  `android.voice_interaction` metadata, and the service must be guarded by `BIND_VOICE_INTERACTION`
  (PermissionController `AssistantRoleBehavior.isAssistantVoiceInteractionService`). So PowOS needs three
  services: VIS, SessionService and a RecognitionService (a thin delegate is enough).
- **Screen understanding is free with the role.** `onHandleAssist` delivers AssistStructure + AssistContent, and
  `onHandleScreenshot` delivers a Bitmap (both settings are unset, so they default to on). No privileged permission
  is involved. This is "Ask about screen".
- **Circle to Search is the framework's `ContextualSearchManager`, and it is reachable.** The system launches
  `android.app.contextualsearch.action.LAUNCH_CONTEXTUAL_SEARCH` in the package named by
  `config_defaultContextualSearchPackageName` (now GSA). The intent carries a system screenshot, the visible
  packages, a token for AssistStructure, **and, with `contextual_search_media_projection` enabled on this build, a
  MediaProjection token created by the system with no consent dialog**. `framework-res` has no `<overlayable>`, so
  a preinstalled RRO from our Magisk module can point that config at `com.powos.app`. Callers need
  `ACCESS_CONTEXTUAL_SEARCH` (`signature|privileged`), which our priv-app can hold.
- **Live screen share: Gemini Live uses plain MediaProjection with consent.** It calls `createScreenCaptureIntent()`
  (`MediaProjectionConfig.createConfigForDefaultDisplay()` on 34+), runs a `mediaProjection` foreground service,
  and reads frames through a VirtualDisplay into an RGBA ImageReader. When it comes from Circle to Search, it reuses
  the consent-free token from the contextual-search intent instead. `CAPTURE_VIDEO_OUTPUT` and
  `MANAGE_MEDIA_PROJECTION` are `signature` here, so they can't be granted. `READ_FRAME_BUFFER` is
  `signature|recents`, so we get it only after taking the recents slot.
- **The hotword is the only part that really needs Google-only pieces.** Those are a DSP keyphrase model (Qualcomm
  sound-trigger module 0) and a HotwordDetectionService. The permissions are reachable (`CAPTURE_AUDIO_HOTWORD`,
  `MANAGE_VOICE_KEYPHRASES`: privileged), but the wake-word model is ours to supply. It is not needed for the
  power button, so it goes last.
- **First step:** add `PowosVoiceInteractionService` + `PowosAssistSessionService` + `PowosRecognitionService`
  with their metadata. The session shows the web shell with `surface=assist` and hands it the screenshot and
  structure text. Then the user selects PowOS AI under Settings → Default apps → Digital assistant app.

## 1. Long-press power → assistant on this device

### What is set now

| What | Value | Source |
|---|---|---|
| ASSISTANT role holder | `com.google.android.googlequicksearchbox` | `cmd role get-role-holders android.app.role.ASSISTANT` |
| `secure assistant` / `voice_interaction_service` | `…googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService` | `settings get secure` |
| `secure voice_recognition_service` | `com.google.android.tts/…GoogleTTSRecognitionService` | (system default `SpeechRecognizer`) |
| `secure assist_structure_enabled`, `assist_screenshot_enabled` | unset, which `VoiceInteractionSessionConnection` reads as `1` (on) | lines ~203–207 |
| `secure contextual_search_package` | `com.google.android.googlequicksearchbox` (written by ContextualSearchManagerService itself) | |
| `secure op_assist_started=1`, `assist_long_press_home_enabled=1` | OnePlus's one-time "assistant guide" dialog is already done | |
| `system quick_turn_on_voice_assistant=1` | OnePlus Settings "Press and hold power button → Assistant" (`StrategyShutdown`, `mPowerKeyAssistantEnable`) | |
| `global power_button_long_press` | unset, so the framework config applies | |
| `config_longPressOnPowerBehavior` | `5` = `LONG_PRESS_POWER_ASSISTANT`; `mLongPressOnPowerAssistantTimeoutMs=500` | `cmd overlay lookup`, `dumpsys window policy` |
| `config_defaultAssistant` | `com.google.android.googlequicksearchbox` (role default) | `cmd overlay lookup` |
| `config_defaultContextualSearchPackageName` | `com.google.android.googlequicksearchbox` | `cmd overlay lookup` |
| VIS bound | session `…nga.engine.viss.NgaVoiceInteractionSessionService`, recognition `…voicesearch.serviceapi.GoogleRecognitionService`, hotword `…GsaHotwordDetectionService`, `Supports assist=true`, `Supports launch from keyguard=true`, `mIsHdsRequired=false` | `dumpsys voiceinteraction` |

### The call path (services.jar, oplus-services.jar, SystemUI.apk)

1. `PhoneWindowManager.powerLongPress` → `getResolvedLongPressOnPowerBehavior()` returns 5 (or 1 = global actions
   if the device is not provisioned) → haptic → `launchAssistAction(null, -2, t, invocationType=6, 1)`.
   `6` is `INVOCATION_TYPE_POWER_BUTTON_LONG_PRESS`. OnePlus's `PhoneWindowManagerExtImpl.oplusHandleAssistLaunchMode`
   only adds stats and an `assistant_launch_mode` extra. The OnePlus Breeno path (`com.heytap.speechassist`) is not
   installed and not taken on this EX build.
2. `launchAssistAction` → `SearchManager.launchAssist(args)` → `SearchManagerService` →
   `StatusBarManagerInternal.startAssist(args)` → SystemUI `AssistManager.startAssist`.
3. `AssistManager.startAssist`: if the recents app (the launcher's `ILauncherProxy`) registered overrides for this
   invocation type (`setAssistantOverridesRequested`), the call goes to `onAssistantOverrideInvoked(type)` instead
   (section 4.3). Otherwise, on export builds (`isExpRegion()`), OnePlus's `AssistManagerImpl.beforeStartAssistInternal`
   runs:
   - It reads `Settings.Secure.assistant`, splits it into a ComponentName, and computes `isService = (component ==
     active VIS)`. If the setting is empty it returns early (`opAssistPicker is empty!`).
   - Then `AssistManager.startAssistInternal(bundle, component, isService)`:
     - **service** → `AssistUtils.showSessionForActiveService(bundle, SHOW_SOURCE_ASSIST_GESTURE=4, …)`;
     - **activity** → `SearchManager.getAssistIntent(structureEnabled)` (ACTION_ASSIST) with that component,
       launched as a new task.
4. `VoiceInteractionManagerService.showSessionForActiveService` → `mImpl.showSessionLocked(args, sourceFlags | 1 | 2,
   …)`. That is `SHOW_WITH_ASSIST | SHOW_WITH_SCREENSHOT`. `VoiceInteractionSessionConnection.showLocked` removes
   whatever the user settings disable (`assist_structure_enabled=0` → no structure, `assist_screenshot_enabled=0` →
   no screenshot), plus the service's own `setDisabledShowContext`. It then binds the SessionService (if needed),
   creates the session and its `TYPE_VOICE_INTERACTION` window, and calls
   `onPrepareShow` → `onShow(args, flags)` → `onHandleAssist(AssistState)` per visible activity →
   `onHandleScreenshot(Bitmap)`.

So **the component that gets invoked is the role holder's `VoiceInteractionSessionService`**. An `ACTION_ASSIST`
activity is only the fallback for an assistant that has no VIS, and OnePlus's SystemUI breaks that fallback.

### How the role picks its holder

`roles.xml` (GooglePermissionController): ASSISTANT has `requestable="false"` (an app can't ask for it with
`RoleManager.createRequestRoleIntent`), `showNone="true"`, and `exclusive`. Qualification
(`AssistantRoleBehavior.getQualifyingPackagesInternal`) accepts either:

- an exported service for `android.service.voice.VoiceInteractionService`, with `android:permission=
  "android.permission.BIND_VOICE_INTERACTION"` and `android.voice_interaction` metadata that sets
  `sessionService`, `recognitionService` and `supportsAssist="true"`; or
- an exported activity for `android.intent.action.ASSIST`. This qualifies PowOS for the role today, but per step 3
  above the power button can't use it.

The role grants the holder: the `sms` set, `READ_CALL_LOG`, `ACCESS_BLOBS_ACROSS_USERS`,
`READ_ASSISTANT_APP_SEARCH_DATA`, `SUBSCRIBE_TO_KEYGUARD_LOCKED_STATE`, `EXECUTE_APP_ACTION`,
`MANAGE_CONTENT_SUGGESTIONS`, `EMBED_ANY_APP_IN_UNTRUSTED_MODE`, the `SYSTEM_ALERT_WINDOW` app-op, and
`receive_sensitive_notifications`. A newer platform level (`isAtLeastC`, not this SDK 36 build) adds a
`read_screen_context` app-op with a consent count. When we target that level, plan for a consent prompt before
screen reading.

When the holder changes, VoiceInteractionManagerService moves `voice_interaction_service` / `assistant` to the
new holder's VIS and binds it. Ways to become the holder:

- **The user picks it:** Settings → Apps → Default apps → Digital assistant app → PowOS AI. This is the normal
  path. PowOS can open that screen with `Intent(Settings.ACTION_VOICE_INPUT_SETTINGS)` or
  `android.settings.MANAGE_DEFAULT_APPS_SETTINGS`.
- **Shell:** `cmd role add-role-holder --user 0 android.app.role.ASSISTANT com.powos.app` (exclusive, so it replaces
  GSA). Do not run this without the user's yes. To undo it, run the same command with GSA's package.
- **Default for fresh setups:** a `config_defaultAssistant` RRO in the system module. Not needed.

## 2. How Gemini does it (reference only)

Gemini (`com.google.android.apps.bard`, 5 MB) is a thin chat app. It has no VIS, no `ACTION_ASSIST` and no
contextual-search component. All of the assistant machinery is in GSA, which is a system priv-app on `/product`
(updated in `/data`), `targetSdk 37`.

### Overlay: VoiceInteractionSession

- VIS `com.google.android.voiceinteraction.GsaVoiceInteractionService` in process `:interactor`, guarded by
  `BIND_VOICE_INTERACTION`. Metadata `@xml/voice_interaction_service_nga`: `sessionService`, `recognitionService`,
  `hotwordDetectionService`, `supportsAssist`, `supportsLaunchVoiceAssistFromKeyguard`, `supportsLocalInteraction`,
  `usesAssistData`, `usesAssistScreenshots`, `usesAssistStructureScreenContent=false`.
- The VIS overrides `onReady`, `onPrepareToShowSession(Bundle, flags)`, `onShowSessionFailed` and
  `onLaunchVoiceAssistFromKeyguard`. It also calls `showSession(bundle, flags)` itself for programmatic invocations,
  and `setDisabledShowContext(SHOW_WITH_SCREENSHOT)` only on XR devices.
- The session (`AgsaApa…VoiceInteractionSession`) implements `onHandleAssist(AssistState)` (and the legacy
  `onHandleAssist(Bundle, AssistStructure, AssistContent)`), `onHandleScreenshot`, `onCloseSystemDialogs`,
  `requestDirectActions`, `setUiEnabled`, and **`onComputeInsets`, setting `touchableInsets` and `touchableRegion`
  from its UI**. That is how the overlay leaves the app below it touchable outside the panel. The window is the
  framework's session window (`TYPE_VOICE_INTERACTION`). GSA never adds a `TYPE_APPLICATION_OVERLAY` window of its
  own for this.
- "Ask about screen" = the screenshot and AssistStructure from that same show.

### Circle to Search: ContextualSearchManager

- GSA exports two activity-aliases for `android.app.contextualsearch.action.LAUNCH_CONTEXTUAL_SEARCH`
  (`com.google.android.apps.lens.ContextualSearchEntrypoint`, `…omnient.host.contextualsearch.ContextualSearchServiceEntrypoint`).
  It reads `extra.SCREENSHOT`, `ENTRYPOINT`, `VISIBLE_PACKAGE_NAMES`, `INVOCATION_TIME_MS`, `FLAG_SECURE_FOUND`
  and `IS_MANAGED_PROFILE_VISIBLE`. It wraps `extra.TOKEN` (a `CallbackToken`) to call `getContextualSearchState`
  for the AssistStructure/AssistContent.
- Who starts it: OnePlus's SystemUI (`OplusCircleToSearchDialogManager.startCircleToSearch` →
  `ContextualSearchManager.startContextualSearch(entryPoint)`) and the launcher's nav-handle long press. Callers
  must hold `ACCESS_CONTEXTUAL_SEARCH`.
- Framework side (`ContextualSearchManagerService`, device build). `getResolvedLaunchIntent` resolves the action in
  `getContextualSearchPackageName()`, which is the temporary package or `config_defaultContextualSearchPackageName`
  (jadx mislabels it `config_dreamsDefaultComponent`). **The target package needs no permission.**
  `getContextualSearchIntent` takes `WindowManagerInternal.takeContextualSearchScreenshot(csUid)`. With
  `contextual_search_prevent_self_capture` on, the target's own windows are left out of it. It requests assist data
  for the top visible activities and, with `contextual_search_media_projection` on (true here), calls
  `IMediaProjectionManager.createProjection(csUid, csPackage, …)` + `setRecordingOverlay(true)` and puts it in
  `android.media.projection.extra.EXTRA_MEDIA_PROJECTION`. **That is a projection the user never confirmed in a
  dialog.** It is launched via `startActivityWithScreenshot` with no starting window.
- When GSA hands off from Circle to Search to Live, it moves that token into the Live intent ("invocation-intent")
  and drops the screenshot extra. Live then gets frames without a consent prompt.

### Gemini Live screen share

- `…robin.ui.conversationmode.screenshare.activity.ScreenshareStartupActivity` →
  `MediaProjectionManager.createScreenCaptureIntent()`, or `createScreenCaptureIntent(MediaProjectionConfig.
  createConfigForDefaultDisplay())` on 34+ (this skips the "single app" choice) → result →
  `ScreenShareService` (`foregroundServiceType="mediaProjection"`) → `getMediaProjection(resultCode, intent)` →
  `createVirtualDisplay("ScreenRecorder", w, h, dpi, AUTO_MIRROR, ImageReader(RGBA_8888, 1 buffer))` → frames sampled
  from `onImageAvailable`. `LiveService` is `microphone|camera|mediaProjection`. The Lens `ScreencastService` and
  `OmnientLiveForegroundService` follow the same pattern.
- There are no `CAPTURE_VIDEO_OUTPUT`, `READ_FRAME_BUFFER` or private capture APIs in GSA's manifest.

### Voice

- `GoogleRecognitionService` (`android.speech.RecognitionService`) is the VIS's recognitionService.
- Hotword: `createAlwaysOnHotwordDetector` (DSP keyphrase through the Qualcomm sound-trigger HAL; GSA is attached to
  module 0 in `dumpsys soundtrigger_middleware`) plus `createHotwordDetector` (software). Both go through
  `GsaHotwordDetectionService` (`isolatedProcess`, `BIND_HOTWORD_DETECTION_SERVICE`).
- Permissions GSA holds for this: `RECORD_AUDIO`, `CAPTURE_AUDIO_HOTWORD`, `MANAGE_VOICE_KEYPHRASES`,
  `MANAGE_HOTWORD_DETECTION`, `CAPTURE_AUDIO_OUTPUT`, `CAPTURE_MEDIA_OUTPUT`, `MODIFY_AUDIO_ROUTING`,
  `MANAGE_ASSISTANT_AUDIO`, `SUBSCRIBE_TO_KEYGUARD_LOCKED_STATE`, `SYSTEM_ALERT_WINDOW`, `DETECT_SCREEN_CAPTURE`.

### Which of Gemini's abilities rest on what

| Ability | Mechanism | Needs |
|---|---|---|
| Power-button overlay | VIS + SessionService | ASSISTANT role (any app) |
| See the screen (text + pixels) | `onHandleAssist` / `onHandleScreenshot` | role; user settings on (default) |
| Circle to Search | ContextualSearchManager target | being `config_defaultContextualSearchPackageName` (a framework config; Google gets it from OEM config). PowOS: preinstalled RRO |
| Consent-free projection | the contextual-search token | same as above |
| Live screen share | MediaProjection + FGS | public API, user consent |
| Voice in/out | RecognitionService, TTS, mic | public, `RECORD_AUDIO` |
| "Hey Google" | DSP keyphrase + HotwordDetectionService | `CAPTURE_AUDIO_HOTWORD` / `MANAGE_VOICE_KEYPHRASES` (privileged) **and Google's proprietary models** |

## 3. PowOS design

### 3.1 Components (targets/android/app, package com.powos.app)

```
PowosVoiceInteractionService : VoiceInteractionService     // the role's entry; holds no UI
PowosAssistSessionService   : VoiceInteractionSessionService
  └ PowosAssistSession       : VoiceInteractionSession      // thin host: WebView(shell, surface=assist)
PowosRecognitionService     : RecognitionService            // required by role qualification; delegates
PowosScreenShareService     : Service (fgs mediaProjection) // phase 4
PowosContextualSearchActivity (LAUNCH_CONTEXTUAL_SEARCH)    // phase 5
```

Manifest sketch:

```xml
<service android:name=".assist.PowosVoiceInteractionService" android:exported="true"
    android:permission="android.permission.BIND_VOICE_INTERACTION">
  <meta-data android:name="android.voice_interaction" android:resource="@xml/powos_voice_interaction"/>
  <intent-filter><action android:name="android.service.voice.VoiceInteractionService"/></intent-filter>
</service>
<service android:name=".assist.PowosAssistSessionService" android:exported="true"
    android:permission="android.permission.BIND_VOICE_INTERACTION"/>
<!-- No bind permission: apps bind recognizers directly (GSA's GoogleRecognitionService is exported, unguarded;
     there is no BIND_RECOGNITION_SERVICE on this build). The service checks RECORD_AUDIO on its caller itself. -->
<service android:name=".assist.PowosRecognitionService" android:exported="true">
  <intent-filter><action android:name="android.speech.RecognitionService"/></intent-filter>
  <meta-data android:name="android.speech" android:resource="@xml/powos_recognition"/>
</service>
```

`res/xml/powos_voice_interaction.xml`:

```xml
<voice-interaction-service xmlns:android="http://schemas.android.com/apk/res/android"
    android:sessionService="dev.omalauncher.assist.PowosAssistSessionService"
    android:recognitionService="dev.omalauncher.assist.PowosRecognitionService"
    android:settingsActivity="dev.omalauncher.SettingsActivity"
    android:supportsAssist="true"
    android:supportsLaunchVoiceAssistFromKeyguard="true"
    android:supportsLocalInteraction="true"/>
```

(No `hotwordDetectionService` until phase 6. Adding one later requires `isolatedProcess`.)

Keep the `ACTION_ASSIST` filter on `PowosAiActivity`. It still serves "open the full chat" and the share sheet, and
it is the fallback on ROMs whose SystemUI handles activity assistants.

**PowosRecognitionService** must be a real delegate, not a stub. When the VIS changes, the framework can also point
`voice_recognition_service` at it, so every app that uses the default `SpeechRecognizer` would go through it. It
forwards `onStartListening` to `SpeechRecognizer.createOnDeviceSpeechRecognizer` (falling back to the previous
default component, which today is Google's TTS recognizer, the same choice `ui/Speech.kt` makes) and relays the
callbacks.

### 3.2 The overlay: session window + web shell

- `PowosAssistSession.onCreateContentView()` returns a WebView loading `https://shell.powos/index.html?surface=assist`
  through the same asset loader and hot reload as `ShellActivity` (factor its WebView setup out so both hosts share
  it; `ShellBridge` takes an `Activity` today and needs a `Context` + window variant). The window is
  `TYPE_VOICE_INTERACTION`, above apps and below the status bar.
- Transparent background. The shell draws a bottom sheet (`ui/powai.tsx` reused) and reports its panel rectangles
  through a new bridge call `assist.touchable(rects)`. The host stores them and returns them from `onComputeInsets`
  (`TOUCHABLE_INSETS_REGION`), so taps outside the sheet reach the app below. This is the same technique Gemini
  uses.
- `onShow(args, flags)`: `args.getInt("invocation_type")` says what opened it (6 = power long press, 5 = home long
  press, 1 = gesture, 2 = other). The host emits `assist.show {invocation, flags}` and the shell decides whether to
  open listening (power) or typing.
- `onHide`, `onBackPressed` and `onCloseSystemDialogs` close it (`hide()`). `onLockscreenShown` and
  `supportsLaunchVoiceAssistFromKeyguard` give a locked-screen variant later. Keep it text-only while locked: no
  screen context, no agent tools that act on the device.

### 3.3 Screen context ("Ask about screen")

- `onHandleAssist(state)`: walk `state.assistStructure` (window nodes → `ViewNode.text`, `contentDescription`,
  `hint`, bounds, `isFocused`) into a compact outline. `state.assistContent` gives `webUri`, `intent` and
  `structuredData` (JSON-LD). Keep `AssistStructure.isHomeActivity`/package names. Emit
  `assist.context {pkg, activity, outline, uri}`.
- `onHandleScreenshot(bitmap)`: encode it to JPEG (~85, longest side capped around 1600 px) in the app cache and
  emit `assist.screenshot {url}`, served by the shell's asset handler at `/_assist/screenshot.jpg?n=` (no base64
  over the bridge).
- No flags to set: the framework always asks for `SHOW_WITH_ASSIST | SHOW_WITH_SCREENSHOT` on the power path. Only
  the user switches (`Settings > Default apps > Digital assistant > Use text from screen / Use screenshot` =
  `assist_structure_enabled` / `assist_screenshot_enabled`) and our own `setDisabledShowContext` can turn them off.
  Secure (`FLAG_SECURE`) windows come out black. That's expected; say so in the UI.
- Refresh while open: the VIS can call `showSession(Bundle, SHOW_WITH_ASSIST or SHOW_WITH_SCREENSHOT)` again,
  which delivers a new structure and screenshot to the live session (Gemini does programmatic `showSession` too).
  Whether the session's own window is left out of that screenshot needs checking on the device. If it isn't, hide
  the sheet for one frame first.

### 3.4 Draw, circle and crop

All of this is web UI, no native code. The `surface=assist` shell shows the screenshot full-bleed under a canvas.
Lasso or freehand stroke → bounding box (plus padding) → crop in a `<canvas>` → `assist.attach({png})` → stored next
to the screenshot. Taps on AssistStructure nodes can snap the box to a text block (bounds come from the outline).
The cropped image plus the node text inside the box go to the agent with the prompt.

### 3.5 Live screen share

Two sources, chosen by how it was opened:

1. **From the assistant overlay (phase 4):** `MediaProjectionManager.createScreenCaptureIntent(
   MediaProjectionConfig.createConfigForDefaultDisplay())` from a transparent trampoline activity (a session can
   `startAssistantActivity`) → the user confirms → `PowosScreenShareService` (`foregroundServiceType=
   "mediaProjection"`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` is `normal`) → `getMediaProjection` →
   VirtualDisplay → `ImageReader`. Register `MediaProjection.Callback` first (required since 34). The consent covers
   one projection only; a new share asks again.
2. **From Circle to Search (phase 5):** the `EXTRA_MEDIA_PROJECTION` binder in the contextual-search intent →
   `getMediaProjection(RESULT_OK, launchIntent)`. No dialog. The status-bar recording chip still shows, because
   `setRecordingOverlay(true)` is set.

Not available: `CAPTURE_VIDEO_OUTPUT` and `CAPTURE_SECURE_VIDEO_OUTPUT` (`signature`, `signature|role`),
`MANAGE_MEDIA_PROJECTION` (`signature`), `ACCESS_SURFACE_FLINGER` (`signature`). `READ_FRAME_BUFFER` is
`signature|recents`. It becomes ours if PowOS takes `config_recentsComponentName` (NATIVE-SYSTEM-UI.md section 1),
which would allow silent captures through the window manager's screenshot path. Don't build on it here. Consent
plus the contextual-search token cover the feature honestly.

What "live" means for the agent: the manager is turn-based Claude, so there is no realtime video. The share
service samples a frame when the screen changes (cheap diff on a downscaled copy) or when the user speaks, caps the
rate at about 1 fps, and sends the latest frame or frames with each spoken turn. A realtime voice+video model can
be added behind the same frame source later.

### 3.6 Voice in and out

- In: `ui/Speech.kt` (on-device `SpeechRecognizer`, partial results, loudness) moved into the session host and
  exposed as the existing `speech.start/stop/cancel` bridge calls. `RECORD_AUDIO` is already requested. On a power
  invocation the shell starts listening right away. Push-to-talk while the button is still held would need key
  events, which the session doesn't get, so start on show and stop on silence.
- Out: `android.speech.tts.TextToSpeech` (default engine, Google TTS today; swappable) speaking the agent's
  `assistant` events as they stream, sentence by sentence. Take audio focus with
  `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK` while speaking and `AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE` while listening, and
  release it on hide. Bridge: `speech.say(text)`, `speech.hush()`.

### 3.7 Getting images to the PowOS manager

Today `PowosAiChat.turn` runs `powos manager --once-stdin --json-events` in the rooted guest and writes plain text
to stdin. `lib/ai/manager/manager.py` already speaks `--input-format stream-json` to `claude` and builds
`{"type":"user","message":{"role":"user","content":[{"type":"text",…}]}}`. Claude's stream-json user content
accepts image blocks, so:

- Add `--once-stdin-json` to manager.py. Stdin is `{"text": "...", "images": [{"media_type": "image/jpeg", "data":
  "<base64>"}], "context": "<outline>"}`, and the content becomes `[{type:image, source:{type:base64,…}}…,
  {type:text, text: context + text}]`. This keeps it to one pipe, needs no shared filesystem path between Android
  and the guest, and works the same from the KDE widget.
- `PowosAiChat.send(context, text, images)` and `ai.send(text, {images})` in `shell/bridge.ts`. History stores a
  thumbnail reference, not the image.

### 3.8 Permissions and the allowlist

What each piece needs, with protection levels read on this device (`pm list permissions -f`):

| Permission | Level here | Phase | Why |
|---|---|---|---|
| (role) ASSISTANT | role | 0 | power button, screen context, `SYSTEM_ALERT_WINDOW` app-op, keyguard state |
| `RECORD_AUDIO` | dangerous | 0 | already requested |
| `FOREGROUND_SERVICE_MEDIA_PROJECTION` | normal | 4 | share service |
| `ACCESS_CONTEXTUAL_SEARCH` | **signature\|privileged** | 5 | call `startContextualSearch` (e.g. a "Circle" button in the overlay). **Add to `privapp-permissions.txt`** |
| `CAPTURE_AUDIO_HOTWORD` | **signature\|privileged\|role** | 6 | hotword audio. **Allowlist** |
| `MANAGE_VOICE_KEYPHRASES` | **signature\|privileged** | 6 | DSP keyphrase enrollment. **Allowlist** |
| `MANAGE_HOTWORD_DETECTION` | internal\|preinstalled | 6 | granted to preinstalled apps; not an allowlist entry, check that it is granted |
| `CAPTURE_AUDIO_OUTPUT` / `CAPTURE_MEDIA_OUTPUT` | signature\|privileged\|role | later, optional | "what's playing" audio; skip until wanted |
| `CAPTURE_VIDEO_OUTPUT`, `MANAGE_MEDIA_PROJECTION`, `BIND_VOICE_INTERACTION`, `ACCESS_VOICE_INTERACTION_SERVICE`, `BIND_HOTWORD_DETECTION_SERVICE`, `CONTROL_KEYGUARD` | signature | – | not reachable; not needed (the BIND_* ones are what the *system* holds to bind us) |
| `READ_FRAME_BUFFER` | signature\|recents | – | only as the recents app |

`build-module.sh` refuses an APK that requests a privileged permission missing from the list, and a missing entry
would otherwise bootloop the phone, so each `uses-permission` lands in the same commit as its allowlist line.

**RRO for Circle to Search (phase 5):** add a static overlay for `android` to the system module
(`/system/product/overlay/PowosContextualSearch.apk`, `isStatic`, high priority) that sets
`string/config_defaultContextualSearchPackageName = com.powos.app`. Preinstalled is required because a `/data`
overlay cannot target `android`. It is allowed because `framework-res` declares no `<overlayable>`. Then the stock
OnePlus triggers (nav-handle long press, SystemUI's circle-to-search) open `PowosContextualSearchActivity` with the
screenshot, the token (→ structure) and the consent-free projection. To try it before writing the RRO, without a
reboot: `cmd contextual_search set temporary-package com.powos.app 120000` (max 2 min, shell-only, resets
itself). Run it only with the user's yes. The cost: Google Circle to Search stops working while PowOS owns the
config.

Note: right now `com.powos.app` is still a `/data/app` install (`pm path`, no PRIVILEGED flag). The system module
from NATIVE-SYSTEM-UI phase 0 has to be installed and booted before anything in phases 5–6 applies. Phases 0–4
need no privileges at all.

## 4. Risks and limits

1. **OnePlus SystemUI quirks.** The VIS path relies on `Settings.Secure.assistant` equaling the active VIS. The
   role sets both, but an OTA could change `AssistManagerImpl`. Watch for a first-run "assistant guide" dialog:
   `op_assist_started` is already 1. OnePlus's Settings toggle "Press and hold power button" must stay on
   *Assistant* (`quick_turn_on_voice_assistant=1`). On a non-provisioned device, long press falls back to the power
   menu.
2. **Role is exclusive.** Taking it removes Gemini/Google Assistant from the power button and from "Hey Google"
   (GSA's hotword stops when it is no longer the active VIS). Google Circle to Search survives until the phase 5 RRO.
3. **RecognitionService side effect.** Becoming the VIS can make PowOS the system default recognizer for other
   apps. The delegate must be solid, or we keep `voice_recognition_service` pointing at Google's. Check what the
   framework writes on role change.
4. **Hotword is the one Google-only piece.** The DSP path needs a keyphrase model for the Qualcomm sound-trigger
   HAL (vendor format, Google's models are proprietary). The software `HotwordDetector` needs our own
   HotwordDetectionService in an isolated process with an open wake-word model. `mIsHdsRequired=false` on this
   build, so a privileged app could also run its own always-on detector, at a battery cost. Research track, last.
5. **Screen-share consent is per session** (Android 14+). The only consent-free source is the contextual-search
   token, and only when PowOS is the CS package. Don't try to keep it alive across invocations.
6. **Platform drift.** `read_screen_context` (a newer platform level) will add a user consent for screen reading by
   the assistant. Contextual-search token refresh (`enable_token_refresh`) isn't listed in this build's aconfig, so
   expect one structure fetch per invocation.
7. **Privacy surface.** The overlay sees every screen it is invoked on. Keep screenshots in app cache, delete
   them on hide, never ship them anywhere but the PowOS manager, and show a visible chip while sharing.
8. **Session window and IME.** The `TYPE_VOICE_INTERACTION` window takes the keyboard (`adjustResize` behaviour
   differs from an activity). Test typing in the sheet on both screens of the Open (fold/unfold reconfigures the
   session).

## 5. Plan

| Phase | What | Effort | Needs priv? |
|---|---|---|---|
| 0 | VIS + SessionService + delegate RecognitionService + metadata. Session host = shell WebView `surface=assist` with `onComputeInsets`. User selects PowOS AI as Digital assistant. Long-press power opens it over the app | 1–1.5 d | no |
| 1 | Ask about screen: `onHandleAssist` outline + `onHandleScreenshot` → shell. `manager.py --once-stdin-json` with image blocks; `ai.send(text, {images})` | 1–2 d | no |
| 2 | Draw/circle/crop in the shell over the screenshot; node snapping | 1 d | no |
| 3 | Voice in/out in the overlay (Speech.kt in the host, TTS, audio focus); auto-listen on power invocation | 1 d | no |
| 4 | Live share: consent → `mediaProjection` FGS → change-sampled frames into turns; status chip | 2–3 d | no |
| 5 | Circle to Search: `PowosContextualSearchActivity`, `ACCESS_CONTEXTUAL_SEARCH` in the allowlist, contextual-search RRO in the system module; consent-free projection from that entry | 1–2 d + a reboot | yes (module) |
| 6 | Hotword research (software HotwordDetectionService with an open wake-word model; DSP later) | open | yes |

**First concrete step (phase 0):** add `dev.omalauncher.assist.{PowosVoiceInteractionService,
PowosAssistSessionService, PowosAssistSession, PowosRecognitionService}` and `res/xml/powos_voice_interaction.xml`.
Factor the shell WebView setup out of `ShellActivity` so the session can host it with `?surface=assist`. Build and
deploy through the project pipeline. Then, with the user's go-ahead, select PowOS AI under Settings → Default apps
→ Digital assistant app. Check `dumpsys voiceinteraction` (our component, `Session service=…PowosAssistSessionService`,
`Supports assist=true`) and long-press power. Undo by picking Google again in the same screen.
