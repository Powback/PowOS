#!/bin/bash
# tools/agents/reply-phone.sh <id> <text...|-> (Mac): answer a phone message the coordinator relay delivered
# (~/.cache/powos-coordinator-inbox.jsonl): `powos comms send <its sender> --from coordinator` on the phone, the body
# "Re <id>: <text>" (-: the text from stdin; use a quoted heredoc for text with $ or backticks). Logged in
# ~/.cache/powos-coordinator-inbox.log. Exit 69: phone offline, nothing sent.
exec python3 "$(cd "$(dirname "$0")" && pwd)/coordinator-relay.py" reply "$@"
