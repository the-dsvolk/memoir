# memoir — Design

**Status:** draft v1 · 2026-10-17 · owner: the-dsvolk
**Supersedes:** the first "System Blueprint: Real-Time macOS Meeting Transcription" draft (BlackHole +
Qwen-Audio-Chat). What changed and why is in [Appendix A](#appendix-a--changes-from-the-first-blueprint).

## 1. Goal

While I'm on a video call (Zoom, Microsoft Teams, WebEx) on the Mac, show a **live transcript** in a
small always-on-top window, labelled **Me** (my microphone) and **Them** (the call's audio), and **keep
a record** of every meeting. The Mac only captures and displays; transcription runs on the DGX Spark
`spark-0e81` on the home LAN — the same split qmx uses.

**v1 success criteria**

- Partial (in-progress) text on screen **≤ 1.0 s p50** after the words are spoken; final text for an
  utterance **≤ 1.2 s** after the speaker stops.
- A 60-minute call runs without lag building up, and survives switching to AirPods mid-call.
- Every meeting is saved as JSONL + Markdown with per-utterance timestamps.

**Non-goals (v1)** — summaries, telling apart *multiple* remote speakers, translation, more than one
client or one meeting at a time, use away from the home LAN, any cloud service.

## 2. Settled decisions

| # | Decision | Instead of | Why |
|---|---|---|---|
| D1 | **Inference on `spark-0e81` only** (for now) | `spark-0f50`, both | One host to operate; it already runs qmx. `spark-0f50` is the later fail-over. |
| D2 | **Qwen3-ASR** (start with **1.7B**, fall back to 0.6B) | Qwen-Audio-Chat (~8B) | Dedicated ASR model, native streaming API, Apache-2.0, small enough for live latency. |
| D3 | **Core Audio process taps** for call audio | BlackHole + Multi-Output Device | No driver; volume keys keep working; follows the call app, not an output device. |
| D4 | **Mic captured separately** → two streams, Me / Them | One mixed Aggregate Device | Speaker labels for free; lets us handle echo/bleed. |
| D5 | **Server cuts speech into utterances (VAD)** and streams each one | Fixed 1.5 s windows | Qwen3-ASR streaming re-reads the whole utterance each chunk, so utterances must stay short. |
| D6 | **Port 8770** on the Spark | 8000 | 8000 is vLLM's default; 8770 sits next to qmx's 8765 and is free. |

## 3. Architecture

```
 Mac — memoir.app (Swift)                          spark-0e81 — memoir-asr (Python, vLLM container)
 ─────────────────────────                         ────────────────────────────────────────────────
 Zoom / Teams / WebEx output                        WebSocket :8770  (bearer token)
   └─ Core Audio process tap ──┐                      │
                               ├─ resample → 16 kHz   ├─ per source: Silero VAD → utterances (≤ 20 s)
 Microphone (AVAudioEngine) ───┘   mono s16, 100 ms   │
                                   frames tagged      ├─ ASR worker (one thread, owns the model)
                                   Me / Them ───────► │    Qwen3-ASR-1.7B  streaming_transcribe()
                                                      │    → partial every ~1 s, final at end of speech
 Overlay HUD (NSPanel) ◄──── partial / final JSON ────┤
 Menu bar: start/stop, app + mic pickers              └─ ~/.memoir/meetings/<date>/<id>.jsonl (+ .md)
```

| Subsystem | Runs on | Components |
|---|---|---|
| Call-audio capture | Mac | `AudioHardwareCreateProcessTap`, private aggregate device, IOProc → ring buffer |
| Mic capture | Mac | `AVAudioEngine` input node, `AVAudioConverter` |
| Streaming client | Mac | `URLSessionWebSocketTask`, framing, reconnect + 30 s resend buffer |
| UI | Mac | SwiftUI in an AppKit `NSPanel` overlay, `MenuBarExtra` |
| ASR service | Spark | asyncio WebSocket server, Silero VAD, `qwen-asr` on vLLM, transcript store |

## 4. Mac client

Native app, Swift 6.2 / Xcode 26, **deployment target macOS 26** (my only Mac runs 26.7; the tap API
itself needs 14.2, and 26 adds tapping by bundle ID). Menu-bar app (`LSUIElement`), not sandboxed.

### 4.1 Call audio — process tap ("Them")

1. **Find the call app's audio processes.** Read `kAudioHardwarePropertyProcessObjectList` (only
   processes currently connected to audio), and for each object read `kAudioProcessPropertyBundleID`,
   `kAudioProcessPropertyPID` and `kAudioProcessPropertyIsRunningOutput`. Match the bundle-ID family:

   | App | Bundle IDs |
   |---|---|
   | Zoom | `us.zoom.xos` |
   | Teams | `com.microsoft.teams2` (classic: `com.microsoft.teams`) |
   | WebEx | `Cisco-Systems.Spark`, `com.cisco.webexmeetingsapp` |

   Call apps play audio from **helper processes**. Teams plays it from its WebView
   `audio.mojom.AudioService` helper, and adding its video-capture helper to a tap stops all
   callbacks — so **tap only family members with `IsRunningOutput == true`**. Zoom and WebEx helpers are
   unverified → confirm during a live call in M2.
2. **Create the tap.** `CATapDescription(stereoMixdownOfProcesses:)` with those process objects,
   `muteBehavior = .unmuted`, `isPrivate = true`. (macOS 26 also offers `bundleIDs` +
   `isProcessRestoreEnabled`; adopt it if M2 shows it covers the helpers.)
3. **Wrap it in a private aggregate device** (sub-device = current output device, tap list = the tap,
   drift compensation on, `TapAutoStart` on — requires the aggregate to be private), then
   `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`.
4. **Read the format** from `kAudioTapPropertyFormat` — don't hardcode it (typically 48 kHz Float32
   interleaved stereo). The IOProc block runs on the real-time path: it only copies into a lock-free
   ring buffer; conversion happens on a separate queue.
