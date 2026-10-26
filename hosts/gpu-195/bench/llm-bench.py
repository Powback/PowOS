#!/usr/bin/env python3
"""gpu-195 LLM pool benchmark (llama-swap :9292 / http://llm-gpu.pow). Python stdlib only: runs on the box's own
python3 or any PowOS, nothing to install.

  python3 llm-bench.py [general|nothink|vision|embed|tools|concurrent|all] [--url http://127.0.0.1:9292] [--n 3]

  general/nothink  time to first token and decode tokens/s, one stream, warm (a first request loads the model and
                   is reported apart as the cold start)
  concurrent       4 streams at once: aggregate tokens/s
  tools            one tool call comes back as tool_calls
  vision           a generated image (a red square on white) is described
  embed            /v1/embeddings: dimension and texts/s for 64 short texts
Prints one line per measurement plus a JSON summary.
"""
import base64, json, statistics, struct, sys, threading, time, urllib.request, zlib

URL = sys.argv[sys.argv.index("--url") + 1] if "--url" in sys.argv else "http://127.0.0.1:9292"
N = int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 3
OUT = {}
PROMPT = "Write a short paragraph (about 200 words) on why idle GPUs should unload their models."


def post(path, body, timeout=900):
    req = urllib.request.Request(URL + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=timeout)


def stream(model, prompt=PROMPT, max_tokens=300, extra=None):
    """-> (ttft s, decode tok/s, completion tokens, total s, text)"""
    body = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": max_tokens,
            "temperature": 0.7, "stream": True, "stream_options": {"include_usage": True}, **(extra or {})}
    t0 = time.perf_counter(); first = None; toks = 0; text = []
    with post("/v1/chat/completions", body) as r:
        for line in r:
            line = line.strip()
            if not line.startswith(b"data:") or line == b"data: [DONE]":
                continue
            d = json.loads(line[5:])
            if d.get("usage"):
                toks = d["usage"]["completion_tokens"]
            for c in d.get("choices", []):
                delta = c.get("delta", {})
                piece = delta.get("content") or delta.get("reasoning_content") or delta.get("reasoning")
                if piece:
                    if first is None:
                        first = time.perf_counter()
                    text.append(piece)
    end = time.perf_counter()
    first = first or end
    rate = (toks - 1) / (end - first) if toks > 1 and end > first else 0.0
    return first - t0, rate, toks, end - t0, "".join(text)


def running():
    try:
        return [m.get("model") for m in json.load(urllib.request.urlopen(URL + "/running", timeout=5))["running"]]
    except Exception:
        return []


def bench_chat(name, model, extra=None):
    if model.split("-")[0] not in running():
        ttft, rate, toks, total, _ = stream(model, "Say hi.", 8, extra)
        print(f"  {name}: cold start (load + first answer) {total:.1f} s")
        OUT[f"{name}_cold_s"] = round(total, 1)
    ttfts, rates = [], []
    for _ in range(N):
        ttft, rate, toks, total, text = stream(model, extra=extra)
        ttfts.append(ttft); rates.append(rate)
        print(f"  {name}: first token {ttft * 1000:.0f} ms, decode {rate:.1f} tok/s ({toks} tokens, {total:.1f} s)")
    OUT[f"{name}_ttft_ms"] = round(statistics.median(ttfts) * 1000)
    OUT[f"{name}_decode_tok_s"] = round(statistics.median(rates), 1)
    OUT[f"{name}_example"] = text[:160]


def bench_concurrent(model="general-nothink", k=4):
    stream(model, "Say hi.", 8)  # loaded
    res = [None] * k

    def one(i):
        res[i] = stream(model)
    t0 = time.perf_counter()
    th = [threading.Thread(target=one, args=(i,)) for i in range(k)]
    [t.start() for t in th]; [t.join() for t in th]
    wall = time.perf_counter() - t0
    toks = sum(r[2] for r in res)
    print(f"  concurrent x{k}: {toks} tokens in {wall:.1f} s = {toks / wall:.1f} tok/s aggregate, "
          f"per stream {statistics.median(r[1] for r in res):.1f} tok/s")
    OUT[f"concurrent{k}_aggregate_tok_s"] = round(toks / wall, 1)
    OUT[f"concurrent{k}_per_stream_tok_s"] = round(statistics.median(r[1] for r in res), 1)


