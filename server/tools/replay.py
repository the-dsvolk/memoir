"""Stream a 16 kHz mono 16-bit WAV to the server in real time, print the live transcript, report latency.

Usage (from server/):
    uv run --no-sync python tools/replay.py meeting.wav [--url ws://localhost:8770/v1/stream] [--speed 1.0]

Latency = time from sending the last audio sample a message covers (its `upto`) to receiving it.
"""

import argparse
import asyncio
import json
import os
import statistics
import struct
import sys
import time
import uuid
import wave
from pathlib import Path

import websockets

HEADER = struct.Struct("<B3xQ")
FRAME_SAMPLES = 1600  # 100 ms


def load_pcm(path: str) -> bytes:
    with wave.open(path, "rb") as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (16000, 1, 2):
            sys.exit(f"{path}: need 16 kHz mono 16-bit PCM WAV")
        return w.readframes(w.getnframes())


def token() -> str:
    return os.environ.get("MEMOIR_TOKEN") or Path("~/.config/memoir/token").expanduser().read_text().strip()


async def replay(path: str, url: str, speed: float, tail_s: float) -> None:
    pcm = load_pcm(path)
    sent_at: dict[int, float] = {}  # sample offset at end of each frame -> send time
    latencies = {"partial": [], "final": []}

    async with websockets.connect(url, additional_headers={"Authorization": f"Bearer {token()}"},
                                  max_size=None) as ws:
        await ws.send(json.dumps({"type": "start", "meeting_id": f"replay-{uuid.uuid4().hex[:6]}",
                                  "title": Path(path).name, "sources": ["me"],
                                  "sample_rate": 16000, "encoding": "pcm_s16le"}))
        ready = json.loads(await ws.recv())
        if ready.get("type") != "ready":
            sys.exit(f"server refused: {ready}")
        print(f"ready: {ready['model']}, {ready['chunk_ms']} ms chunks", file=sys.stderr)

        async def sender() -> None:
            t0 = time.monotonic()
            total = len(pcm) // 2
            for start in range(0, total, FRAME_SAMPLES):
                end = min(start + FRAME_SAMPLES, total)
                await asyncio.sleep(max(0.0, t0 + end / 16000 / speed - time.monotonic()))
                await ws.send(HEADER.pack(0, start) + pcm[2 * start: 2 * end])
                sent_at[end] = time.monotonic()
            # Trailing silence lets the end-of-utterance detector close the last sentence, as in a live call.
            silence = bytes(2 * FRAME_SAMPLES)
            for i in range(int(tail_s * 10)):
                await asyncio.sleep(0.1 / speed)
                await ws.send(HEADER.pack(0, total + i * FRAME_SAMPLES) + silence)
            await ws.send(json.dumps({"type": "stop"}))

        send_task = asyncio.create_task(sender())
        async for raw in ws:
            msg = json.loads(raw)
            kind = msg.get("type")
            if kind in ("partial", "final"):
                upto = round(msg["upto"] * 16000)
                sent = next((sent_at[k] for k in sorted(sent_at) if k >= upto), None)
                if sent is not None:
                    latencies[kind].append(time.monotonic() - sent)
                if kind == "partial":
                    print(f"\r\033[K  … {msg['text']}", end="", file=sys.stderr, flush=True)
                else:
                    print(f"\r\033[K[{msg['t0']:6.2f}–{msg['t1']:6.2f}] {msg['text']}", flush=True)
            elif kind == "stopped":
                print(f"\nstopped: {msg['path']}", file=sys.stderr)
                break
            else:
                print(f"\n{msg}", file=sys.stderr)
        await send_task

    for kind, values in latencies.items():
        if values:
            q = statistics.quantiles(values, n=20) if len(values) > 1 else values * 19
            print(f"{kind} latency: p50 {statistics.median(values):.2f} s, p95 {q[18]:.2f} s, "
                  f"max {max(values):.2f} s ({len(values)} messages)", file=sys.stderr)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("wav")
    p.add_argument("--url", default="ws://localhost:8770/v1/stream")
    p.add_argument("--speed", type=float, default=1.0, help="playback speed (1.0 = real time)")
    p.add_argument("--tail", type=float, default=2.0, help="seconds of silence sent after the audio")
    args = p.parse_args()
    asyncio.run(replay(args.wav, args.url, args.speed, args.tail))


if __name__ == "__main__":
    main()
