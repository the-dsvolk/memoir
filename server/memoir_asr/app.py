"""WebSocket endpoint `/v1/stream` (DESIGN.md §6) — MVP subset: start / audio / stop, partials and finals.

The asyncio loop only moves bytes and JSON; every model call goes to a single-thread executor, so
the GPU pipeline is used from one thread and the socket never blocks on inference.
"""

import asyncio
import hmac
import json
import logging
from concurrent.futures import ThreadPoolExecutor

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from .engine import Engine
from .protocol import ProtocolError, error, parse_audio_frame, validate_start
from .session import Session
from .settings import Settings
from .store import Store

log = logging.getLogger(__name__)


def create_app(settings: Settings, engine: Engine) -> FastAPI:
    app = FastAPI(title="memoir-asr")
    asr = ThreadPoolExecutor(max_workers=1, thread_name_prefix="asr")
    busy = asyncio.Lock()

    def authorized(ws: WebSocket) -> bool:
        header = ws.headers.get("authorization", "")
        return header.startswith("Bearer ") and hmac.compare_digest(header[7:].strip(), settings.token)

    async def send(ws: WebSocket, msg: dict) -> None:
        await ws.send_text(json.dumps(msg, ensure_ascii=False))

    @app.websocket("/v1/stream")
    async def stream(ws: WebSocket) -> None:
        await ws.accept()
        if not authorized(ws):
            await send(ws, error("unauthorized", "missing or wrong bearer token"))
            await ws.close(code=1008)
            return
        if busy.locked():
            await send(ws, error("busy", "another meeting is being transcribed"))
            await ws.close(code=1013)
            return
        async with busy:
            await run_meeting(ws)

    async def run_meeting(ws: WebSocket) -> None:
        loop = asyncio.get_running_loop()
        try:
            start = validate_start(json.loads(await ws.receive_text()))
        except (ProtocolError, ValueError, WebSocketDisconnect) as e:
            if not isinstance(e, WebSocketDisconnect):
                await send(ws, error("bad_start", str(e)))
                await ws.close(code=1002)
            return

        session = Session(start["meeting_id"], start["sources"], engine.frame_samples, engine.new_stream_id)
        store = Store(settings.data_dir, start, engine.model_label)
        log.info("meeting %s started (%s)", start["meeting_id"], ", ".join(start["sources"]))
        await send(ws, {"type": "ready", "meeting_id": start["meeting_id"], "model": engine.model_label,
                        "chunk_ms": settings.chunk_ms, "resume_from": {s: 0 for s in start["sources"]}})

        connected = True
        audio = asyncio.Event()

        async def emit(messages: list[dict]) -> None:
            nonlocal connected
            for msg in messages:
                if msg["type"] == "final":
                    store.append(msg)
                if connected:
                    try:
                        await send(ws, msg)
                    except Exception:  # client went away mid-send
                        connected = False

        async def pump() -> None:
            while True:
                await audio.wait()
                audio.clear()
                while frames := session.ready_frames():
                    await emit(session.handle(await loop.run_in_executor(asr, engine.step, frames)))

        pump_task = asyncio.create_task(pump())
        try:
            while True:
                msg = await ws.receive()
                if msg["type"] == "websocket.disconnect":
                    connected = False
                    break
                if msg.get("bytes") is not None:
                    try:
                        source, offset, pcm = parse_audio_frame(msg["bytes"])
                    except ProtocolError as e:
                        await send(ws, error("bad_frame", str(e)))
                        continue
                    session.ingest(source, offset, pcm)
                    audio.set()
                elif msg.get("text") is not None:
                    data = json.loads(msg["text"])
                    if data.get("type") == "stop":
                        break
                    if data.get("type") == "note":
                        store.append(data)
        except WebSocketDisconnect:
            connected = False
        finally:
            pump_task.cancel()
            try:
                await pump_task
            except asyncio.CancelledError:
                pass
            # Drain what's buffered, then end every model stream (frees its pipeline state).
            while frames := session.ready_frames():
                await emit(session.handle(await loop.run_in_executor(asr, engine.step, frames)))
            if frames := session.final_frames():
                await emit(session.handle(await loop.run_in_executor(asr, engine.step, frames)))
            await emit(session.flush_partials())
            store.close()
            log.info("meeting %s stopped -> %s", start["meeting_id"], store.path)
            if connected:
                await send(ws, {"type": "stopped", "path": str(store.path.relative_to(settings.data_dir))})
                await ws.close()

    return app
