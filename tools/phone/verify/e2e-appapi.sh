#!/bin/bash
# lanes: emu phone
# e2e-appapi.sh --round R: the App API app and the Hue widgets used like a user, READ-ONLY, for the manager's review
# (board manager-end-to-end-user-journeys-on-the-phone-qa; e2e-lib.sh has the rules: screenshots + steps.txt in
# /home/powos/design-qa/e2e-appapi/<round>/, never the verify pill, only what it opened closed).
#   App API from the dock (search if it isn't there): the Apps tab, Philips Hue's actions, "List rooms" opened and
#   "Dry run" (a dry run: nothing is sent, the bridge never contacted), back, the Audit tab (the dry run on top), the
#   Trackers tab; "+ add app": its three paths, the bundled Open-Meteo OpenAPI sample imported into a draft, a dry run
#   of it, discarded (nothing sent, nothing added); closed. Lights opened once from search (it hands its pairing to App API: /link?app=hue linked) and
#   closed - nothing inside it touched. The composed Hue rooms widget (local.hue-rooms*) looked at on home.
# NEVER: a switch (role=switch), "Send", a field, "Ask PowOS AI", "Add to my apps", a light, a setting - every tap's target is checked over CDP first
# (the element under the spot must be the one meant, and not inside a switch, input or textarea).
# Exit: 0 (FAIL lines = a FAIL); 3 a real touch / no window (re-queued); 5 can't run.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/e2e-lib.sh"
e2e_args "$@"
e2e_init appapi
e2e_setup
SCR="document.querySelector('.app-screen')"

step start "home, page 1 (the journey found home on page index $PAGE0; -1 = PowOS AI's)"
note "found home on page index $PAGE0, ${W}x${H}; the journey runs from page 1 and goes back there at the end"

# safe <js element>: its centre "x y" only when the element under that spot is it (or inside it) and nothing there is
# a switch / field / Send; else "unsafe: ..." / "none" / "off".
safe() {
  ev "(()=>{const e=($1);if(!e)return 'none';const r=e.getBoundingClientRect(),d=devicePixelRatio;if(r.width<2||r.height<2||r.bottom<1||r.top>innerHeight-1||r.right<1||r.left>innerWidth-1)return 'off';const cx=r.x+Math.min(r.width/2,40),cy=r.y+r.height/2,h=document.elementFromPoint(cx,cy);if(!h||!(h===e||e.contains(h)||h.contains(e)))return 'unsafe: covered by '+(h&&h.className||h&&h.tagName);if(h.closest('[role=switch],input,textarea')||/^Send$/.test((h.closest('button')||{}).textContent||''))return 'unsafe: a switch or field';return Math.round(cx*d)+' '+Math.round(cy*d)})()"
}
# tapel <js element> <what>: a real tap on it when safe(); 1 (and a FAIL) otherwise.
tapel() { local p; p=$(safe "$1"); case $p in none|off|unsafe*|"") fail "not tapped: $2 ($p)"; return 1 ;; esac; set -- $p "$2"; tap "$1" "$2" "$3"; }
# until_js <js boolean> <s>: polls it.
until_js() { local i; for i in $(seq 1 $((${2:-6} * 2))); do [ "$(ev "!!($1)")" = true ] && return 0; sleep 0.5; done; return 1; }
screen_app() { ev "($SCR&&$SCR.dataset.app)||'none'"; }
# Scroll the app page until the element is on screen: a swipe up on the page's left margin (no switch is there).
reveal() {
  local i v; for i in 1 2 3 4; do
    v=$(ev "(()=>{const e=($1),s=$SCR;if(!e||!s)return 'none';const r=e.getBoundingClientRect(),q=s.getBoundingClientRect(),d=devicePixelRatio;if(r.top>=q.top&&r.bottom<=Math.min(q.bottom,innerHeight)*0.92)return 'ok';const x=Math.round((q.left+6)*d),h=Math.min(q.bottom,innerHeight)-q.top;return x+' '+Math.round((q.top+h*0.7)*d)+' '+Math.round((q.top+h*0.35)*d)})()")
    case $v in ok) return 0 ;; none|"") return 1 ;; esac
    set -- "$1" $v; swipe "$2" "$3" "$2" "$4" 300 "up on the page's left margin (scroll)" || return 1; sleep 0.8; done; return 1; }
