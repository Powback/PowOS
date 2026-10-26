#!/bin/bash
# lanes: emu phone
# app-frost.sh (Mac side, board app-screens-default-to-frost-blur-not-brown): a PowOS app's page wears the frost. In the
# runner's free window: opens one installed app page (local.lights if there, else the first without its own ground)
# from home's devtools, reads the page's computed material over CDP and the compositor's blur regions, takes a
# screencap, closes it again (closeApp - nothing else is changed; no touch injected). PASS = .app-screen is a .tile with
# the frost's compositor radius (--glass-blur-native = --frost-blur-native) and SurfaceFlinger has a blur region on it.
set -u
cd "$(dirname "$0")/../../.." || exit 1
adb() { tools/phone/adb.sh "$@"; }
ev() { tools/phone/cdp.sh eval home "$1" 2>&1 | tr -d '\\' | tail -1; }
open='(()=>{const A=window.__powosApps;if(!A)return "no-api";const L=A.installedApps.value;
const ok=(a)=>{try{return JSON.parse(JSON.stringify(a)).manifest?.page?.background!=="own"}catch{return true}};
const a=L.find(x=>x.id==="local.lights")||L.find(ok);if(!a)return "no-app";A.openApp(a.id);return "opened "+a.id})()'
probe='JSON.stringify((()=>{const e=document.querySelector(".app-screen");if(!e)return {open:false};const c=getComputedStyle(e);
return {open:true,app:e.dataset.app,tile:e.classList.contains("tile"),blur:c.getPropertyValue("--glass-blur-native").trim(),
frost:c.getPropertyValue("--frost-blur-native").trim(),bg:c.backgroundImage.slice(0,160)}})())'
# Whatever happens after the open, the page is closed again (a failed run once left Lights open on the user's screen).
trap "ev 'window.__powosApps&&window.__powosApps.closeApp(),1' >/dev/null" EXIT
o=$(ev "$open")
# cdp.sh prints the answer JSON-quoted ("opened local.lights"): unquote before matching - the quotes made a page that
# DID open read as a failure (2026-10-23).
o=${o#\"}; o=${o%\"}
case "$o" in opened*) ;; *) echo "FAIL: couldn't open an app page ($o)"; exit 1 ;; esac
sleep 1.2
p=$(ev "$probe")
regions=$(adb shell 'su -c "dumpsys SurfaceFlinger"' | tr -d '\r' | grep -A3 "com.powos.app" | grep -o "blurRegions.size()=[0-9]*" | sort -u | tr '\n' ' ')
shot=$HOME/.cache/app-frost/device-app-page.png; mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
ev 'window.__powosApps.closeApp(),"closed"' >/dev/null
echo "app-frost: $o probe=$p sf=[$regions] shot=$shot"
fail=
grep -q '"open":true' <<<"$p" || fail="$fail not-open"
grep -q '"tile":true' <<<"$p" || fail="$fail not-a-tile"
b=$(sed -nE 's/.*"blur":"([^"]*)".*/\1/p' <<<"$p"); f=$(sed -nE 's/.*"frost":"([^"]*)".*/\1/p' <<<"$p")
[ -n "$b" ] && [ "$b" = "$f" ] || fail="$fail radius=$b(want $f)"
grep -q "blurRegions.size()=[1-9]" <<<"$regions" || fail="$fail no-blur-region"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: $o wears the frost (radius $b, compositor regions: $regions)"