5. **Retarget, don't rebuild,** when processes come and go: listen on the process-object list and set
   `kAudioTapPropertyDescription` on the live tap. **Rebuild** the aggregate when the default output
   device changes (`kAudioHardwarePropertyDefaultOutputDevice` listener — AirPods).
6. **Fallback:** a global tap excluding memoir's own process (captures all system audio).

### 4.2 Microphone ("Me")

- `AVAudioEngine` input node; choose the device by setting `kAudioOutputUnitProperty_CurrentDevice` on
  `inputNode.audioUnit` before start.
- **Tap in the hardware format** (`inputNode.outputFormat(forBus: 0)`) and convert with
  `AVAudioConverter` (`downmix = true`) to 16 kHz mono. The input node does no format conversion —
  asking `installTap` for 16 kHz directly crashes.
- Rebuild tap + converter on `AVAudioEngineConfigurationChange` (rate/channel changes stop the engine).
- **Start the mic before the call tap** — otherwise AirPods can stay in A2DP and the mic is silent.
- **No voice processing** (`setVoiceProcessingEnabled`): it ducks all other audio, including the call,
  and can cut off another app's mic stream.

### 4.3 Echo / bleed

On laptop speakers the mic hears the remote side, so "Me" would transcribe "Them" a second time.
v1: **headphones recommended**; the app shows a hint when output is the built-in speakers. M4 adds a
server-side filter: drop a Me final whose normalised text matches a Them final overlapping within ±1 s.

### 4.4 Streaming client

- Converts both sources to **PCM s16le, 16 kHz mono, 100 ms frames** (3,200 bytes) and sends them on
  one WebSocket with the header in §6.
- Keeps the **last 30 s per source** for resend; on disconnect, reconnects with exponential backoff
  (0.5 s → 10 s) and resumes from the offsets the server reports in `ready`.
- Server URL `ws://spark-0e81.local:8770/v1/stream`; token in the Keychain.

### 4.5 UI

