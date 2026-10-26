"""Wire protocol (DESIGN.md §6): binary audio frames and JSON messages."""

import struct

# 12-byte header: source (u8), 3 reserved bytes, sample_offset (u64 LE); then PCM s16le, 16 kHz mono.
HEADER = struct.Struct("<B3xQ")
SOURCES = {0: "me", 1: "them", 2: "room"}
SAMPLE_RATE = 16000
# Bumped only when messages or frames change incompatibly; the Mac has the same number (Wire.protocolVersion).
PROTOCOL = 1


class ProtocolError(ValueError):
    """A malformed message from the client."""

    code = "bad_start"


class ProtocolMismatch(ProtocolError):
    """The client speaks another protocol version."""

    code = "protocol_mismatch"


def parse_audio_frame(data: bytes) -> tuple[str, int, bytes]:
    """Split a binary frame into (source name, sample offset, PCM bytes)."""
    if len(data) < HEADER.size:
        raise ProtocolError(f"frame shorter than its {HEADER.size}-byte header")
    source_id, sample_offset = HEADER.unpack_from(data)
    if source_id not in SOURCES:
        raise ProtocolError(f"unknown source {source_id}")
    pcm = data[HEADER.size:]
    if len(pcm) % 2:
        raise ProtocolError("PCM payload has an odd number of bytes")
    return SOURCES[source_id], sample_offset, pcm


def validate_start(msg: dict) -> dict:
    """Check a `start` message and return it with defaults filled in."""
    if msg.get("type") != "start":
        raise ProtocolError("first message must be {\"type\": \"start\", ...}")
    client_protocol = msg.get("protocol", 1)  # clients before 0.3 don't say: they speak 1
    if client_protocol != PROTOCOL:
        side = "the Mac app and CLI" if client_protocol < PROTOCOL else "the server on the Spark"
        raise ProtocolMismatch(f"this server speaks protocol {PROTOCOL}, the client {client_protocol} — update {side}")
    if msg.get("sample_rate", SAMPLE_RATE) != SAMPLE_RATE or msg.get("encoding", "pcm_s16le") != "pcm_s16le":
        raise ProtocolError("only 16 kHz pcm_s16le audio is supported")
    sources = msg.get("sources") or ["me"]
    if any(s not in SOURCES.values() for s in sources):
        raise ProtocolError(f"sources must be among {sorted(SOURCES.values())}")
    meeting_id = str(msg.get("meeting_id") or "").strip()
    if not meeting_id or "/" in meeting_id or meeting_id.startswith("."):
        raise ProtocolError("start needs a meeting_id without '/'")
    return {**msg, "meeting_id": meeting_id, "sources": sources}


def error(code: str, message: str) -> dict:
    return {"type": "error", "code": code, "message": message}
