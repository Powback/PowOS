#!/usr/bin/env python3
"""Benchmark-only Claude launcher for a loopback SSH tunnel to an experimental runtime.

TRIAL_BASE_URL and TRIAL_KEY_FILE are required. MODEL is the first argument.
No changes to the user's saved Claude configuration.
"""
import os
from pathlib import Path
import sys
from urllib.parse import urlparse

model = sys.argv[1]
url = os.environ["TRIAL_BASE_URL"]
if urlparse(url).hostname not in ("127.0.0.1", "localhost", "::1"):
    raise SystemExit("Use a loopback SSH tunnel for experimental benchmark servers")
env = dict(os.environ)
for name in ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
             "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"):
    env.pop(name, None)
env.update(ANTHROPIC_BASE_URL=url,
           ANTHROPIC_AUTH_TOKEN=Path(env["TRIAL_KEY_FILE"]).read_text().strip(),
           CLAUDE_CODE_MAX_CONTEXT_TOKENS="32768", CLAUDE_CODE_MAX_OUTPUT_TOKENS="4096",
           MAX_THINKING_TOKENS="0", API_TIMEOUT_MS="600000",
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
for name in ("ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
             "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
             "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"):
    env[name] = model
os.execvpe("claude", ["claude", "--model", model, *sys.argv[2:]], env)