- **Overlay:** `NSPanel` with `[.nonactivatingPanel, .borderless, .resizable]`, level `.floating`,
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` (stays above full-screen Zoom),
  `isMovableByWindowBackground`. Click-through mode toggles `ignoresMouseEvents`. No `.hudWindow`
  style — the SwiftUI view draws its own translucent background.
- **Transcript model:** segments keyed by `(source, seg)`. A partial **replaces** that segment's text
  (shown dimmed); a final replaces and freezes it. Show the last ~6 lines; Me and Them in different
  colours.
- **Status pill from real state:** `connecting` → `live` (only after the server's `ready`) →
  `reconnecting` / `offline`, plus `no system-audio permission` (§4.6) and `server error`.
- **Menu bar:** start / stop, call-app picker (auto = whichever is outputting), mic picker,
  click-through, meeting title, open transcripts folder.

### 4.6 Permissions, signing, packaging

| Need | How |
|---|---|
| Call audio | `NSAudioCaptureUsageDescription` written **directly in Info.plist** (the `INFOPLIST_KEY_` build setting reportedly drops it — check with `plutil -p`). Shows under Privacy & Security → Screen & System Audio Recording → *System Audio Recording Only*. Prompted on first start of the tap's aggregate device. |
| Microphone | `NSMicrophoneUsageDescription`; hardened runtime + `com.apple.security.device.audio-input`. |
| LAN | `NSLocalNetworkUsageDescription` (macOS 15+ local-network prompt). |
| Stable grants | Sign with a stable Apple Development identity, not ad-hoc — ad-hoc rebuilds lose permission grants. |

There is **no public API to check or request** system-audio permission, and when it's denied every call
succeeds but buffers are all zeros. So: a **silence watchdog** — if the call app reports
`IsRunningOutput` but the tap delivers only zeros for 5 s, rebuild the tap once; if still zero, show
"Allow System Audio Recording, then restart memoir" (grants only apply after a restart).

## 5. ASR service (`spark-0e81`)

### 5.1 Model and engine

- **Qwen3-ASR-1.7B** via the official `qwen-asr` toolkit on its **vLLM backend** — streaming exists only
  there. Weights: 1.7B ≈ 4.7 GB bf16, 0.6B ≈ 1.9 GB. Streaming WER (paper avg.): 1.7B 3.33 vs 0.6B 4.40.
- The toolkit's streaming is **pseudo-streaming**: every call re-feeds all audio buffered so far for
  that stream, with the last few tokens still revisable. Cost grows with utterance length and users
  report lag building up on long streams — hence D5: one streaming state **per utterance**, reset after
  each final, utterances capped at 20 s.
- API shape (from the toolkit's example):

  ```python
  asr = Qwen3ASRModel.LLM(model="Qwen/Qwen3-ASR-1.7B",
                          gpu_memory_utilization=0.10, max_new_tokens=32)
  state = asr.init_streaming_state(chunk_size_sec=1.0, unfixed_chunk_num=4,
                                   unfixed_token_num=5, language="English")
  asr.streaming_transcribe(new_audio, state)    # → state.text = whole current hypothesis (partial)
  asr.finish_streaming_transcribe(state)        # → final text for the utterance
  ```

  No timestamps and no batching in streaming mode; segment times come from sample counts (§5.3).
  Word-level timestamps (Qwen3-ForcedAligner-0.6B on finals) are a later add-on.
- **Memory cap is mandatory.** The Spark's 128 GB is unified CPU/GPU memory and qmx already holds
  ~39 GB on the GPU (Ollama embeddings + the 23 GB `qwen3.6:35b-a3b` chat model + the llama.cpp
  reranker). vLLM's default `gpu_memory_utilization` of 0.9 would starve it, so start at **0.10**
  (~12 GB) and tune in M0.
- **Language:** forced to `English` by default (auto-detect on 1 s chunks can flip); per-meeting
  override, `auto` allowed. **Context biasing** (`context=` names/jargon) is **off by default** — known
  issues: hotwords repeated in output, context text leaking into transcripts.

### 5.2 Install on the Spark (rootless) — proven in M0

The upstream toolkit doesn't install as-is here: it pins `vllm==0.14.0` / `torch==2.9.1` (PyPI torch is
CPU-only on aarch64) and the official Docker image is amd64-only. The Spark's driver (580.173.02)
supports CUDA up to 13.1, so the newest usable NGC vLLM image is **26.02** (vLLM 0.15.1).

- **Plan A — NGC container:** `FROM nvcr.io/nvidia/vllm:26.02-py3`, then
  `pip install --no-deps qwen-asr==0.0.6` plus whatever it imports that the image lacks, plus
  `silero-vad` and the web server. Pin the base image by digest. Docker already works for my user.
- **Plan B — uv venv:** the community fork `qwen-asr-dgxspark` (torch ≥ 2.11, vLLM ≥ 0.20) with torch
  from the `cu130` wheel index. Needs a check that its vLLM wheel runs on CUDA 13.1.
- Skip `flash-attn` (fails to build for sm_121; the vLLM path doesn't need it).

### 5.3 Per-stream pipeline

For each `(meeting, source)`:

1. **Ingest** frames into a ring buffer by `sample_offset`; fill gaps with silence, drop duplicates.
2. **VAD** — Silero VAD on CPU, 32 ms frames. Utterance **starts** after 250 ms of speech (with 300 ms
   pre-roll); **ends** after 600 ms of silence; **force-cut** at the first ≥ 200 ms pause after 15 s, or
   hard at 20 s.
3. **Partial** — whenever ≥ 1.0 s of new audio is buffered, feed it to `streaming_transcribe` and emit
   `state.text` as a partial (skip if it didn't change).
4. **Final** — at utterance end, `finish_streaming_transcribe` → emit final, append to the store,
   discard the state.
5. **Times** — `t0`/`t1` = sample offsets ÷ 16,000 (seconds since meeting start, per source clock).

### 5.4 Concurrency

- The vLLM engine is created in the main process (`if __name__ == "__main__"` — it spawns workers) and
  used from **one dedicated ASR thread**; the asyncio WebSocket loop never touches the GPU and never
  blocks.
- At most one job in flight per stream. The scheduler runs **finals first**, then the stream with the
  oldest pending audio. If a stream falls > 2 s behind, its partials are skipped (the audio still goes
  into the next call) — partials degrade, finals are never dropped.
- With one person talking at a time this is ~1 GPU call per second. Me and Them overlapping doubles it;
  M0 measures whether that fits.
- v1 serves **one meeting at a time**; a second `start` with another `meeting_id` gets `busy`.

### 5.5 Storage

```
~/.memoir/meetings/2026-10-17/1630-weekly-sync-3f9a.jsonl   # source of truth, appended per final
~/.memoir/meetings/2026-10-17/1630-weekly-sync-3f9a.md      # rendered at stop
```

```json
{"type":"meeting","meeting_id":"3f9a…","title":"Weekly sync","app":"us.zoom.xos",
 "started_at":"2026-10-17T16:30:00-07:00","model":"Qwen/Qwen3-ASR-1.7B","language":"English"}
{"type":"final","source":"them","seg":42,"t0":812.48,"t1":817.90,"text":"So the plan for next quarter is to ship the beta."}
```

Files are `0600`. **Raw audio is not stored** unless `MEMOIR_SAVE_AUDIO=true` (then 16 kHz FLAC per
source, for re-transcription and debugging). The Mac also saves a Markdown copy on stop.

## 6. Wire protocol

`GET ws://spark-0e81.local:8770/v1/stream` with `Authorization: Bearer <token>`.