# Search: the pill focused (never typed into anything else), the text, the result for key tapped.
search_open() { # <text> <result key> <name>
  local f; f=$(pt "document.querySelector('.home > .bar textarea')")
  case $f in none|off|"") fail "no search pill on home ($f)"; return 1 ;; esac
  set -- "$@" $f; tap "$4" "$5" "the search pill" || return 1; sleep 1.2; chk pill
  [ "$(ev "document.activeElement&&document.activeElement.matches('.home > .bar textarea')?'yes':'no'")" = yes ] &&
    sh_ "dumpsys window | grep -m1 mCurrentFocus" | grep -q com.powos.app || { fail "the search pill didn't take the focus - nothing typed"; back; return 1; }
  sh_ "input text $1"; sleep 1.5; chk typed
  step "search-$1" "\"$1\" typed into the search pill: the results"
  local p; p=$(pt "document.querySelector('.drawer-list.results .app[data-key=\"$2\"]')")
  case $p in none|off|"") fail "no $3 in the search results ($p)"; back; back; return 1 ;; esac
  # The name first: `set -- $p` replaces $3 (it was unbound under set -u and ended the journey at step 2, 2026-10-23).
  local name=$3; pass "$name in the search results"; set -- $p; tap "$1" "$2" "$name in the results"
}

# The "+ add app" part (from the Apps tab, App API open): three paths, the sample imported, a dry run, discarded.
btn() { echo "[...$SCR.querySelectorAll('button')].find(b=>b.textContent.trim()==='$1')"; }
add_app_journey() {
  tapel "[...$SCR.querySelectorAll('[role=tab]')].find(t=>t.textContent==='Apps')" "the Apps tab" || return 0
  sleep 1; chk apps-again
  local ADD="$SCR.querySelector('[data-add-app]')" t out
  reveal "$ADD"
  tapel "$ADD" "the + add app card" || return 0
  sleep 1.2; chk add-app
  step add-app "+ add app: describe it, an installed app, or import its API - and the drafts"
  t=$(ev "[...$SCR.querySelectorAll('[data-add-path]')].map(e=>e.dataset.addPath).join('|')")
  [ "$t" = "Describe it|From an installed app|Import its API" ] && pass "the three paths: $t" || fail "the add paths: '$t'"
  [ "$(ev "!!($(btn 'Ask PowOS AI'))")" = true ] && pass "Describe it hands PowOS AI a ready prompt (not tapped here)" ||
    note "no Ask PowOS AI button (a shell without askAssistant)"
  local SAMPLE; SAMPLE=$(btn 'Try the Open-Meteo sample')
  reveal "$SAMPLE"
  tapel "$SAMPLE" "Try the Open-Meteo sample" || return 0
  until_js "$SCR.innerText.includes('Open-Meteo (demo capture)')&&!!($(btn 'Discard'))" 8 || { fail "the sample made no draft: $(ev "$SCR.innerText.slice(0,160)")"; return 0; }
  chk draft
  step draft "the Open-Meteo sample as a draft: its actions, dry runs only, Add to my apps / Discard"
  pass "the sample is a draft under review (Add to my apps, Discard)"
  [ "$(ev "!!$SCR.querySelector('[role=switch]')")" = false ] && pass "a draft has no switches" || fail "the draft review shows switches"
  local FC="[...$SCR.querySelectorAll('div')].find(d=>d.textContent==='Get v1 forecast'&&!d.children.length)" DRY
  reveal "$FC"
  if tapel "$FC" "Get v1 forecast"; then sleep 1; chk forecast
    DRY=$(btn 'Dry run'); until_js "$DRY" 5 || fail "the draft's action opened no Dry run"
    reveal "$DRY"
    if tapel "$DRY" "Dry run (draft)"; then
      until_js "[...$SCR.querySelectorAll('pre')].some(p=>/nothing was sent|refused|couldn/.test(p.textContent))" 8; chk draft-dry
      out=$(ev "([...$SCR.querySelectorAll('pre')].pop()||{}).textContent||''")
      reveal "[...$SCR.querySelectorAll('pre')].pop()"
      step draft-dry-run "the draft's dry run: the request it would make, nothing sent"
      grep -q 'dry run - nothing was sent' <<<"$out" && grep -q 'GET https://api.open-meteo.com/v1/forecast' <<<"$out" &&
        pass "the draft dry-runs GET https://api.open-meteo.com/v1/forecast, nothing sent" || fail "the draft's dry run said: $(head -c 200 <<<"$out")"
      [ "$(ev "!!($(btn 'Send'))")" = false ] && pass "no Send on a draft" || fail "a draft offers Send"
    fi
  fi
  local DISC; DISC=$(btn 'Discard')
  reveal "$DISC"
  tapel "$DISC" "Discard" || return 0
  until_js "$SCR.innerText.includes('Add an app')" 6; sleep 0.8; chk discarded
  step discarded "Discard: back on + add app, the draft gone"
  [ "$(ev "!!$SCR.querySelector('[data-draft=\"open-meteo-demo-capture\"]')")" = false ] && pass "the draft is gone from Drafts" || fail "the discarded draft is still listed"
  tapel "$SCR.querySelector('button[aria-label=back]')" "+ add app's back" && sleep 1
  until_js "$SCR&&[...$SCR.querySelectorAll('[role=tab]')].some(t=>t.textContent==='Apps')" 4 || fail "back from + add app: no tabs"
  [ "$(ev "$SCR.innerText.includes('Open-Meteo (demo capture)')")" = false ] && pass "the sample never became one of the apps" || fail "the sample is in the Apps list"
}

