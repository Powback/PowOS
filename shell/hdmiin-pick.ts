/**
 * HDMI in's choices, pure (no DOM, no bridge; shell/test/hdmiin.test.ts): which camera is the capture dongle, which
 * mic is its audio, what to ask getUserMedia for, and the overlay's words. A cheap HDMI-to-USB dongle (MacroSilicon
 * MS2109 / MS2130 and their clones) is a plain UVC camera + a USB Audio Class mic: Linux sees a V4L2 webcam + an ALSA
 * input, Android (where the phone's camera HAL takes external cameras) a Camera2 camera facing "external".
 */

/** What enumerateDevices() says of a device (MediaDeviceInfo's fields). */
export interface MediaDev {
  deviceId: string;
  groupId: string;
  kind: string;
  label: string;
}

/** The dongle's names as hosts label it: the chips, "USB Video", Chromium's Android "facing external", capture words. */
const CAPTURE = /ms ?21(09|30)|macrosilicon|usb ?3?\.?0? ?video|usb video|hdmi|capture|cam ?link|av to usb|facing external|external/i;
/** A camera that is the device's own: Android's front/back ones, a laptop's. Never shown as the HDMI source. */
const BUILT_IN = /facing (front|back)|integrated|facetime|built-?in|ir camera|front camera|rear camera|back camera/i;
/** A mic that is a dongle's: same words, or a plain USB audio device ("USB Digital Audio", "USB Audio"). */
const USB_AUDIO = /ms ?21(09|30)|macrosilicon|hdmi|capture|usb ?(digital )?audio|usb video|cam ?link/i;

/** How likely [d] is the capture dongle: 0 never (the device's own camera, no label yet), 1 maybe, 2 by its name. */
export function captureScore(d: MediaDev): number {
  if (d.kind !== "videoinput" || !d.label) return 0;
  if (BUILT_IN.test(d.label)) return 0;
  return CAPTURE.test(d.label) ? 2 : 1;
}

/** The capture dongle among [devices] (the best named one; an unnamed external camera only if it's the only one). */
export function pickVideo(devices: MediaDev[]): MediaDev | null {
  const scored = devices.map((d) => ({ d, s: captureScore(d) })).filter((x) => x.s > 0);
  const named = scored.filter((x) => x.s === 2);
  if (named.length) return named[0].d;
  return scored.length === 1 ? scored[0].d : null;
}

/**
 * The dongle's mic: the input of the same USB device (Chromium groups a device's camera and mic by groupId on Linux),
 * else one named like a dongle's. On Android the WebView lists only "default" - Android's own input routing, which
 * prefers a USB input over the built-in mic for the default source - so there it's the default, but only when the
 * host says a USB audio input is plugged in ([usbAudioIn]): never the phone's own mic played out of its speaker.
 * null: no audio (the video still shows).
 */
export function pickAudio(devices: MediaDev[], video: MediaDev | null, usbAudioIn: boolean | null): { deviceId?: string } | null {
  const inputs = devices.filter((d) => d.kind === "audioinput");
  const same = video?.groupId ? inputs.find((d) => d.groupId === video.groupId && d.deviceId !== "default" && d.deviceId !== "communications") : undefined;
  if (same) return { deviceId: same.deviceId };
  const named = inputs.find((d) => d.label && USB_AUDIO.test(d.label) && d.deviceId !== "communications");
  if (named) return { deviceId: named.deviceId };
  // HACK: Android's WebView has no per-device mic choice; the default input is the USB one while it's plugged in
  // (audio policy order for the MIC source: wired, USB headset, USB device, built-in). Real fix: the native source
  // (docs/HDMI-IN.md, AudioRecord.setPreferredDevice on the dongle's AudioDeviceInfo).
  if (usbAudioIn) return {};
  return null;
}

/** getUserMedia's ask: the dongle's best mode up to 1080p60, and its audio raw (no echo cancel, denoise, gain). */
export function constraints(video: MediaDev, audio: { deviceId?: string } | null): MediaStreamConstraints {
  return {
    video: {
      deviceId: { exact: video.deviceId },
      width: { ideal: 1920, max: 1920 },
      height: { ideal: 1080, max: 1080 },
      frameRate: { ideal: 60, max: 60 },
    },
    audio: audio
      ? {
          ...(audio.deviceId ? { deviceId: { exact: audio.deviceId } } : {}),
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
          channelCount: { ideal: 2 },
          sampleRate: { ideal: 48000 },
        }
      : false,
  };
}

/** The overlay's line: "1920×1080 · 60 fps", with the frames really shown when they're measured and differ. */
export function modeLine(width: number | undefined, height: number | undefined, fps: number | undefined, measured: number | null): string {
  if (!width || !height) return "starting…";
  const asked = fps ? `${Math.round(fps)} fps` : "";
  const real = measured != null && (!fps || Math.abs(measured - fps) >= 1.5) ? `${measured.toFixed(0)} shown` : "";
  return [`${width}×${height}`, asked, real].filter(Boolean).join(" · ");
}

/**
 * Frames per second from the times frames were shown (ms, oldest first) over the last second; null until there are
 * enough to say.
 */
export function measuredFps(times: number[]): number | null {
  if (times.length < 2) return null;
  const span = times[times.length - 1] - times[0];
  return span > 0 ? ((times.length - 1) * 1000) / span : null;
}