**Client → server, text frames**

```json
{"type":"start","meeting_id":"3f9a…","title":"Weekly sync","app":"us.zoom.xos",
 "sources":["me","them"],"sample_rate":16000,"encoding":"pcm_s16le","language":"English"}
{"type":"stop"}
```

Reconnecting sends the same `start` (same `meeting_id`); the server continues the same file and segment
numbering.

**Client → server, binary frames** — 12-byte header + PCM:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | `source` — 0 = me, 1 = them |
| 1 | 3 | reserved, 0 |
| 4 | 8 | `sample_offset` — u64 LE, index of the first sample since meeting start, per source |
| 12 | n | PCM s16le, 16 kHz mono (100 ms = 3,200 bytes) |

**Server → client, text frames**

```json
{"type":"ready","meeting_id":"3f9a…","model":"Qwen/Qwen3-ASR-1.7B","resume_from":{"me":0,"them":0}}
{"type":"partial","source":"them","seg":42,"t0":812.48,"text":"so the plan for next quarter is"}
{"type":"final","source":"them","seg":42,"t0":812.48,"t1":817.90,"text":"So the plan for next quarter is to ship the beta."}
{"type":"status","lag_ms":{"me":120,"them":340}}
{"type":"stopped","path":"meetings/2026-10-17/1630-weekly-sync-3f9a.md"}
{"type":"error","code":"unauthorized|busy|bad_frame|engine_down","message":"…"}
```

Partials carry the **whole** current text of the segment (not a delta), so the client just replaces it.

## 7. Latency budget

| Stage | Budget | Basis |
|---|---|---|
| Tap / mic buffer | ~10–20 ms | aggregate buffer size + safety offset — measure |
| Client framing (100 ms frames) | ≤ 100 ms (avg 50) | design |
| LAN | < 5 ms | |
| VAD frame | ≤ 32 ms | Silero frame size |
| Wait for the next 1 s chunk | ≤ 1 s (avg 0.5 s) | `chunk_size_sec = 1.0` |
| Decode one chunk | ~0.1–0.3 s | paper: ~0.1 s to first token on an unnamed GPU; **GB10 measured in M0** |
| Render | ~16 ms | one frame |

