#!/bin/bash
# The shell's native bridge reaches its own top frame only (targets/android/app .../shell/ShellOrigin.kt): checked in
# the live page on the phone over CDP (tools/phone/cdp.sh) - the gate's headless Chromium runs the mock bridge, so it
# can't see what the app's WebView injects. Draws nothing the user sees (the probe frames are 0x0 and removed).
#   tools/phone/bridge-check.sh [page]        (page: home by default; lock, shade, assist, ...)
# Exit 0: the top frame has the bridge, no probe frame could use it. 1: a leak (or no bridge at all). 2: couldn't run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
page=${1:-}
# Every probe frame reports what it has and tries one harmless call (apps.list, id 999999: an answer would only
# land in the top frame's unknown-id slot) - refused calls show as "refused a message" in logcat (PowosShell).
read -r -d '' js <<'JS' || true
(async () => {
  const out = { top: { host: typeof window.PowosHost, native: typeof window.PowosNative, boot: typeof window.PowosBoot, origin: self.origin } };
  const probe = (name) => `<script>
    let tried = "none";
    try { if (window.PowosHost) { window.PowosHost.postMessage(JSON.stringify([999999, "apps.list", "[]"])); tried = "sent"; } } catch (e) { tried = "threw " + e.message; }
    parent.postMessage({ probe: "${name}", host: typeof window.PowosHost, native: typeof window.PowosNative, boot: typeof window.PowosBoot, origin: self.origin, tried }, "*");
  <\/script>`;
  const got = {};
  const onMsg = (e) => { if (e.data && e.data.probe) got[e.data.probe] = e.data; };
  addEventListener("message", onMsg);
  const frames = [];
  const add = (name, set) => { const f = document.createElement("iframe"); f.style.cssText = "position:fixed;width:0;height:0;border:0;opacity:0;pointer-events:none"; set(f); document.body.appendChild(f); frames.push(f); return f; };
  add("srcdoc", (f) => (f.srcdoc = probe("srcdoc")));
  add("srcdoc-sandboxed", (f) => { f.setAttribute("sandbox", "allow-scripts"); f.srcdoc = probe("srcdoc-sandboxed"); });
  add("data-url", (f) => (f.src = "data:text/html," + encodeURIComponent(probe("data-url"))));
  // about:blank: same origin as the page, so the page reaches into it directly (no inline script needed).
  const blank = add("about-blank", () => {});
  await new Promise((r) => setTimeout(r, 1500));
  try {
    const w = blank.contentWindow;
    let tried = "none";
    try { if (w.PowosHost) { w.PowosHost.postMessage(JSON.stringify([999998, "apps.list", "[]"])); tried = "sent"; } } catch (e) { tried = "threw " + e.message; }
    got["about-blank"] = { host: typeof w.PowosHost, native: typeof w.PowosNative, boot: typeof w.PowosBoot, origin: w.origin, tried };
  } catch (e) { got["about-blank"] = { error: String(e) }; }
  removeEventListener("message", onMsg);
  frames.forEach((f) => f.remove());
  out.frames = got;
  return out;
})()
JS
res=$("$here/cdp.sh" eval "$page" "$js") || { echo "bridge-check: CDP failed: $res" >&2; exit 2; }
echo "$res"
refused=$("$here/adb.sh" shell "logcat -d -v time -s PowosShell:W | grep -c 'refused a message' || true" | tr -d '\r')
echo "logcat: $refused refused message(s) so far"
# Pass: the top frame has the objects. A probe frame may hold an object only where the WebView injects by origin
# (a same-origin srcdoc/about:blank frame) - then its call must have been refused (seen in logcat above).
echo "$res" | grep -q '"host": "object"' || { echo "bridge-check: FAIL - the top frame has no PowosHost" >&2; exit 1; }
echo "$res" | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad = []
if d["top"]["host"] != "object": bad.append("top frame: no PowosHost")
for name, f in d.get("frames", {}).items():
    if name in ("srcdoc-sandboxed", "data-url") and (f.get("host") not in (None, "undefined")):
        bad.append(name + ": an opaque-origin frame got PowosHost")
print("bridge-check: frames reporting:", ", ".join(sorted(d.get("frames", {}))) or "none")
if bad:
    print("bridge-check: FAIL - " + "; ".join(bad)); sys.exit(1)
print("bridge-check: ok (same-origin probe frames that hold an object must show as refused in logcat)")
'
