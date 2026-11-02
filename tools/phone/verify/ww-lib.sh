# shellcheck shell=bash
# tools/phone/verify/ww-lib.sh (sourced by e2e-lib.sh, linux-float.sh): home's page over CDP (ev), its bridge (hcall)
# and the web windows (W1, docs/WEB_WINDOWS.md) every window check reads - one copy, not one per check. Needs T set.
# ev <js> [page]: a CDP eval, its answer unquoted when it is a JSON string (cdp.sh prints "\"opened\"" - a quoted answer
# read as is made app-api.sh and app-frost.sh FAIL on a page that had opened, 2026-10-23).
UNQ='import json,sys
s=sys.stdin.read().strip()
try:
    v=json.loads(s)
except Exception:
    v=s
print(v if isinstance(v,str) else json.dumps(v))'
ev() { "$T/cdp.sh" eval "${2:-home}" "$1" 2>/dev/null | tr -d '\r' | tail -1 | python3 -c "$UNQ"; }
# hcall <method> <JS args> <JS fn of the answer -> string>: a call on home's bridge as the page makes it
# (float-windows.sh); an empty answer is a failed hop before the page, made again (up to 4 tries).
hcall_once() {
  ev "new Promise(ok=>{const h=window.__powosHost,P=window.PowosHost;if(!h||!P||!P.postMessage)return ok('ERR no bridge');const r=h.resolve,j=h.reject,id=930300+Math.floor(Math.random()*9000);const done=v=>{h.resolve=r;h.reject=j;ok(v)};h.resolve=(i,v)=>i===id?done(v):r(i,v);h.reject=(i,m)=>i===id?done('ERR '+m):j(i,m);setTimeout(()=>done('ERR no answer'),8000);P.postMessage(JSON.stringify([id,'$1',JSON.stringify($2)]))}).then(v=>typeof v==='string'&&v.startsWith('ERR')?v:String(($3)(v)))"
}
hcall() { local v i; for i in 1 2 3 4; do v=$(hcall_once "$@"); case $v in ""|"cdp: adb"*|*"isn't running"*|"no page"*) sleep 2 ;; *) echo "$v"; return ;; esac; done; echo "ERR no answer (${v:-empty})"; }
# Web windows (W1, docs/WEB_WINDOWS.md): their ids are "w<id>" here (the page's data-wwid), task ids stay plain numbers.
# The truth is the host's list (webwindows.list: key "a:<drawer key>"/"l:<app>", state, task) and the page's element
# (.webwindow[data-wwid]: where it is on screen now, device px). WWRECTS: every web window shown on screen, "l t r b,...".
# WWON: a JS fn of a window's element -> true when any of it shows: its rect cut to its page's box (.page clips its
# windows, PS2 - sideways overflow clip) and the screen. Its bare rect isn't enough: a window hanging past its page's
# right edge (under the dock, E2E 203/206/207: 553..2127 on a 2087 px page) kept 40 px "on screen" after a swipe to the
# next page, while the page's clip (and the host's w.f, visible 0) hid all of it.
WWON="(e=>{const r=e.getBoundingClientRect(),p=e.closest('.page'),q=p?p.getBoundingClientRect():{left:-1e9,right:1e9};return Math.min(r.right,q.right,innerWidth)-Math.max(r.left,q.left,0)>=2&&Math.min(r.bottom,innerHeight)-Math.max(r.top,0)>=2})"
WWRECTS="(()=>{const d=devicePixelRatio,on=$WWON;return [...document.querySelectorAll('.webwindow[data-wwid]')].filter(on).map(e=>e.getBoundingClientRect()).map(r=>[r.left,r.top,r.right,r.bottom].map(v=>Math.round(v*d)).join(' ')).join(',')})()"
# wwel <w-id> <js fn of the element -> string>: its frame element in home's page ("none" when it has none).
wwel() { ev "(()=>{const e=document.querySelector('.webwindow[data-wwid=\"${1#w}\"]');return e?String(($2)(e)):'none'})()"; }
# wwrect <w-id>: its frame, "l t r b" device px (uncut), "" when none of it shows (WWON: minimised, another page).
wwrect() { local v; v=$(wwel "$1" "e=>{const r=e.getBoundingClientRect(),d=devicePixelRatio;return !($WWON)(e)?'':[r.left,r.top,r.right,r.bottom].map(v=>Math.round(v*d)).join(' ')}"); [ "$v" = none ] && v=""; echo "$v"; }
# wwhost <w-id> <field>: from the host's webwindows.list - state | task | key | gone (true when it isn't listed).
wwhost() { hcall webwindows.list "[]" "l=>{const w=l.find(w=>w.id===${1#w});return '$2'==='gone'?String(!w):w?String(w['$2']):'none'}"; }
# wwbody <w-id>: its body (the app's content, under the title bar) on screen, "l t r b" device px, or "".
wwbody() { local v; v=$(wwel "$1" "e=>{const b=e.querySelector('.webwindow-body');if(!b)return '';const r=b.getBoundingClientRect(),d=devicePixelRatio;return r.width<2||r.height<2||r.right<1||r.bottom<1||r.left>innerWidth-1||r.top>innerHeight-1?'':[r.left,r.top,r.right,r.bottom].map(v=>Math.round(v*d)).join(' ')}"); [ "$v" = none ] && v=""; echo "$v"; }
# wwids [key prefix]: the host's web windows (webwindows.list) whose key starts with it, "w<id>" one per line, sorted
# (comm's order). "l:" = every Linux window.
wwids() { local v; v=$(hcall webwindows.list "[]" "l=>l.filter(w=>String(w.key).startsWith('${1:-}')).map(w=>'w'+w.id).join(' ')"); case $v in ERR*) v="" ;; esac
  printf '%s\n' $v | grep . | sort; }
# wwnew <s> <before: wwids' lines> [key prefix]: up to s seconds for web windows not in before; prints them.
wwnew() { local n="" i; for i in $(seq 1 "$1"); do sleep 1; n=$(comm -13 <(echo "$2") <(wwids "${3:-}")); [ -n "$n" ] && break; done; echo "$n"; }
# wwbar <w-id>: true when its PowOS title bar (.webwindow-title) shows on screen in its frame, else false.
wwbar() { wwel "$1" "e=>{const b=e.querySelector('.webwindow-title');if(!b)return false;const r=b.getBoundingClientRect();return r.width>2&&r.height>2&&r.right>0&&r.bottom>0&&r.left<innerWidth&&r.top<innerHeight}"; }
# wwtop <w-id>...: of those, the one on top (the page's webWins, bottom first), "w<id>" or "none".
wwtop() { local ids; ids=$(printf "%s," "${@#w}")
  ev "importShim('./ui/webwindows.tsx').then(m=>{const s=[${ids%,}],w=m.webWins.value.filter(w=>s.includes(w.id)).at(-1);return w?'w'+w.id:'none'})"; }