**Partial:** p50 ≈ 0.7–0.9 s, worst ≈ 1.5 s. **Final:** 600 ms end-of-speech silence + one decode ≈
0.8–1.0 s after the speaker stops. Lowering `chunk_size_sec` to 0.5 s trades GPU calls for snappier
partials. These are targets until M0/M1 put real numbers here.

## 8. Security and privacy

- **LAN-only**, like qmx — but meeting audio is more sensitive than qmx queries, so a **bearer token is
  required** (32 random bytes; `~/.config/memoir/env` on the Spark, Keychain on the Mac). No TLS in v1;
  TLS or Tailscale before it ever leaves the home LAN.
- Transcripts `0600` under `~/.memoir`; raw audio off by default.
- **Consent is on the user.** Some jurisdictions require every participant's consent to record or
  transcribe a call, and employers may restrict sending work-meeting audio to personal hardware. The
  overlay always shows that transcription is on.

## 9. Deployment

Same pattern as qmx: rootless, `systemd --user` with linger (already enabled on `spark-0e81`), repo
clone at `~/GitHub/the-dsvolk/memoir`.

`~/.config/memoir/env`:

```ini
MEMOIR_HOST=0.0.0.0
MEMOIR_PORT=8770
MEMOIR_TOKEN=<openssl rand -hex 32>
MEMOIR_MODEL=Qwen/Qwen3-ASR-1.7B
MEMOIR_GPU_MEM_UTIL=0.10
MEMOIR_LANGUAGE=English
MEMOIR_DATA_DIR=/data              # ~/.memoir inside the container
MEMOIR_SAVE_AUDIO=false
```

`~/.config/systemd/user/memoir-asr.service` (sketch — finalised in M0):

```ini
[Unit]
Description=memoir ASR server (Qwen3-ASR on vLLM)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/docker run --rm --name memoir-asr --gpus all --user %U \
  -p 8770:8770 --env-file %h/.config/memoir/env \
  -v %h/.memoir:/data -v %h/.cache/huggingface:/hf -e HF_HOME=/hf \
  -v %h/GitHub/the-dsvolk/memoir/server:/app -w /app \
  memoir-asr:local python -m memoir_asr
ExecStop=/usr/bin/docker stop memoir-asr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

`--user` keeps files written to `/data` owned by me, not root. Port map after M1:

| Port | Service |
|---|---|
| 8081 | qmx reranker (llama.cpp) |
| 8765 | qmx MCP |
| **8770** | **memoir-asr** |
| 11434 | Ollama (qmx) |

## 10. Repository layout

```
memoir/
  DESIGN.md
  server/                 # Python — memoir-asr
    pyproject.toml
    Dockerfile            # FROM nvcr.io/nvidia/vllm:26.02-py3 (pinned digest)
    memoir_asr/
      __main__.py         # builds the engine, starts the server
      protocol.py         # frame header, JSON messages
      session.py          # meeting + per-source state, resume
      vad.py              # Silero wrapper, utterance segmentation
      engine.py           # ASR thread, scheduler, qwen-asr calls
      store.py            # JSONL append, Markdown render
    tools/replay.py       # streams a WAV in real time over the protocol, measures latency
    tests/
  mac/
    Memoir.xcodeproj
    Memoir/
      App/  Capture/  Stream/  Transcript/  UI/
  deploy/
    memoir-asr.service
    env.example