# 1. App API from the dock.
p=$(pt "$(dockel p:local.app-api)")
case $p in none|off|"") note "App API isn't in the dock here: from search"; search_open api p:local.app-api "App API" ;;
  *) set -- $p; tap "$1" "$2" "App API's dock cell" ;; esac
sleep 1.5; chk app-api
if until_js "$SCR&&$SCR.dataset.app==='local.app-api'&&$SCR.innerText.includes('Apps')" 8; then
  step apps "App API: the Apps tab - every app's spec, its actions and its switch"
  n=$(ev "String([...$SCR.querySelectorAll('div')].filter(d=>d.style.cursor==='pointer').length)")
  until_js "$SCR.innerText.includes('Philips Hue')" 6 && pass "the Apps tab lists $n app(s), Philips Hue among them" || fail "no Philips Hue in the Apps tab ($n cards): $(ev "$SCR.innerText.slice(0,120)")"

  # 2. Philips Hue: its actions.
  HUE="[...$SCR.querySelectorAll('div')].filter(d=>d.style.cursor==='pointer'&&d.textContent.includes('Philips Hue')).pop()"
  HUENAME="[...($HUE||document).querySelectorAll('div')].find(d=>d.textContent==='Philips Hue'&&!d.children.length)"
  reveal "$HUENAME"
  if tapel "$HUENAME" "Philips Hue's name"; then sleep 1.2; chk hue
    step hue "Philips Hue opened: its actions, by safety"
    ids=$(ev "['list_rooms','list_scenes','set_room','recall_scene','open_lights_page'].filter(a=>$SCR.innerText.includes(a)).join(' ')")
    [ "$(wc -w <<<"$ids" | tr -d ' ')" = 5 ] && pass "Hue's 5 actions listed: $ids" || fail "Hue's actions: '$ids' (want 5)"

    # 3. list_rooms opened, a dry run.
    # Titles are plain words, the raw id muted under them (manager's design notes, 2026-10-24).
    LR="[...$SCR.querySelectorAll('div')].find(d=>d.textContent==='List rooms'&&!d.children.length)"
    [ "$(ev "!!($LR)&&!![...$SCR.querySelectorAll('div')].find(d=>d.textContent==='list_rooms'&&!d.children.length)")" = true ] &&
      pass "list_rooms shows as the title 'List rooms', its id muted under it" || fail "no plain 'List rooms' title with the id under it"
    # The active view tab: the dark foreground on the accent fill (not accent-tinted text on it).
    tc=$(ev "(()=>{const t=[...$SCR.querySelectorAll('[role=tab][aria-selected=true]')].find(x=>x.textContent==='Actions');if(!t)return 'none';const c=getComputedStyle(t),b=getComputedStyle(document.documentElement).getPropertyValue('--color-background').trim();return c.color+' on '+c.backgroundColor+' | bg '+b})()")
    note "the active Actions tab: $tc"
    reveal "$LR"
    if tapel "$LR" "list_rooms"; then sleep 1; chk list-rooms
      DRY="[...$SCR.querySelectorAll('button')].find(b=>b.textContent==='Dry run')"
      until_js "$DRY" 5 || fail "list_rooms opened no Dry run button"
      reveal "$DRY"
      step list-rooms "list_rooms opened: its endpoint, auth handle and output shape"
      pass "list_rooms opened with its Dry run button"
      if tapel "$DRY" "Dry run"; then
        until_js "[...$SCR.querySelectorAll('pre')].some(p=>/nothing was sent|refused|couldn/.test(p.textContent))" 8; chk dry
        out=$(ev "([...$SCR.querySelectorAll('pre')].pop()||{}).textContent||''")
        reveal "[...$SCR.querySelectorAll('pre')].pop()"
        step dry-run "Dry run: the exact request list_rooms would make - nothing sent"
        grep -q 'dry run - nothing was sent' <<<"$out" && grep -qE 'GET https://[^ /]+/clip/v2/resource/room' <<<"$out" && grep -q 'secret:hue' <<<"$out" &&
          pass "the dry run shows GET .../clip/v2/resource/room, the key only as secret:hue, nothing sent" || fail "the dry run said: $(head -c 200 <<<"$out")"
      fi
    fi
    # Back to the list (the header's ‹ in the detail view).
    tapel "$SCR.querySelector('button[aria-label=back]')" "the detail's back" && sleep 1
    until_js "$SCR&&[...$SCR.querySelectorAll('[role=tab]')].some(t=>t.textContent==='Audit')" 4 || { fail "back from Hue's detail: no tabs"; }
  fi

  # 4. Audit: the dry run on top.
  if tapel "[...$SCR.querySelectorAll('[role=tab]')].find(t=>t.textContent==='Audit')" "the Audit tab"; then
    sleep 1.5; chk audit
    step audit "the Audit tab: every call, newest first"
    top=$(ev "(()=>{const c=[...$SCR.querySelectorAll('div')].filter(d=>d.style.borderRadius&&d.textContent.includes('.'))[0];return c?c.innerText.replace(/\\n/g,' | '):$SCR.innerText.slice(0,160)})()")
    grep -q 'hue.list_rooms' <<<"$top" && grep -q 'dry run' <<<"$top" && pass "on top: $top" ||
      { grep -qi 'Nothing has been called' <<<"$top" && fail "the audit log is empty after a dry run" || note "the newest row isn't the dry run: $top"; }
  fi
  # 5. Trackers.
  if tapel "[...$SCR.querySelectorAll('[role=tab]')].find(t=>t.textContent==='Trackers')" "the Trackers tab"; then
    sleep 1.5; chk trackers
    step trackers "the Trackers tab: what the capture proxy saw each app contact"
    t=$(ev "$SCR.innerText.replace(/\\n/g,' | ').slice(0,200)")
    grep -qE 'trackers in|No trackers seen yet' <<<"$t" && pass "the Trackers tab answers: $(cut -c1-120 <<<"${t#*Files | }")" || fail "the Trackers tab: $t"
  fi
  # 6. "+ add app": its three paths; the bundled Open-Meteo OpenAPI sample imported into a draft, one dry run, discarded.
  #    Nothing is sent and nothing is added to the apps: a draft only previews (appcap_add.py).
  add_app_journey
  back 1.2; chk close-api
  step api-closed "Back: App API closed, home again"
  [ "$(screen_app)" = none ] && pass "App API is closed" || { fail "App API still open ($(screen_app))"; ev "window.__powosApps&&window.__powosApps.closeApp(),'x'" >/dev/null; }
else
  step app-api "App API tapped"; fail "App API didn't open ($(screen_app))"
fi

# 7. Lights, once: its pairing to App API. Nothing inside it is touched.
if search_open lights p:local.lights Lights; then
  sleep 1.5; chk lights
  until_js "$SCR&&$SCR.dataset.app==='local.lights'" 6
  sleep 2
  step lights "Lights opened from search (looked at, nothing touched)"
  [ "$(screen_app)" = local.lights ] && pass "Lights is open" || fail "Lights didn't open ($(screen_app))"
  probe=$OUT/link.sh; echo "curl -s -m 5 'http://127.0.0.1:3411/link?app=hue' | head -c 300; echo" > "$probe"
  lk=$("$T/root.sh" "$probe" 2>/dev/null | grep -v "file pushed" | tail -1)
  grep -q '"linked": *true' <<<"$lk" && pass "App API has Hue's pairing from Lights (/link?app=hue: linked)" || fail "App API's /link?app=hue after Lights: $(head -c 160 <<<"$lk")"
  back 1.2; chk close-lights
  [ "$(screen_app)" = none ] || ev "window.__powosApps&&window.__powosApps.closeApp(),'x'" >/dev/null
  step lights-closed "Back: Lights closed"
  [ "$(screen_app)" = none ] && pass "Lights is closed" || fail "Lights still open ($(screen_app))"
fi

# 8. The composed Hue rooms widget on home: its page shown (real swipes from empty space), looked at, back.
hemit system.home null
where=$(ev "(()=>{const e=[...document.querySelectorAll('.page-track [data-key]')].find(x=>/hue-rooms/.test(x.dataset.key));if(!e)return 'none';const pg=e.closest('.page-track > .page');return [...pg.parentElement.children].indexOf(pg)+' '+e.dataset.key})()")
if [ "$where" = none ] || [ -z "$where" ]; then
  step hue-rooms "home: looking for the composed Hue rooms widget"
  inst=$(ev "(window.__powosApps?window.__powosApps.installedApps.value.map(a=>a.id).filter(i=>/hue-rooms/.test(i)).join(' '):'?')")
  # Installed but not on home is the user's layout choice, not a bug: this journey never changes the layout.
  case $inst in ""|"?") fail "no composed Hue rooms widget installed (local.hue-rooms*: '$inst')" ;;
    *) note "the composed Hue rooms widget is installed ($inst) but not on home - not placed by this journey (no layout changes)" ;; esac
