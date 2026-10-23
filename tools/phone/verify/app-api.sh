#!/bin/bash
# app-api.sh (Mac side, board app-api-app-view-toggle-app-apis): the App API app on the device. In the runner's free
# window: opens local.app-api from home's devtools, opens Philips Hue, counts its actions, opens list_rooms and taps
# "Dry run" (a dry run only: nothing is sent, the Hue bridge is never contacted), reads the request it shows, takes a
# screencap, closes the app again. PASS = 5 Hue actions listed and the dry run shows the GET with the key only as its
# handle (secret:hue), nothing sent. Transient UI only: the page is closed again (closeApp), no setting changes.
set -u
cd "$(dirname "$0")/../../.." || exit 1
ev() { tools/phone/cdp.sh eval home "$1" 2>&1 | tr -d '\\' | tail -1; }
o=$(ev '(()=>{const A=window.__powosApps;if(!A)return "no-api";if(!A.installedApps.value.some(a=>a.id==="local.app-api"))return "not-installed";A.openApp("local.app-api");return "opened"})()')
[ "$o" = opened ] || { echo "FAIL: couldn't open App API ($o)"; exit 1; }
# One async eval on the phone: wait for the list, open Hue, open list_rooms, dry run, read the result.
run='(async()=>{const s=document.querySelector(".app-screen");const until=async(f,n)=>{for(let i=0;i<n;i++){const v=f();if(v)return v;await new Promise(r=>setTimeout(r,250))}return null};
const pick=(t)=>[...s.querySelectorAll("div")].reverse().find(d=>d.style.cursor==="pointer"&&d.textContent.includes(t));
const hue=await until(()=>pick("Philips Hue"),40);if(!hue)return JSON.stringify({step:"list",text:s.innerText.slice(0,200)});hue.click();
const lr=await until(()=>pick("list_rooms"),20);if(!lr)return JSON.stringify({step:"detail"});
const ids=["list_rooms","list_scenes","set_room","recall_scene","open_lights_page"].filter(a=>s.innerText.includes(a));
lr.click();const b=await until(()=>[...s.querySelectorAll("button")].find(x=>x.textContent==="Dry run"),20);b.click();
const pre=await until(()=>s.querySelector("pre"),40);return JSON.stringify({ids:[...new Set(ids)],out:pre?pre.textContent:null})})()'
r=$(tools/phone/cdp.sh eval home "$run" 2>&1 | tail -1)
shot=$HOME/.cache/app-api/device-app-api.png; mkdir -p "$(dirname "$shot")"
tools/phone/shot.sh "$shot" >/dev/null 2>&1 || shot="(no screencap)"
ev 'window.__powosApps.closeApp(),"closed"' >/dev/null
echo "app-api: $r shot=$shot"
fail=
n=$(grep -o 'list_rooms\|list_scenes\|set_room\|recall_scene\|open_lights_page' <<<"${r%%out*}" | sort -u | wc -l | tr -d ' ')
[ "$n" = 5 ] || fail="$fail actions=$n(want 5)"
grep -q 'GET https://{bridge_ip}/clip/v2/resource/room' <<<"$r" || fail="$fail no-request"
grep -q 'secret:hue' <<<"$r" || fail="$fail no-handle"
grep -q 'dry run - nothing was sent' <<<"$r" || fail="$fail not-dry-run"
[ -n "$fail" ] && { echo "FAIL:$fail"; exit 1; }
echo "PASS: App API lists Hue's 5 actions; list_rooms dry run shows GET /resource/room with secret:hue as a handle, nothing sent"
