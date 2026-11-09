#!/usr/bin/env python3
"""Choose Strata's GPU lease from the voice gateway's fresh idle marker."""
import json
import os
import sys
import time
from pathlib import Path

STATE = Path("/run/powos-voice/voice-gpu-state.json")
SERVER = "/opt/strata/terminal/serve/server.py"
PYTHON = "/opt/strata/terminal/python/bin/python3"
MAX_STATE_AGE = 45


def choose_gpus() -> list[int]:
    try:
        state = json.loads(STATE.read_text())
        age = time.time() - float(state["updated_at_unix"])
        if state.get("state") == "sleeping" and state.get("active_requests") == 0 and age <= MAX_STATE_AGE:
            return [0, 1]
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
        pass
    return [1]


def main() -> None:
    args = sys.argv[1:]
    try:
        config_index = args.index("--config") + 1
        source = Path(args[config_index])
    except (ValueError, IndexError):
        raise SystemExit("strata-voice-aware: expected --config PATH")

    config = json.loads(source.read_text())
    gpus = choose_gpus()
    config["gpu"] = gpus[0] if len(gpus) == 1 else gpus
    port = "unknown"
    if "--port" in args:
        try:
            port = args[args.index("--port") + 1]
        except IndexError:
            pass
    target = Path(f"/tmp/flash-next-{port}.json")
    target.write_text(json.dumps(config, separators=(",", ":")) + "\n")
    os.chmod(target, 0o600)
    args[config_index] = str(target)
    print(f"[gpu-lease] voice={'sleeping' if len(gpus) == 2 else 'awake/unknown'}; Strata GPUs={gpus}", flush=True)
    os.execv(PYTHON, [PYTHON, SERVER, *args])


if __name__ == "__main__":
    main()