else
  set -- $where; WP=$1; WK=$2; d=$((W * 35 / 100)); i=0
  while [ "$(ev "String([...document.querySelectorAll('.page-track > .page')].findIndex(p=>!p.classList.contains('away')))")" -lt "$WP" ] && [ $i -lt 4 ]; do
    p=$(freept "" -1 "$d"); [ "$p" != none ] && [ -n "$p" ] || break; set -- $p; to=$(($1 - d)); [ $to -lt 20 ] && to=20
    swipe "$1" "$2" $to "$2" 250 "to the next page (the widget's)" || break; sleep 1.5; chk swipe; i=$((i + 1)); done
  sleep 1
  step hue-rooms "the composed Hue rooms widget on home ($WK)"
  st=$(ev "(()=>{const e=document.querySelector('.page-track [data-key=\"$WK\"]');if(!e)return 'gone';const r=e.getBoundingClientRect();return (r.right>0&&r.left<innerWidth?'on screen':'off screen')+' | '+e.innerText.replace(/\\n/g,' ').slice(0,100)})()")
  case $st in "on screen"*) pass "the widget shows: ${st#on screen | }" ;; *) fail "the Hue rooms widget: $st" ;; esac
  grep -qiE 'error|failed|refused' <<<"$st" && fail "the widget shows an error: $st"
fi
e2e_finish
