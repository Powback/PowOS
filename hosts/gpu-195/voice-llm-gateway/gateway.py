"""Private control and OpenAI proxy for the shared voice/code GPUs.

The vLLM sleep/wake endpoints are deliberately never forwarded to clients.
The public :8100 listener only accepts OpenAI /v1 routes and /health.
"""
import asyncio
import fcntl
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
IDLE_SECONDS = max(30, int(os.getenv("VOICE_LLM_IDLE_SECONDS", "300")))
GPU_DRAIN_TIMEOUT = max(60, int(os.getenv("VOICE_GPU_DRAIN_TIMEOUT", "1800")))
STATE_FILE = Path(os.getenv("VOICE_GPU_STATE_FILE", "/state/voice-gpu-state.json"))
# GPU0 wake-room lease (shared with local-llm-stack llm-pool/gpu0_lease.py). A pool model that borrows voice-llm's GPU0
# room while it sleeps holds this flock for its whole life; waking voice takes it first. Created by install.sh.
GPU0_LEASE_LOCK = Path(os.getenv("GPU0_LEASE_LOCK", "/gpu-lease/gpu0-wake-room.lock"))
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


def lease_holder() -> str:
    try:
        return GPU0_LEASE_LOCK.read_text().strip() or "unknown holder"
    except OSError:
        return "unknown holder"


async def take_gpu0_wake_room() -> int | None:
    """Block (bounded) until no pool model borrows GPU0's wake room; never kill a live session.

    Called after the state file says "waking", so a launcher that takes the lock afterwards re-reads the state, backs
    off, and releases it. Returns the held fd (release after the wake), or None when the lock file is missing: then no
    launcher can borrow either (they never create it), so voice wakes.
    """
    try:
        fd = os.open(GPU0_LEASE_LOCK, os.O_RDWR | os.O_CLOEXEC)
    except OSError as exc:
        log.error("GPU0 lease lock %s unavailable (%s); pool borrowing is off, waking voice", GPU0_LEASE_LOCK, exc)
        return None
    deadline = time.monotonic() + GPU_DRAIN_TIMEOUT
    next_note = time.monotonic() + 1
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            pass
        if time.monotonic() >= deadline:
            os.close(fd)
            raise RuntimeError(
                f"GPU0 wake room still borrowed after {GPU_DRAIN_TIMEOUT}s ({lease_holder()}); "
                "leaving its session untouched; retry voice request"
            )
        if time.monotonic() >= next_note:
            log.info("GPU0 wake room borrowed by %s; waiting for its session and natural unload", lease_holder())
            next_note = time.monotonic() + 30
        await asyncio.sleep(0.25)


def release_gpu0_wake_room(fd: int | None) -> None:
    if fd is not None:
        os.close(fd)  # closing the only descriptor drops the flock


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
    lease = await take_gpu0_wake_room()
    try:
        response = await client.post(f"{VOICE_URL}/wake_up", timeout=180)
        response.raise_for_status()
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            sleeping = await is_sleeping()
            if sleeping is False:
                write_state("awake")
                log.info("voice LLM woke; GPU0 wake room returned to voice")
                return
            await asyncio.sleep(0.25)
        raise RuntimeError("voice LLM wake timed out")
    finally:
        # Released while the state says "awake" or "waking": a launcher that then gets the lock reads a non-sleeping
        # state and does not borrow.
        release_gpu0_wake_room(lease)


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
