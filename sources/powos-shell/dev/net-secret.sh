#!/usr/bin/env bash
# A PowOS app's host.net secret, from the phone's Android app (ShellNet.kt's private store) to the desktop host's
# (~/.local/share/powos/net/secrets.json, src/net.cpp) on the same phone - or removed again. The value never leaves
# the phone and is never printed: root copies file to file, and only "copied" / "failed" / "removed" comes back.
# Only with the user's say (a key is theirs).
#
#   sources/powos-shell/dev/net-secret.sh copy local.lights hue
#   sources/powos-shell/dev/net-secret.sh remove local.lights hue
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
op=${1:?usage: net-secret.sh copy|remove APP NAME}
app=${2:?app id}
name=${3:?secret name}
[[ $app =~ ^[a-z0-9][a-z0-9.-]{0,63}$ && $name =~ ^[a-zA-Z0-9_.-]{1,64}$ ]] || { echo "bad app or name" >&2; exit 2; }
script=$(mktemp "$HOME/.cache/net-secret.XXXXXX")
trap 'rm -f "$script"' EXIT
T=/root/.powos-net-secret-src.xml
if [ "$op" = copy ]; then
  "$repo/tools/phone/adb.sh" shell "su -c 'install -m 600 -o 0 -g 0 /data/data/com.powos.app/shared_prefs/powos-net-secrets.xml /data/powos/root$T'" >/dev/null
fi
cat >"$script" <<EOF
python3 - <<'PY' >/dev/null 2>&1 && echo ${op/copy/copied} | sed 's/^remove$/removed/' || echo failed
import html, json, os, pwd, re
op, app, name, src = "$op", "$app", "$name", "$T"
d = "/home/powos/.local/share/powos/net"
f = os.path.join(d, "secrets.json")
try:
    data = json.load(open(f))
except Exception:
    data = {}
if op == "copy":
    m = re.search(r'<string name="' + re.escape(app) + '&#0;' + re.escape(name) + r'">(.*?)</string>', open(src, encoding="utf-8").read(), re.S)
    if not m:
        raise SystemExit(1)
    data[app + "/" + name] = html.unescape(m.group(1))
else:
    data.pop(app + "/" + name, None)
os.makedirs(d, mode=0o700, exist_ok=True)
fd = os.open(f + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as out:
    json.dump(data, out, separators=(",", ":"))
pw = pwd.getpwnam("powos")
os.chown(f + ".new", pw.pw_uid, pw.pw_gid)
os.chown(d, pw.pw_uid, pw.pw_gid)
os.chmod(d, 0o700)
os.replace(f + ".new", f)
PY
rm -f $T
EOF
"$repo/tools/phone/root.sh" "$script" 2>&1 | grep -v ' pushed'
