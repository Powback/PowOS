"""Private control and OpenAI proxy for the shared voice/code GPUs.

The vLLM sleep/wake endpoints are deliberately never forwarded to clients.
The public :8100 listener only accepts OpenAI /v1 routes and /health.
"""
import asyncio
import json
import logging
import os
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import Response, StreamingResponse

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("voice-llm-gateway")
logging.getLogger("httpx").setLevel(logging.WARNING)

VOICE_URL = os.getenv("VOICE_LLM_URL", "http://voice-llm:8000").rstrip("/")
POOL_URL = os.getenv("LLM_POOL_URL", "http://host.containers.internal:9292").rstrip("/")
IDLE_SECONDS = max(30, int(os.getenv("VOICE_LLM_IDLE_SECONDS", "300")))
GPU_DRAIN_TIMEOUT = max(60, int(os.getenv("VOICE_GPU_DRAIN_TIMEOUT", "1800")))
GPU0_VOICE_RESERVE_BYTES = int(float(os.getenv("GPU0_VOICE_RESERVE_GIB", "8")) * 1024**3)
STATE_FILE = Path(os.getenv("VOICE_GPU_STATE_FILE", "/state/voice-gpu-state.json"))
STATE_FILE.parent.mkdir(parents=True, exist_ok=True)

client = httpx.AsyncClient(
    timeout=httpx.Timeout(connect=5, read=None, write=60, pool=5),
    follow_redirects=False,
)
transition_lock = asyncio.Lock()
active_requests = 0
last_activity = time.monotonic()
state = "awake"
sleep_supported: bool | None = None

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
}


def write_state(value: str, *, detail: str | None = None) -> None:
    global state
    state = value
    payload = {
        "state": state,
        "active_requests": active_requests,
        "idle_seconds": IDLE_SECONDS,
        "last_activity_unix": time.time() - (time.monotonic() - last_activity),
        "updated_at_unix": time.time(),
    }
    if detail:
        payload["detail"] = detail
    fd, temp_name = tempfile.mkstemp(prefix="voice-gpu-state-", dir=STATE_FILE.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_name, STATE_FILE)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


async def is_sleeping() -> bool | None:
    global sleep_supported
    try:
        response = await client.get(f"{VOICE_URL}/is_sleeping", timeout=5)
        if response.status_code == 404:
            sleep_supported = False
            return None
        response.raise_for_status()
        data = response.json()
        sleep_supported = True
        value = data.get("is_sleeping", data.get("sleeping"))
        return value if isinstance(value, bool) else None
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("could not read vLLM sleep state: %s", exc)
        return None


async def gpu0_memory_used_bytes() -> int | None:
    """Read host GPU memory from llama-swap's global metrics, available during generation."""
    try:
        response = await client.get(f"{POOL_URL}/metrics", timeout=5)
        response.raise_for_status()
        for line in response.text.splitlines():
            if line.startswith("llamaswap_gpu_memory_used_bytes{") and 'id="0"' in line:
                return int(float(line.rsplit(maxsplit=1)[1]))
    except (httpx.HTTPError, ValueError, IndexError) as exc:
        log.warning("could not read GPU0 memory from llama-swap metrics: %s", exc)
    return None


async def free_dual_gpu_flash_next() -> None:
    """Wait only when Flash Next actually holds GPU0; never kill a live session."""
    deadline = time.monotonic() + GPU_DRAIN_TIMEOUT
    next_note = time.monotonic()
    needs_gpu0 = False
    while time.monotonic() < deadline:
        try:
            response = await client.get(f"{POOL_URL}/running", timeout=5)
            response.raise_for_status()
            running = response.json().get("running", [])
        except (httpx.HTTPError, ValueError) as exc:
            raise RuntimeError(f"cannot verify local model sessions; refusing to interrupt them: {exc}") from exc

        if not any(model.get("model") == "flash-next" for model in running):
            if needs_gpu0:
                log.info("Flash Next exited naturally; GPU0 is clear for voice")
            return

        # The upstream metrics route is subject to flash-next's concurrencyLimit
        # and returns 429 during generation. llama-swap's global /metrics is not;
        # use GPU0's actual VRAM to distinguish a GPU1-only session from a dual-GPU
        # lease, even while the coding model is actively generating.
        gpu0_used = await gpu0_memory_used_bytes()
        if gpu0_used is not None and gpu0_used < GPU0_VOICE_RESERVE_BYTES:
            log.info(
                "Flash Next is not using GPU0 (%.1f GiB used, %.1f GiB reserve threshold); waking voice alongside the active session",
                gpu0_used / 1024**3,
                GPU0_VOICE_RESERVE_BYTES / 1024**3,
            )
            return

        needs_gpu0 = True
        if time.monotonic() >= next_note:
            if gpu0_used is None:
                log.info("GPU0 lease is unknown; waiting safely without interrupting the running model")
            else:
                log.info(
                    "Flash Next currently uses GPU0 (%.1f GiB); waiting for its session and natural unload before waking voice",
                    gpu0_used / 1024**3,
                )
            next_note = time.monotonic() + 30
        await asyncio.sleep(1)

    raise RuntimeError(
        f"Flash Next still holds both GPUs after {GPU_DRAIN_TIMEOUT}s; leaving its session untouched; retry voice request"
    )


