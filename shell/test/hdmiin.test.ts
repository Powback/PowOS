// HDMI in's device choice and overlay line (shell/hdmiin-pick.ts): node --test shell/test/hdmiin.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { captureScore, constraints, measuredFps, modeLine, pickAudio, pickVideo, type MediaDev } from "../hdmiin-pick.ts";

const cam = (label: string, groupId = "", deviceId = label): MediaDev => ({ kind: "videoinput", label, groupId, deviceId });
const mic = (label: string, groupId = "", deviceId = label): MediaDev => ({ kind: "audioinput", label, groupId, deviceId });

test("Android: the external camera, never front or back", () => {
  const list = [cam("camera2 0, facing back"), cam("camera2 1, facing front"), cam("camera2 5, facing external")];
  assert.equal(pickVideo(list)?.label, "camera2 5, facing external");
  assert.equal(pickVideo(list.slice(0, 2)), null);
});

test("Linux: the dongle's V4L2 name wins over a laptop webcam", () => {
  const list = [cam("Integrated Camera (04f2:b6dd)", "g1"), cam("USB Video: USB Video (534d:2109)", "g2")];
  assert.equal(pickVideo(list)?.groupId, "g2");
  assert.equal(captureScore(cam("MS2130 (345f:2130)")), 2);
});

test("an unnamed camera only when it's the only candidate; no labels = nothing yet", () => {
  assert.equal(pickVideo([cam("Some Cam")])?.label, "Some Cam");
  assert.equal(pickVideo([cam("Some Cam"), cam("Other Cam")]), null);
  assert.equal(pickVideo([cam("")]), null);
});

test("audio: the same USB device's input first, then a USB-named one", () => {
  const v = cam("USB Video", "g2");
  const list = [mic("Default", "g0", "default"), mic("Built-in Microphone", "g0", "m0"), mic("USB Digital Audio", "g2", "m2")];
  assert.deepEqual(pickAudio(list, v, null), { deviceId: "m2" });
  assert.deepEqual(pickAudio([mic("MS2109 Analog Stereo", "gx", "m9")], v, null), { deviceId: "m9" });
});

test("audio: never the phone's own mic - Android's default only with a USB input plugged in", () => {
  const v = cam("camera2 5, facing external");
  const android = [mic("", "", "default")];
  assert.equal(pickAudio(android, v, false), null);
  assert.equal(pickAudio(android, v, null), null);
  assert.deepEqual(pickAudio(android, v, true), {});
  assert.equal(pickAudio([mic("Built-in Microphone", "g0", "m0")], cam("USB Video", "g2"), null), null);
});

test("constraints: up to 1080p60, raw audio", () => {
  const c = constraints(cam("USB Video", "g", "v1"), { deviceId: "a1" });
  const video = c.video as MediaTrackConstraints;
  assert.deepEqual(video.deviceId, { exact: "v1" });
  assert.deepEqual(video.frameRate, { ideal: 60, max: 60 });
  const audio = c.audio as MediaTrackConstraints;
  assert.equal(audio.echoCancellation, false);
  assert.equal(audio.autoGainControl, false);
  assert.deepEqual(audio.deviceId, { exact: "a1" });
  assert.equal(constraints(cam("x"), null).audio, false);
  assert.equal((constraints(cam("x"), {}).audio as MediaTrackConstraints).deviceId, undefined);
});

test("the overlay line", () => {
  assert.equal(modeLine(1920, 1080, 60, 59.7), "1920×1080 · 60 fps");
  assert.equal(modeLine(1920, 1080, 60, 30), "1920×1080 · 60 fps · 30 shown");
  assert.equal(modeLine(undefined, undefined, undefined, null), "starting…");
  assert.equal(measuredFps([0, 16.6, 33.3, 50]), 60);
  assert.equal(measuredFps([5]), null);
});
