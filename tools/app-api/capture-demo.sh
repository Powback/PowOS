#!/usr/bin/env bash
# capture-demo.sh - a zero-risk end-to-end demo of the capture -> OpenAPI step.
#
# Captures a few reads from Open-Meteo (a free, public, no-auth, no-account,
# no-spend weather + geocoding API, https://open-meteo.com) into a HAR, then
# runs har2openapi.py on it. Nothing here touches a logged-in account or spends
# money; it is the safe stand-in for the real "use the app normally while a proxy
# records it" flow described in docs/APP-API-CAPTURE.md.
#
#   ./capture-demo.sh            # live capture -> /tmp, then spec to stdout
#   ./capture-demo.sh sample/open-meteo.har   # regenerate the committed sample
set -euo pipefail
cd "$(dirname "$0")"
HAR="${1:-/tmp/open-meteo.har}"

req() {  # method url  -> one HAR entry (request + response), bodies inline
  local method="$1" url="$2" body
  body=$(curl -sS -m 20 "$url")
  python3 - "$method" "$url" "$body" <<'PY'
import json, sys
method, url, body = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
  "startedDateTime": "2026-10-23T00:00:00.000Z",
  "request": {"method": method, "url": url,
              "headers": [{"name": "accept", "value": "application/json"}],
              "queryString": []},
  "response": {"status": 200,
               "content": {"mimeType": "application/json", "text": body}},
}))
PY
}

{
  echo '{"log":{"version":"1.2","creator":{"name":"capture-demo.sh","version":"1"},"entries":['
  first=1
  for u in \
    "https://api.open-meteo.com/v1/forecast?latitude=59.91&longitude=10.75&current=temperature_2m&hourly=temperature_2m" \
    "https://api.open-meteo.com/v1/forecast?latitude=63.43&longitude=10.39&current=temperature_2m,wind_speed_10m" \
    "https://geocoding-api.open-meteo.com/v1/search?name=Oslo&count=3" \
    "https://geocoding-api.open-meteo.com/v1/search?name=Bergen&count=1" ; do
    [ $first -eq 1 ] || echo ","
    first=0
    req GET "$u"
  done
  echo ']}}'
} > "$HAR"

echo "captured -> $HAR" >&2
python3 ./har2openapi.py "$HAR" --title "Open-Meteo (demo capture)" "${@:2}"
