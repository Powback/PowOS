#!/usr/bin/env python3
"""Short, repeatable OpenAI streaming measurements; no model-quality claims."""
import argparse
import importlib.util
import json
from pathlib import Path
import statistics
import urllib.request

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("url")
p.add_argument("model")
p.add_argument("output", type=Path)
p.add_argument("--key-file", type=Path)
a = p.parse_args()
spec = importlib.util.spec_from_file_location("llm_bench", Path(__file__).with_name("llm-bench.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
headers = {"Content-Type": "application/json"}
if a.key_file:
    headers["Authorization"] = "Bearer " + a.key_file.read_text().strip()

def post(path, body, timeout=600):
    request = urllib.request.Request(a.url.rstrip("/") + path, json.dumps(body).encode(), headers)
    return urllib.request.urlopen(request, timeout=timeout)

bench.post = post
extra = {"chat_template_kwargs": {"enable_thinking": False}}
warm = bench.stream(a.model, "Say hello in one sentence.", 16, extra)
out = {"model": a.model, "first_request_seconds": round(warm[3], 3), "warm_samples": []}
for _ in range(3):
    ttft, rate, tokens, seconds, text = bench.stream(a.model, max_tokens=128, extra=extra)
    row = dict(ttft_ms=round(ttft * 1000, 1), decode_tokens_s=round(rate, 2),
               output_tokens=tokens, seconds=round(seconds, 3), text=text)
    out["warm_samples"].append(row)
    print(json.dumps(row), flush=True)
out["median_decode_tokens_s"] = statistics.median(r["decode_tokens_s"] for r in out["warm_samples"])
out["median_ttft_ms"] = statistics.median(r["ttft_ms"] for r in out["warm_samples"])
# New prefix so this does not reuse the short prompt's prefix cache. Report
# latency, not an inferred prefill rate that would include unrelated overhead.
prompt = "Review these synthetic application logs and give a one-sentence summary.\n" + "\n".join(
    f"request={i} method=GET route=/items/{i % 17} status={500 if i % 43 == 0 else 200} duration_ms={i % 300}"
    for i in range(160))
ttft, rate, tokens, seconds, text = bench.stream(a.model, prompt, 64, extra)
out["long_prompt"] = dict(prompt_characters=len(prompt), ttft_ms=round(ttft * 1000, 1),
                          decode_tokens_s=round(rate, 2), output_tokens=tokens,
                          seconds=round(seconds, 3), text=text)
a.output.write_text(json.dumps(out, indent=2) + "\n")
print(json.dumps({k: v for k, v in out.items() if k != "warm_samples"}), flush=True)
