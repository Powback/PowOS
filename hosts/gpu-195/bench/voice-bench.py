#!/usr/bin/env python3
"""gpu-195 voice path benchmark: each service alone, then the VoiceAgent WebSocket round trip.

Runs inside the voiceagent-backend image (it has httpx, websockets, numpy), on the voice network:
  podman run --rm --network voice --security-opt label=disable -v ~/Projects/PowOS/hosts/gpu-195/bench:/bench:ro \
      localhost/voiceagent-backend:latest python /bench/voice-bench.py [stt|tts|llm|ws|all] [--n 5]

The test utterance is synthesized by the TTS unit itself ("Hey Luna, what time is it?"), resampled to 16 kHz.
Prints one line per measurement plus a JSON summary. Env: STT, TTS, LLM, WS override the URLs.
"""
import asyncio, io, json, os, statistics, sys, time, wave

import httpx
import numpy as np

STT = os.environ.get("STT", "http://voice-stt:8000")
TTS = os.environ.get("TTS", "http://voice-tts:8880")
LLM = os.environ.get("LLM", "http://voice-llm:8000")
WS = os.environ.get("WS", "ws://voice-agent:9000/ws")
PHRASE = os.environ.get("PHRASE", "Hey Luna, what time is it?")
N = int(sys.argv[sys.argv.index("--n") + 1]) if "--n" in sys.argv else 5
OUT = {}


def wav_to_pcm16k(data):
    with wave.open(io.BytesIO(data)) as w:
        sr, ch = w.getframerate(), w.getnchannels()
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    n = int(len(a) * 16000 / sr)
    a = np.interp(np.linspace(0, len(a) - 1, n), np.arange(len(a)), a)
    return a.astype(np.int16)


def pcm_to_wav(pcm, sr=16000):
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(pcm.tobytes())
    return b.getvalue()


def ms(x):
    return round(x * 1000, 1)


def summary(name, xs):
    OUT[name] = {"median_ms": ms(statistics.median(xs)), "min_ms": ms(min(xs)), "n": len(xs)}
    print(f"{name}: median {ms(statistics.median(xs))} ms, min {ms(min(xs))} ms (n={len(xs)})")


def utterance(c):
    r = c.post(f"{TTS}/v1/audio/speech", json={"input": PHRASE, "voice": "bf_emma", "response_format": "wav"})
    r.raise_for_status()
    return wav_to_pcm16k(r.content)


def bench_stt(c, pcm):
    wav = pcm_to_wav(pcm)
    xs = []
    for i in range(N + 1):
        t = time.perf_counter()
        r = c.post(f"{STT}/v1/audio/transcriptions", files={"file": ("a.wav", wav, "audio/wav")},
                   data={"response_format": "json", "language": "en"})
        r.raise_for_status()
        dt = time.perf_counter() - t
        if i:
            xs.append(dt)
        print(f"  stt {ms(dt)} ms: {r.json().get('text', '').strip()!r} ({len(pcm) / 16000:.2f} s audio)")
    summary("stt_latency", xs)


def bench_tts(c):
    text = "It's a quarter past ten. Anything else I can help you with?"
    first, full = [], []
    for i in range(N + 1):
        t = time.perf_counter()
        with c.stream("POST", f"{TTS}/v1/audio/speech",
                      json={"input": text, "voice": "bf_emma", "response_format": "pcm", "stream": True}) as r:
            r.raise_for_status()
            t1 = None
            for chunk in r.iter_bytes():
                if chunk and t1 is None:
                    t1 = time.perf_counter() - t
        t2 = time.perf_counter() - t
        t = time.perf_counter()
        c.post(f"{TTS}/v1/audio/speech", json={"input": text.split(".")[0] + ".", "voice": "bf_emma",
                                                "response_format": "wav"}).raise_for_status()
        t3 = time.perf_counter() - t
        if i:
            first.append(t1); full.append(t3)
        print(f"  tts first audio {ms(t1)} ms (stream done {ms(t2)} ms); one sentence as wav {ms(t3)} ms")
    summary("tts_first_audio_stream", first)
    summary("tts_sentence_wav", full)