def bench_tools():
    tools = [{"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city",
              "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
    body = {"model": "general-nothink", "messages": [{"role": "user", "content": "What's the weather in Oslo?"}],
            "tools": tools, "max_tokens": 200}
    t0 = time.perf_counter()
    d = json.load(post("/v1/chat/completions", body))
    calls = d["choices"][0]["message"].get("tool_calls") or []
    ok = bool(calls) and calls[0]["function"]["name"] == "get_weather"
    print(f"  tools: {'ok' if ok else 'FAIL'} {calls[0]['function'] if calls else d['choices'][0]['message']} "
          f"({time.perf_counter() - t0:.2f} s)")
    OUT["tools_ok"] = ok


def png_red_square(w=128):
    rows = b"".join(b"\0" + b"".join(b"\xff\x00\x00" if w // 4 <= x < 3 * w // 4 and w // 4 <= y < 3 * w // 4
                                     else b"\xff\xff\xff" for x in range(w)) for y in range(w))

    def chunk(t, data):
        return struct.pack(">I", len(data)) + t + data + struct.pack(">I", zlib.crc32(t + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, w, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def bench_vision():
    img = "data:image/png;base64," + base64.b64encode(png_red_square()).decode()
    msg = [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": img}},
                                        {"type": "text", "text": "What shape and colour is in this image? One line."}]}]
    if "vision" not in running():
        t0 = time.perf_counter()
        json.load(post("/v1/chat/completions", {"model": "vision", "messages": msg, "max_tokens": 5}))
        OUT["vision_cold_s"] = round(time.perf_counter() - t0, 1)
        print(f"  vision: cold start (load + first answer) {OUT['vision_cold_s']} s")
    t0 = time.perf_counter()
    d = json.load(post("/v1/chat/completions", {"model": "vision", "messages": msg, "max_tokens": 40}))
    ans = d["choices"][0]["message"]["content"]
    print(f"  vision: {ans!r} ({time.perf_counter() - t0:.2f} s)")
    OUT["vision_answer"] = ans
    OUT["vision_ok"] = "red" in ans.lower() and "square" in ans.lower()
    ttft, rate, toks, total, _ = stream("vision")
    print(f"  vision text: first token {ttft * 1000:.0f} ms, decode {rate:.1f} tok/s")
    OUT["vision_decode_tok_s"] = round(rate, 1)


def bench_embed():
    texts = [f"note {i}: the voice path stays on GPU0 and the pool unloads after ten idle minutes" for i in range(64)]
    if "embed" not in running():
        t0 = time.perf_counter()
        json.load(post("/v1/embeddings", {"model": "embed", "input": ["warm up"]}))
        OUT["embed_cold_s"] = round(time.perf_counter() - t0, 1)
        print(f"  embed: cold start {OUT['embed_cold_s']} s")
    t0 = time.perf_counter()
    d = json.load(post("/v1/embeddings", {"model": "embed", "input": texts}))
    dt = time.perf_counter() - t0
    dim = len(d["data"][0]["embedding"])
    print(f"  embed: {len(d['data'])} texts, dim {dim}, {dt * 1000:.0f} ms ({len(texts) / dt:.0f} texts/s)")
    OUT["embed_dim"] = dim
    OUT["embed_texts_s"] = round(len(texts) / dt)


def main():
    what = next((a for a in sys.argv[1:] if not a.startswith("--") and not a.replace(".", "").isdigit()
                 and not a.startswith("http")), "all")
    if what in ("general", "all"):
        bench_chat("general", "general")
    if what in ("nothink", "all"):
        bench_chat("nothink", "general-nothink")
    if what in ("concurrent", "all"):
        bench_concurrent()
    if what in ("tools", "all"):
        bench_tools()
    if what in ("embed", "all"):
        bench_embed()
    if what in ("vision", "all"):
        bench_vision()
    print(json.dumps(OUT))


if __name__ == "__main__":
    main()