async def wake_voice_if_needed() -> None:
    deadline = time.monotonic() + 180
    sleeping = await is_sleeping()
    while sleeping is None and sleep_supported is not False and time.monotonic() < deadline:
        # vLLM can spend a minute loading weights on startup. Hold the voice
        # request until its control API is ready instead of failing it early.
        await asyncio.sleep(1)
        sleeping = await is_sleeping()
    if sleeping is False or (sleeping is None and sleep_supported is False):
        write_state("awake", detail="vLLM sleep mode unavailable; dual-GPU lease disabled" if sleep_supported is False else None)
        return
    if sleeping is None:
        raise RuntimeError("vLLM sleep state endpoint unavailable after startup wait")

    write_state("waking")
    await free_dual_gpu_flash_next()
    response = await client.post(f"{VOICE_URL}/wake_up", timeout=180)
    response.raise_for_status()
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        sleeping = await is_sleeping()
        if sleeping is False:
            write_state("awake")
            log.info("voice LLM woke; dual-GPU lease returned to voice")
            return
        await asyncio.sleep(0.25)
    raise RuntimeError("voice LLM wake timed out")


async def acquire_voice_request() -> None:
    global active_requests, last_activity
    async with transition_lock:
        active_requests += 1
        last_activity = time.monotonic()
        write_state("awake" if state != "sleeping" else "waking")
        try:
            await wake_voice_if_needed()
        except Exception:
            active_requests -= 1
            last_activity = time.monotonic()
            write_state("awake", detail="wake failed; dual-GPU lease disabled")
            raise


async def release_voice_request() -> None:
    global active_requests, last_activity
    async with transition_lock:
        active_requests = max(0, active_requests - 1)
        last_activity = time.monotonic()
        write_state("awake")


async def idle_offload_loop() -> None:
    global last_activity
    while True:
        if active_requests:
            await asyncio.sleep(1)
            continue

        remaining = IDLE_SECONDS - (time.monotonic() - last_activity)
        if remaining > 0:
            await asyncio.sleep(min(remaining, 15))
            # A short heartbeat keeps the shared state fresh for the Strata launcher.
            if state == "sleeping":
                async with transition_lock:
                    if not active_requests:
                        write_state("sleeping")
            continue

        async with transition_lock:
            if active_requests or time.monotonic() - last_activity < IDLE_SECONDS:
                continue
            sleeping = await is_sleeping()
            if sleeping is None:
                write_state("awake", detail="sleep unsupported or unavailable")
                await asyncio.sleep(15)
                continue
            if sleeping:
                write_state("sleeping")
                continue
            write_state("sleeping-pending")
            try:
                response = await client.post(f"{VOICE_URL}/sleep?level=1", timeout=180)
                response.raise_for_status()
                sleeping = await is_sleeping()
                if sleeping:
                    write_state("sleeping")
                    log.info("voice LLM idle for %d seconds; weights offloaded to host RAM", IDLE_SECONDS)
                else:
                    write_state("awake", detail="vLLM did not confirm sleep")
            except Exception as exc:
                write_state("awake", detail=f"sleep failed: {type(exc).__name__}")
                log.exception("idle vLLM sleep failed")
                await asyncio.sleep(15)


@asynccontextmanager
async def lifespan(_: FastAPI):
    global last_activity
    last_activity = time.monotonic()
    sleeping = await is_sleeping()
    write_state("sleeping" if sleeping else "awake")
    task = asyncio.create_task(idle_offload_loop(), name="voice-llm-idle-offload")
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        await client.aclose()


app = FastAPI(lifespan=lifespan)


@app.get("/health")
async def health():
    return {"status": "ok", "voice_state": state, "active_requests": active_requests, "idle_seconds": IDLE_SECONDS}


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def proxy(request: Request, path: str):
    if not path.startswith("v1/"):
        raise HTTPException(status_code=404, detail="route not exposed")

    try:
        await acquire_voice_request()
    except Exception as exc:
        log.exception("could not wake voice LLM")
        raise HTTPException(status_code=503, detail=f"voice LLM unavailable: {exc}") from exc
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP_BY_HOP}
    upstream_request = client.build_request(
        request.method,
        f"{VOICE_URL}/{path}",
        params=request.query_params,
        headers=headers,
        content=await request.body(),
    )
    try:
        upstream = await client.send(upstream_request, stream=True)
    except Exception:
        await release_voice_request()
        raise

    response_headers = {k: v for k, v in upstream.headers.items() if k.lower() not in HOP_BY_HOP}
    if upstream.status_code >= 400:
        content = await upstream.aread()
        await upstream.aclose()
        await release_voice_request()
        return Response(content, status_code=upstream.status_code, headers=response_headers)

    async def body() -> AsyncIterator[bytes]:
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await upstream.aclose()
            await release_voice_request()

    return StreamingResponse(body(), status_code=upstream.status_code, headers=response_headers)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080, access_log=False)