def bench_llm(c):
    ttft, tps = [], []
    for i in range(N + 1):
        body = {"model": "qwen3-8b", "stream": True, "max_tokens": 200, "temperature": 0.7,
                "stream_options": {"include_usage": True},
                "chat_template_kwargs": {"enable_thinking": False},
                "messages": [{"role": "system", "content": "You are Luna, a concise voice assistant."},
                             {"role": "user", "content": "Tell me a short story about a lighthouse keeper, in about"
                                                         " a hundred words."}]}
        t = time.perf_counter()
        t1, toks = None, 0
        with c.stream("POST", f"{LLM}/v1/chat/completions", json=body) as r:
            r.raise_for_status()
            for line in r.iter_lines():
                if not line.startswith("data: ") or line == "data: [DONE]":
                    continue
                d = json.loads(line[6:])
                if d.get("usage"):
                    toks = d["usage"]["completion_tokens"]
                if d.get("choices") and d["choices"][0]["delta"].get("content") and t1 is None:
                    t1 = time.perf_counter() - t
        t2 = time.perf_counter() - t
        rate = (toks - 1) / (t2 - t1) if toks > 1 else 0
        if i:
            ttft.append(t1); tps.append(rate)
        print(f"  llm first token {ms(t1)} ms, {toks} tokens, {rate:.1f} tok/s")
    summary("llm_first_token", ttft)
    OUT["llm_tok_per_s"] = round(statistics.median(tps), 1)
    print(f"llm_tok_per_s: median {OUT['llm_tok_per_s']}")


async def ws_once(pcm, verbose=True):
    import websockets
    async with websockets.connect(WS, max_size=None) as ws:
        async def recv_until(pred, timeout):
            end = time.perf_counter() + timeout
            while time.perf_counter() < end:
                m = await asyncio.wait_for(ws.recv(), timeout=max(0.01, end - time.perf_counter()))
                if pred(m):
                    return m
        await recv_until(lambda m: isinstance(m, str) and json.loads(m).get("type") == "config_sync", 30)
        await ws.send(json.dumps({"type": "config", "enable_thinking": False, "provider": "vllm",
                                  "model": os.environ.get("MODEL", "qwen3-8b")}))
        await ws.send(json.dumps({"type": "start"}))
        frame = 512
        lead = np.zeros(16000 // 2, dtype=np.int16)            # 0.5 s of silence before speech
        tail = np.zeros(16000 * 4, dtype=np.int16)              # 4 s of silence after it
        audio = np.concatenate([lead, pcm, tail])
        speech_end_sample = len(lead) + len(pcm)
        t0 = time.perf_counter()
        ev = {"transcript": None, "first_token": None, "first_audio": None, "audio_bytes": 0}
        text, reply = [], []
        t_speech_end = None

        async def reader():
            async for m in ws:
                now = time.perf_counter()
                if isinstance(m, bytes):
                    if ev["first_audio"] is None:
                        ev["first_audio"] = now
                    ev["audio_bytes"] += len(m)
                    continue
                d = json.loads(m)
                if d.get("type") == "transcript" and d.get("final"):
                    ev["transcript"] = ev["transcript"] or now
                    text.append(d.get("text", ""))
                elif d.get("type") == "llm_token":
                    ev["first_token"] = ev["first_token"] or now
                    reply.append(d.get("token", ""))
                elif d.get("type") == "state" and d.get("phase") == "speaking" and ev["first_audio"]:
                    pass
        rt = asyncio.create_task(reader())
        for i in range(0, len(audio), frame):
            await ws.send(audio[i:i + frame].tobytes())
            if t_speech_end is None and i + frame >= speech_end_sample:
                t_speech_end = time.perf_counter()
            target = t0 + (i + frame) / 16000                   # real time pacing
            await asyncio.sleep(max(0, target - time.perf_counter()))
        await asyncio.sleep(3)
        rt.cancel()
        r = {k: (ms(v - t_speech_end) if isinstance(v, float) else v) for k, v in ev.items()}
        r["heard"] = " ".join(text).strip()
        r["reply"] = "".join(reply).strip()[:200]
        if verbose:
            print(f"  ws: end of speech -> final transcript {r['transcript']} ms, first LLM token {r['first_token']}"
                  f" ms, first audio byte {r['first_audio']} ms ({r['audio_bytes']} bytes audio)\n"
                  f"      heard {r['heard']!r}; reply {r['reply']!r}")
        return r


def bench_ws(pcm):
    rs = [asyncio.run(ws_once(pcm)) for _ in range(N)]
    for k in ("transcript", "first_token", "first_audio"):
        xs = [r[k] / 1000 for r in rs if isinstance(r[k], (int, float))]
        if xs:
            summary(f"ws_end_of_speech_to_{k}", xs)
    OUT["ws_example"] = {"heard": rs[-1]["heard"], "reply": rs[-1]["reply"]}


def main():
    what = next((a for a in sys.argv[1:] if not a.startswith("--") and not a.isdigit()), "all")
    with httpx.Client(timeout=120) as c:
        pcm = utterance(c) if what in ("stt", "ws", "all") else None
        if what in ("stt", "all"):
            bench_stt(c, pcm)
        if what in ("tts", "all"):
            bench_tts(c)
        if what in ("llm", "all"):
            bench_llm(c)
    if what in ("ws", "all"):
        bench_ws(pcm)
    print(json.dumps(OUT))


if __name__ == "__main__":
    main()
