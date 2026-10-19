#!/bin/bash
# omalauncher: recon of an Android app widget, for recreating it as an OWL widget (see the README's "Recreating
# an Android widget" and widgets/recon/WidgetRecon.kt). Drops a request into .recon/inbox, like owl-send, and
# waits for the launcher, which binds the widget for a few seconds, captures it and deletes it again.
set -u
dir="$HOME/.config/omalauncher/widgets"
recon="$dir/.recon"

usage() {
  cat >&2 <<USAGE
usage: owl-recon list [text]
       owl-recon <provider> [WxH] [--seconds N] [--configure] [--static]

list prints the phone's widget providers (package/class, label, app, default
size in dp), optionally only those matching text.

<provider> is package/class as list prints it, or a package with one widget.
The capture goes to $recon/<provider>/:
  recon.json      provider info, the view tree, the RemoteViews actions, updates
  screenshot.png  the widget as Android draws it, at WxH dp (default: its own size)
  images/         every picture in it; preview*.png: the provider's previews
--seconds N watches the provider's updates for N seconds first (default 6).
--configure runs the widget's setup screen on the phone first.
--static doesn't bind the widget: its layout as the app ships it, without data.
The first recon waits (up to 3 minutes) for the user to allow PowOS to create
widgets on the phone; without that it falls back to --static.
USAGE
  exit 2
}

[ $# -ge 1 ] || usage
case $1 in -h | --help) usage ;; esac
lines=()
if [ "$1" = list ]; then
  lines=(list "filter=${2:-}")
  wait=100
else
  lines=(capture "provider=$1")
  shift
  seconds=6
  while [ $# -gt 0 ]; do
    case $1 in
      [0-9]*x[0-9]*) lines+=("width=${1%x*}" "height=${1#*x}") ;;
      --seconds) seconds=${2:?}; shift ;;
      --configure) lines+=(configure=1) ;;
      --static) lines+=(static=1) ;;
      *) usage ;;
    esac
    shift
  done
  lines+=("seconds=$seconds")
  # Room for the permission dialog or the widget's setup (3 minutes), then the capture itself.
  wait=$(((seconds + 200) * 10))
fi

inbox="$recon/inbox"
if [ ! -d "$inbox" ]; then
  echo "owl-recon: $inbox is missing; is the launcher running (and up to date)?" >&2
  exit 1
fi
id="$(date +%s%N)-$$"
printf '%s\n' "${lines[@]}" >"$inbox/.$id.tmp"
mv "$inbox/.$id.tmp" "$inbox/$id.req"

shown=0
for ((i = 0; i < wait; i++)); do
  if [ -f "$inbox/$id.status" ]; then
    n=$(wc -l <"$inbox/$id.status")
    if [ "$n" -gt "$shown" ]; then
      tail -n +$((shown + 1)) "$inbox/$id.status" | sed 's/^/owl-recon: /' >&2
      shown=$n
    fi
  fi
  if [ -f "$inbox/$id.done" ]; then
    reply=$(cat "$inbox/$id.done")
    rm -f "$inbox/$id.done" "$inbox/$id.status"
    head=${reply%%$'\n'*}
    body=${reply#*$'\n'}
    [ "$body" = "$reply" ] && body=
    if [ "$head" = ok ]; then
      if [ "${lines[0]}" = capture ]; then
        name=${body%%$'\n'*}
        echo "$recon/$name/recon.json"
        echo "$recon/$name/screenshot.png"
        printf '%s\n' "${body#*$'\n'}"
      else
        printf '%s\n' "$body"
      fi
      exit 0
    fi
    echo "owl-recon: ${head#error: }" >&2
    [ -n "$body" ] && printf '%s\n' "$body" >&2
    exit 1
  fi
  sleep 0.1
done
rm -f "$inbox/$id.req" "$inbox/$id.status"
echo "owl-recon: the launcher didn't answer; is it running?" >&2
exit 1