```

## 11. Testing

- **Server unit tests:** frame parsing, gap/duplicate handling, VAD segmentation on synthetic audio,
  scheduler priorities, store/render. Run on the Mac without a GPU (engine mocked).
- **Server integration** (`-m integration`, against the Spark like qmx): `tools/replay.py` plays a
  recorded call plus LibriSpeech samples at real-time speed and reports partial/final latency p50/p95
  and WER against reference text.
- **Mac unit tests:** framer, resampler (48 kHz stereo → 16 kHz mono), transcript model.
- **Manual test plan:** Zoom test call and Teams "make a test call"; AirPods connect/disconnect
  mid-call; system-audio permission denied; Spark unreachable for 20 s then back (resume without gaps);
  60-minute call for lag build-up.

## 12. Milestones

| | Milestone | Exit criterion |
|---|---|---|
| **M0** | Spark spike: install (Plan A, else B); offline + streaming on sample WAVs with qmx running | Per-chunk decode latency and memory for 0.6B vs 1.7B recorded here; model + install route picked |
| **M1** | Server: protocol, VAD, partial/final, store, `replay.py`, systemd unit | Replay of a 10-min call: partial p50 ≤ 1.0 s, no lag growth, JSONL + MD written |
| **M2** | Mac capture CLI (no UI): tap + mic → server, transcript printed in Terminal | Live Zoom and Teams calls transcribed for 30 min; AirPods switch survives; helper processes for Zoom/WebEx confirmed |
| **M3** | Mac app: menu bar, overlay, reconnect/resume, permission UX, Markdown copy | Daily-usable on real calls |
| **M4** | Hardening: echo filter, call auto-detect (`IsRunningOutput`), silence watchdog, `INFRA.md` | A week of real calls without manual fixes |

**Later:** meeting summaries with the `qwen3.6:35b-a3b` model already on the Spark's Ollama; index
`~/.memoir/meetings` into qmx; word timestamps via Qwen3-ForcedAligner; telling remote speakers apart;
`spark-0f50` fail-over; ScreenCaptureKit as a capture fallback.

## 13. Open questions

1. **0.6B or 1.7B?** Decided by M0 latency on GB10 with qmx loaded.
2. **Install route** — NGC container (Plan A) or the community fork in a uv venv (Plan B)?
3. **Default language** — force English, or auto-detect because some calls aren't in English?
4. **Zoom / WebEx helper processes** — which one actually plays call audio (M2)?
5. **Where transcripts live** — Spark as source of truth with a Mac Markdown copy (current plan), or
   mirror both ways?
6. **Headphones-only for v1** acceptable until the M4 echo filter?

## Appendix A — changes from the first blueprint

| First blueprint | v1 | Reason |
|---|---|---|
| Qwen-Audio-Chat, `AutoModelForCausalLM` | Qwen3-ASR via `qwen-asr` on vLLM | The draft never passed audio to the model (`raw_samples` unused) and mixed Qwen2-Audio's prompt format with a Qwen-1 model. |
| Fixed 1.5 s windows, 0.3 s overlap | VAD utterances + streaming partials/finals | Windows cut words, duplicated the overlap, and made "< 800 ms" impossible (1.5 s buffering alone). |
| `model.generate()` inside the async handler | Dedicated ASR thread + scheduler | Blocking the event loop stalled the socket and grew an unbounded backlog. |
| BlackHole + Multi-Output / Aggregate Device | Process tap + separate mic | No driver, volume keys work, AirPods switching works, Me/Them labels. |
| `installTap` at 16 kHz on the input node | Tap at hardware format + `AVAudioConverter` | The input node doesn't convert formats — the draft would crash at start. |
| Input = system default device | Explicit tap target + mic device | The draft never actually selected BlackHole. |
| Transcript text replaced on each message | Segments: partial replaces, final appends | The draft only ever showed the last 1.5 s. |
| "LIVE" set as soon as the socket was created | Status from the server's `ready` | Real connection state, plus reconnect/resume. |
| Nothing saved | JSONL + Markdown per meeting | A memoir needs a record. |
| `0.0.0.0:8000`, no auth | `:8770` + bearer token | Avoids vLLM's default port; meeting audio is sensitive. |

## References

- Qwen3-ASR — repo https://github.com/QwenLM/Qwen3-ASR · model https://huggingface.co/Qwen/Qwen3-ASR-0.6B ·
  paper https://arxiv.org/abs/2601.21337 · streaming lag reports
  https://github.com/QwenLM/Qwen3-ASR/issues/148, https://github.com/QwenLM/Qwen3-ASR/issues/199
- Spark — driver / CUDA ceiling https://forums.developer.nvidia.com/t/379168 · vLLM on DGX Spark
  https://vllm.ai/blog/2026-06-01-vllm-dgx-spark · aarch64 fork https://github.com/allen2c/Qwen3-ASR
- Core Audio taps — Apple sample
  https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps ·
  AudioCap https://github.com/insidegui/AudioCap · Heard (call-app bundle IDs)
  https://github.com/execsumo/Heard · Teams helper processes
  https://github.com/pasrom/meeting-transcriber/issues/79,
  https://github.com/pasrom/meeting-transcriber/issues/791 · all-zero buffers
  https://developer.apple.com/forums/thread/825780 · audiotee https://github.com/makeusabrew/audiotee
- qmx deployment pattern on the same Spark — `qmx/INFRA.md`
