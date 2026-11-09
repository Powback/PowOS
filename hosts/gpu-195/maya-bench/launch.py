"""Prepare the downloaded S24 pack and serve it within the benchmark container."""
import json
import os
from pathlib import Path
import secrets
import subprocess

os.umask(0o077)
root = Path("/models")
pack = root / "Maya-S24/pack-s24"
shard = root / "Maya-S24/GLM-5.3-Flash-Maya-S24-IQ2_XXS_S-00001-of-00003.gguf"
if len(list(shard.parent.glob("*.gguf"))) != 3:
    raise SystemExit("Wait for all three pinned Maya-S24 shards to finish downloading")
required = ["index.txt", "native_experts.txt", "dense.bin", "tokenizer/vocab.json",
            "tokenizer/merges.txt", "tokenizer/token_type.json", "tokenizer/chat_template.jinja"]
if not all((pack / f).is_file() for f in required):
    subprocess.run(["python3", "tools/iq_pack.py", "--gguf", str(shard), "--out", str(pack),
                    "--compat-bf16"], check=True, cwd="/opt/maya",
                   env=dict(os.environ, STRATA_GGUF_PY="/opt/maya/third_party/llama.cpp/gguf-py"))
key = root / ".bench-api-key"
if not key.exists():
    key.write_text(secrets.token_hex(24) + "\n")
config = root / "bench-s24.json"
config.write_text(json.dumps({
    "exe": "/opt/maya/build/maya", "cwd": "/opt/maya", "log": "/models/engine.log",
    "args": ["--glm-pack", str(pack), "--expert-profile", "/opt/maya/data/expert-profile-glm.bin",
             "--max-context", "32768", "--expert-cache", "auto",
             "--prefill", "auto", "--kv-streaming", "on", "--vram-reserve-mib", "1536"],
    "tokenizer": str(pack / "tokenizer"), "model_name": "glm-5.3-flash", "gpu": [0],
    "sampling": {"temperature": 1.0, "top_p": 0.95}, "reasoning_effort": "none",
    "env": {"STRATA_GLM_RAM_GB": os.environ.get("MAYA_BENCH_RAM_GB", "36"), "STRATA_GLM_CPU_LANE": "3"},
    "host": "0.0.0.0", "port": 8080, "api_key": key.read_text().strip(),
    "engine_ready_s": 1800
}, indent=2) + "\n")
os.chdir("/opt/maya")
os.execvp("python3", ["python3", "-m", "serve.server", "--engine", "strata",
                       "--config", str(config), "--host", "0.0.0.0", "--port", "8080"])
