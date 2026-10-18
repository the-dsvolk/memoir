# memoir — Design

**Status:** draft v1 · 2026-10-17 · owner: the-dsvolk
**Supersedes:** the first "System Blueprint: Real-Time macOS Meeting Transcription" draft (BlackHole +
Qwen-Audio-Chat). What changed and why is in [Appendix A](#appendix-a--changes-from-the-first-blueprint).

## 1. Goal

While I'm on a video call (Zoom, Microsoft Teams, WebEx) on the Mac — or in an in-person meeting —
show a **live transcript** in a small always-on-top window, labelled **Me** (my microphone) and
**Them** (the call's audio); let me jot **quick notes** that get expanded from the transcript when the
meeting ends; surface **relevant docs from qmx** when someone asks a question; and **keep a record**
of every meeting. The Mac only captures and displays; transcription, notes and retrieval run on the
DGX Spark `spark-0e81` on the home LAN — the same split qmx uses.

**v1 success criteria**

- Partial (in-progress) text on screen **≤ 1.0 s p50** after the words are spoken; final text for an
  utterance **≤ 1.2 s** after the speaker stops.
- A 60-minute call runs without lag building up, and survives switching to AirPods mid-call.
- Every meeting is saved as JSONL + Markdown with per-utterance timestamps.
- My quick notes are expanded into full notes, anchored to the transcript, within ~2 min of the
  meeting ending (M4).
- When the other side asks a question my qmx knowledge base covers, a hint appears within ~2 s of the
  question ending (M5).

**Non-goals (v1)** — any language other than **English** (decided), translation, full meeting
summaries / action items (only my own notes get expanded), telling apart *multiple* remote or in-room
speakers, more than one client or one meeting at a time, any cloud service, and use away from the
home LAN (no on-device fallback — decided).

## 2. Settled decisions

| # | Decision | Instead of | Why |
|---|---|---|---|
| D1 | **Inference on `spark-0e81` only** | `spark-0f50`, both | One host to operate; it already runs qmx. `spark-0f50` was powered off on 2026-10-17 (its Nemotron-120B vLLM server had no traffic in 10 days); it's the later fail-over. |
| D2 | **Nemotron Speech Streaming EN 0.6B** (`nvidia/nemotron-speech-streaming-en-0.6b`, pinned) | Qwen3-ASR-1.7B (earlier draft), Qwen-Audio-Chat (first blueprint) | True cache-aware streaming (each 80 ms frame processed once — no lag build-up), English-only like D10, 0.6B, tested on DGX Spark, NVIDIA Open Model License. |
| D3 | **Core Audio process taps** for call audio | BlackHole + Multi-Output Device | No driver; volume keys keep working; follows the call app, not an output device. |
| D4 | **Mic captured separately** → two streams, Me / Them | One mixed Aggregate Device | Speaker labels for free; lets us handle echo/bleed. |
| D5 | **One continuous stream per source; the pipeline's end-of-utterance detector closes segments** | Fixed 1.5 s windows; Silero VAD | The model streams natively (D2); NeMo's streaming pipeline cuts its running text into timed, punctuated finals (Silero not needed in v1). |
| D6 | **Port 8770** on the Spark | 8000 | 8000 is vLLM's default; 8770 sits next to qmx's 8765 and is free. |
| D7 | **In-person mode = mic only**, labelled **Room** | Call apps only | Same pipeline minus the tap; needs no system-audio permission. |
| D8 | **Quick notes typed on the Mac, expanded on the Spark** by `qwen3.6:35b-a3b`, the model qmx already serves via Ollama | No notes, or a new model | The transcript alone is the least useful part; notes are where the value is, and the model is already loaded. |
| D9 | **Live assist = qmx retrieval** over its MCP endpoint, with meetings indexed into qmx | A separate RAG stack | qmx already runs embeddings, a reranker and the index on the same Spark. |
| D10 | **English only** — ASR language fixed to English, no auto-detect | Auto-detect / per-meeting language | No language-ID flips on short chunks; English prompts and question heuristics; English-only ASR models become candidates. |

## 3. Architecture

```
 Mac — memoir.app (Swift)                          spark-0e81 — memoir-asr (Python + NeMo, uv)
 ─────────────────────────                         ────────────────────────────────────────────────
 Zoom / Teams / WebEx output                        WebSocket :8770  (bearer token)
   └─ Core Audio process tap ──┐                      │
                               ├─ resample → 16 kHz   ├─ per source: stream + Silero VAD (segment ends)
 Microphone (AVAudioEngine) ───┘   mono s16, 100 ms   │
   (in-person mode: mic only)      frames tagged      ├─ ASR worker (one thread, owns the model)
                                   Me / Them / Room ► │    Nemotron Speech Streaming EN 0.6B (cache-aware)
 Quick note (hotkey) ────────────── note JSON ──────► │    → partial every 0.56 s, final at end of speech
                                                      │
 Overlay HUD (NSPanel) ◄──── partial / final JSON ────┤
                       ◄──── assist hint ─────────────┼─ question? → qmx query (MCP :8765, same box)
 Menu bar: start/stop, mode, app + mic pickers        │
                                                      └─ ~/.memoir/meetings/<date>/<id>.jsonl (+ .md)
                                                         at stop: notes → Ollama qwen3.6:35b-a3b
                                                         → expanded notes; qmx indexes the .md
```

| Subsystem | Runs on | Components |
|---|---|---|
| Call-audio capture | Mac | `AudioHardwareCreateProcessTap`, private aggregate device, IOProc → ring buffer |
| Mic capture | Mac | `AVAudioEngine` input node, `AVAudioConverter` |
| Streaming client | Mac | `URLSessionWebSocketTask`, framing, reconnect + 30 s resend buffer |
| UI | Mac | SwiftUI in an AppKit `NSPanel` overlay, `MenuBarExtra` |
| ASR service | Spark | asyncio WebSocket server, Nemotron Speech Streaming EN on NeMo, Silero VAD, transcript store |
| Notes | Mac → Spark | hotkey note entry; expansion at stop via qmx's Ollama (`qwen3.6:35b-a3b`) |
| Live assist | Spark | question detector on finals → qmx `query` → hint card in the overlay |

## 4. Mac client

Native app, Swift 6.2 / Xcode 26, **deployment target macOS 26** (my only Mac runs 26.7; the tap API
itself needs 14.2, and 26 adds tapping by bundle ID). Menu-bar app (`LSUIElement`), not sandboxed.

Two **capture modes**, picked in the menu bar:

| Mode | Sources | Needs |
|---|---|---|
| **Call** | Them (process tap, §4.1) + Me (mic, §4.2) | system-audio + mic permission |
| **In-person** | Room (mic only, §4.2) — everyone in the room on one stream | mic permission |

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

### 4.3 Echo / bleed (call mode)

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
- **Menu bar:** start / stop, mode (call / in-person), call-app picker (auto = whichever is
  outputting), mic picker, click-through, meeting title, open transcripts folder.
- **Quick notes:** a global hotkey (default ⌃⌥N, via Carbon `RegisterEventHotKey` — no Accessibility
  permission) opens a one-line input in the overlay; Enter sends, Esc cancels. The note is stamped
  with the meeting clock **when the hotkey was pressed** (you type after hearing the point). The panel
  subclass overrides `canBecomeKey`, so it takes typing without activating the app or pulling focus
  from the call. Notes stay pinned in the overlay as bullets.
- **Assist hint:** one card at a time under the transcript — the detected question, then the top qmx
  hit (title, path, snippet). Click copies the path; it auto-hides after 20 s or on Esc.

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

## 5. Spark service — ASR, notes, assist (`spark-0e81`)

### 5.1 Model and engine

- **Model: `nvidia/nemotron-speech-streaming-en-0.6b`**, pinned to revision `ebe59e5` (`main`, updated
  2026-08-05 — the March 2026 checkpoint, which NVIDIA says outperforms the January one kept on branch
  `nemotron-speech-streaming-jan2026`). NVIDIA Open Model License (commercial and non-commercial use).
- **Why this one:** it's NVIDIA's latest **English** streaming ASR. The newest Nemotron ASR overall,
  Nemotron 3.5 ASR Streaming 0.6B (2026-05-15, updated 2026-09-10), is the same design extended to 40
  language-locales, and NVIDIA points English-only use at this model (D10).
- **Architecture:** cache-aware FastConformer encoder (24 layers) + RNN-T decoder, 600M parameters,
  punctuation and capitalisation built in, English only. **True streaming** — it caches attention and
  convolution state, so every 80 ms frame is processed once: per-chunk cost is constant and lag can't
  build up over a long call. Transducers are also far less prone than LLM decoders to invent text on
  silence.
- **Latency is a runtime setting**, `att_context_size = [70, R]` in 80 ms frames (no retraining).
  Average WER on the Hugging Face Open ASR leaderboard sets (without punctuation, from the model card):

  | R | Chunk | Avg WER | AMI (meetings) |
  |---|---|---|---|
  | 0 | 80 ms | 8.43 | 18.29 |
  | 1 | 160 ms | 7.67 | 14.71 |
  | **6** | **560 ms** | **7.07** | **11.88** |
  | 13 | 1.12 s | 6.93 | 11.73 |

  Default **560 ms**: within 0.14 points of the best setting, with partials twice a second. Meeting
  audio (AMI) is the hardest set for every model — M0 measures on our own calls.
- **API** (used by the MVP) — NeMo 3.0's streaming-inference pipeline, `CacheAwareRNNTPipeline` in
  `nemo.collections.asr.inference`. It keeps per-stream feature and encoder caches, runs its own
  end-of-utterance detector, and returns partial and final (punctuated) text each step, for many
  streams at once:

  ```python
  pipeline = PipelineBuilder.build_pipeline(cfg)  # NeMo's cache_aware_rnnt.yaml + memoir's overrides
  pipeline.open_session()
  outs = pipeline.transcribe_step([Frame(samples=chunk, stream_id=sid, is_first=first,
                                         is_last=last, length=valid, options=ASRRequestOptions())])
  # → out.partial_transcript, out.final_transcript, out.final_segments (start / end seconds)
  ```

  Each step takes exactly one 560 ms frame (8,960 samples) per stream. Config overrides: pinned
  `.nemo` path, `att_context_size [70, 6]`, bf16, per-stream biasing off (INSTALL.md #4),
  `return_tail_result` on. Fallbacks: NeMo's lower-level `conformer_stream_step`, or 🤗 Transformers
  ≥ 5.13 (`AutoModelForRNNT` with a generator of per-chunk `input_features`).
- **No timestamps from the stream itself** in v1; segment times come from sample counts (§5.3). RNN-T
  token timestamps (NeMo) or Riva's word offsets are a later add-on. **No custom vocabulary** in v1 —
  the model card doesn't offer it; NeMo's word boosting for transducers is a later experiment.
- **Memory:** measured **4.99 GB peak** on `spark-0e81` with the F32 weights (2.4 GB; bf16 would halve
  them) — next to qmx's ~39 GB on the same unified memory. No vLLM-style up-front reservation to cap.
  Installed and verified 2026-10-17 — see [`INSTALL.md`](./INSTALL.md).
- **Numbers come out as words** ("forty two thousand dollars") — no inverse text normalisation (ITN).
  NeMo's streaming pipeline config (`cache_aware_rnnt.yaml`) adds ITN; open question 10.
- **M0 comparison:** `nvidia/parakeet-unified-en-0.6b` (revision `fe53cd8`, 2026-04-07) — same family
  and NeMo stack, one model for streaming *and* offline. Better WER from 0.24 s to 2.08 s (560 ms: 6.52
  vs 7.09 in its card; offline 5.91) but *buffered* streaming (recomputes left context every chunk —
  irrelevant at two streams), minimum 160 ms, and NVIDIA recommends Nemotron for the lowest latencies.
  Its offline mode is also the natural engine for a later post-meeting accuracy pass.

### 5.2 Install on the Spark (rootless) — proven in M0

Known good on `spark-0e81` (checked 2026-10-17): driver 580.173.02, deliberately pinned (CUDA 13.0
builds work), and **torch 2.11.0+cu130 sees the GB10**. The model card lists DGX Spark among its test
machines. Its NeMo install is `pip install Cython packaging` + `nemo_toolkit[asr]` from NeMo `main`,
plus `apt-get install libsndfile1 ffmpeg`.

- **Plan A — uv venv + NeMo** (qmx-style, no Docker): Python 3.12, torch 2.11.0 from the `cu130` wheel
  index (the build already working on this box), `nemo_toolkit[asr]` pinned to a NeMo commit,
  `silero-vad`, the web server. There's no sudo for apt: `soundfile` wheels bundle libsndfile, and we
  feed raw PCM, so ffmpeg shouldn't be needed — M0 confirms both.
- **Plan B — uv venv + Transformers ≥ 5.13:** no NeMo at all (`AutoModelForRNNT`); lighter, newer code
  path; streaming through the input-feature generator (§5.1), one `generate` thread per source instead
  of batched steps.
- **Plan C — container:** `FROM nvcr.io/nvidia/pytorch:25.10-py3` (CUDA 13.0; shown working on a GB10
  by `cjlapao/qwen3-audio-gb10`), `apt-get install libsndfile1 ffmpeg` inside the image, NeMo installed
  against a constraints file of the image's own `torch` / `torchaudio` / `nvidia-*` / `cuda-*` versions
  (so pip can't swap in CPU-only torch), and a build step that fails if `import nemo.collections.asr`
  fails. Runs with `--gpus all --network host --user %U`.
- Keep memoir isolated from the `pip --user` torch / vLLM in `~/.local` (venvs ignore user
  site-packages).

### 5.3 Per-stream pipeline

For each `(meeting, source)`:

1. **Ingest** frames into a ring buffer by `sample_offset`; fill gaps with silence, drop duplicates.
2. **Stream** — one pipeline stream per source for the whole meeting. Every 560 ms of new audio becomes
   one step (§5.4); the step's `partial_transcript` (text since the last end of utterance) is sent as
   a partial when it changes. Silence is fed too: it keeps the context and costs almost nothing.
3. **Segment ends** — the pipeline's end-of-utterance detector (an 800 ms window) closes a segment;
   its `final_transcript` becomes a **final**, appended to the store, with `t0` / `t1` from the
   pipeline's text segments (seconds since the source's start).
4. **Late punctuation** — the model often emits a sentence's closing punctuation one step after the
   cut, so it would open the next segment ("? Alice will …") or arrive alone ("."). The server strips
   leading punctuation and re-sends the previous final, same `seg`, with it appended.
5. **Stream end** — on `stop` (or a dropped socket) every source gets a last frame with at least
   0.25 s of audio (silence counts) **and** some zero padding: `return_tail_result` emits the words in
   that padding (often the final "."), and a near-empty frame is skipped (INSTALL.md #5). Any partial
   still open then becomes a final.

### 5.4 Concurrency

- **One ASR thread owns the model**; the asyncio WebSocket loop never touches the GPU and never blocks.
- Each 560 ms tick, the thread **batches** every source with a full chunk into one stream step (batch
  1–2; caches are per row). NVIDIA reports ~2,400 parallel 1.12 s streams on one H100, so two streams
  are a trivial load even on a GB10 — M0 records the per-step time.
- No skip-partials logic: if a step ever runs late, chunks queue and `status` reports the lag.
- v1 serves **one meeting at a time**; a second `start` with another `meeting_id` gets `busy`.

### 5.5 Storage

```
~/.memoir/meetings/2026-10-17/1630-weekly-sync-3f9a.jsonl   # source of truth, appended per final
~/.memoir/meetings/2026-10-17/1630-weekly-sync-3f9a.md      # rendered at stop
```

```json
{"type":"meeting","meeting_id":"3f9a…","title":"Weekly sync","app":"us.zoom.xos",
 "started_at":"2026-10-17T16:30:00-07:00","model":"nvidia/nemotron-speech-streaming-en-0.6b@ebe59e5","chunk_ms":560}
{"type":"final","source":"them","seg":42,"t0":812.48,"t1":817.90,"text":"So the plan for next quarter is to ship the beta."}
{"type":"note","id":"n3","t":815.2,"text":"beta → Q1? ask re staffing"}
{"type":"expanded_note","id":"n3","segs":[41,42,43],"text":"The beta ships next quarter (Q1); staffing for it is still open — follow up."}
```

Files are `0600`. **Raw audio is not stored** unless `MEMOIR_SAVE_AUDIO=true` (then 16 kHz FLAC per
source, for re-transcription and debugging). The Mac also saves a Markdown copy on stop.

### 5.6 Notes expansion (M4)

- Notes arrive as `note` messages and are appended to the JSONL as they come.
- At `stop`, after the last final is written, the server makes **one call** to `qwen3.6:35b-a3b` on
  qmx's Ollama (`localhost:11434`) with the full transcript (Me / Them / Room labels and times) and all
  notes, asking to expand each note **using only what was said**, and to return the segment ids it
  relied on. Output is schema-constrained JSON (Ollama `format`, `think=false`) — the same pattern
  qmx's consolidation uses.
- A 60-minute call is ~10k words (~13k tokens), so set `num_ctx` explicitly (32k) rather than trusting
  Ollama's default, which can silently truncate. Longer meetings fall back to one call per note, with
  the transcript from 3 min before to 1 min after the note's timestamp.
- Results go to the JSONL (`expanded_note`) and to a **Notes** section at the top of the Markdown, each
  bullet linking to its transcript times. The client gets `notes_ready` if it's still connected.
- It runs **after** the meeting, so it never competes with live ASR. qmx measured ~10 s warm
  round-trips on this model for its own extraction calls; a full transcript should fit the 2-minute
  target comfortably (to measure in M4).

### 5.7 Live assist (M5)

- **Trigger:** a **final** from Them or Room (not Me — I asked it) that looks like a question: it ends
  in `?` (the model punctuates) or starts with an interrogative (what / how / why / when / where / who
  / which / can / could / do / does / is / are / should / will), and has ≥ 5 words. An LLM classifier
  is the fallback if the heuristic proves too noisy.
- **Lookup:** call qmx's `query` tool on its MCP endpoint (`http://localhost:8765/mcp`, same Spark)
  with the question plus the previous ~30 s of transcript as context, `k = 5`, reranked when qmx's
  reranker is enabled.
- **Show** the top hit only if its score clears a threshold (tuned on real meetings), at most one hint
  per 30 s, and never the same path twice in a meeting.
- **Answers:** v1 shows the retrieved snippet — fast, and it can't hallucinate. Composing a one-line
  answer from the hits with `qwen3.6:35b-a3b` (+5–10 s) is an option behind a setting.
- **Meetings feed qmx:** after each meeting qmx indexes its Markdown (§9), so past meetings become
  searchable — and can answer questions in later ones.
- Assist runs off the ASR thread and never delays partials or finals.

## 6. Wire protocol

`GET ws://spark-0e81.local:8770/v1/stream` with `Authorization: Bearer <token>`.

**Client → server, text frames**

```json
{"type":"start","meeting_id":"3f9a…","title":"Weekly sync","app":"us.zoom.xos",
 "sources":["me","them"],"sample_rate":16000,"encoding":"pcm_s16le"}
{"type":"note","id":"n3","t":815.2,"text":"beta → Q1? ask re staffing"}
{"type":"stop"}
```

In-person mode sends `"sources":["room"]`. A note's `t` is the meeting clock when the hotkey was
pressed.

Reconnecting sends the same `start` (same `meeting_id`); the server continues the same file and segment
numbering.

**Client → server, binary frames** — 12-byte header + PCM:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | `source` — 0 = me, 1 = them, 2 = room |
| 1 | 3 | reserved, 0 |
| 4 | 8 | `sample_offset` — u64 LE, index of the first sample since meeting start, per source |
| 12 | n | PCM s16le, 16 kHz mono (100 ms = 3,200 bytes) |

**Server → client, text frames**

```json
{"type":"ready","meeting_id":"3f9a…","model":"nvidia/nemotron-speech-streaming-en-0.6b@ebe59e5","resume_from":{"me":0,"them":0}}
{"type":"partial","source":"them","seg":42,"t0":812.48,"text":"so the plan for next quarter is"}
{"type":"final","source":"them","seg":42,"t0":812.48,"t1":817.90,"text":"So the plan for next quarter is to ship the beta."}
{"type":"status","lag_ms":{"me":120,"them":340}}
{"type":"assist","seg":57,"question":"Do we have numbers on last quarter's churn?",
 "hits":[{"title":"churn-analysis.md","path":"~/kb/…/churn-analysis.md","snippet":"…","score":0.82}]}
{"type":"stopped","path":"meetings/2026-10-17/1630-weekly-sync-3f9a.md"}
{"type":"notes_ready","path":"meetings/2026-10-17/1630-weekly-sync-3f9a.md"}
{"type":"error","code":"unauthorized|busy|bad_frame|engine_down","message":"…"}
```

Partials carry the **whole** current text of the segment (not a delta), so the client just replaces it.
Partials and finals also carry **`upto`** — seconds of that source's audio the model has consumed —
so clients can measure latency. A **`final` re-sent with an earlier `seg` replaces it** (late
punctuation, §5.3); clients key segments by `(source, seg)`.

## 7. Latency budget

| Stage | Budget | Basis |
|---|---|---|
| Tap / mic buffer | ~10–20 ms | aggregate buffer size + safety offset — measure |
| Client framing (100 ms frames) | ≤ 100 ms (avg 50) | design |
| LAN | < 5 ms | |
| Wait for the 560 ms chunk to fill | ≤ 560 ms (avg 280) | `att_context_size = [70, 6]` — the model's whole look-ahead |
| Stream step (both sources batched) | ~10–50 ms (estimate) | 0.6B model, two rows; **GB10 measured in M0** |
| Render | ~16 ms | one frame |

**Partial:** p50 ≈ 0.4–0.5 s, worst ≈ 0.8 s. **Final:** a segment closes after 600 ms of silence, so
≈ 0.7 s after the speaker stops. 1.12 s chunks add ~0.3 s on average for ~0.1 points of WER. These are
targets until M0/M1 put real numbers here.

**Assist hint:** the question's final (≈ 1 s after it ends) + question check + qmx query (~0.1–0.5 s,
to measure) → on screen ≤ 2 s after the question ends.

**Measured (MVP, 2026-10-17, synthetic speech, Mac → `spark-0e81` over the LAN):** a partial arrives
**0.02–0.03 s after its 560 ms chunk completes**, so a word waits 0.03–0.62 s — about 0.3 s typically.
Finals follow the pipeline's 800 ms end-of-utterance window (not yet measured on its own).

## 8. Security and privacy

- **LAN-only**, like qmx — but meeting audio is more sensitive than qmx queries, so a **bearer token is
  required** (32 random bytes; `~/.config/memoir/env` on the Spark, Keychain on the Mac). No TLS in v1;
  TLS or Tailscale before it ever leaves the home LAN.
- Transcripts `0600` under `~/.memoir`; raw audio off by default.
- Notes expansion and assist stay on the Spark (local Ollama and qmx) — nothing goes to a cloud
  service.
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
MEMOIR_MODEL=nvidia/nemotron-speech-streaming-en-0.6b
MEMOIR_MODEL_REVISION=ebe59e5a817142986528bbbee5dba8db7b38ed50
MEMOIR_CHUNK_MS=560                # att_context_size [70, 6]; 1120 = [70, 13]
MEMOIR_DATA_DIR=/home/dsvolk/.memoir
HF_HOME=/home/dsvolk/.cache/memoir/huggingface   # ~/.cache/huggingface/hub is root-owned (INSTALL.md #2)
TRITON_CACHE_DIR=/home/dsvolk/.cache/memoir/triton  # ~/.triton/cache too (INSTALL.md #3)
WANDB_MODE=disabled
MEMOIR_SAVE_AUDIO=false
MEMOIR_OLLAMA_URL=http://localhost:11434
MEMOIR_NOTES_MODEL=qwen3.6:35b-a3b
MEMOIR_NOTES_NUM_CTX=32768
MEMOIR_QMX_MCP_URL=http://localhost:8765/mcp
MEMOIR_ASSIST=true
```

`~/.config/systemd/user/memoir-asr.service` (sketch — finalised in M0):

```ini
[Unit]
Description=memoir ASR server (Nemotron Speech Streaming EN)
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/GitHub/the-dsvolk/memoir/server
EnvironmentFile=%h/.config/memoir/env
ExecStart=%h/.local/bin/uv run --no-sync --project %h/GitHub/the-dsvolk/memoir/server python -m memoir_asr
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

It runs on the host like qmx (Plans A/B), so Ollama (`localhost:11434`) and qmx (`localhost:8765`) are
plain localhost calls and files under `~/.memoir` are owned by me. Plan C would run the same command
inside the container with `--gpus all --network host --user %U`.

M5 adds `memoir-index.path` (+ `.service`): `PathChanged=%h/.memoir/meetings/.last-stop` — a file the
server touches after writing a meeting's Markdown — runs
`uv run --project %h/GitHub/the-dsvolk/qmx qmx index %h/.memoir/meetings`. (A path unit doesn't watch
subdirectories, hence the trigger file.)

Port map after M1:

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
    Dockerfile            # Plan C only (§5.2)
    memoir_asr/
      __main__.py         # builds the engine, starts the server
      protocol.py         # frame header, JSON messages
      session.py          # meeting + per-source state, resume
      vad.py              # Silero wrapper, utterance segmentation
      engine.py           # ASR thread, batched NeMo stream steps
      store.py            # JSONL append, Markdown render
      notes.py            # note expansion at stop (Ollama)
      assist.py           # question detector + qmx MCP client
    tools/replay.py       # streams a WAV in real time over the protocol, measures latency
    tests/
  mac/
    Memoir.xcodeproj
    Memoir/
      App/  Capture/  Stream/  Transcript/  Notes/  UI/
  deploy/
    memoir-asr.service
    memoir-index.path     # + .service — runs `qmx index` after each meeting
    env.example
```

## 11. Testing

- **Server unit tests:** frame parsing, gap/duplicate handling, VAD segmentation on synthetic audio,
  chunk batching, segment open/close, store/render, question detector, assist threshold / rate limit, note-expansion
  prompt and JSON parsing. Run on the Mac without a GPU (engine, Ollama and qmx mocked).
- **Server integration** (`-m integration`, against the Spark like qmx): `tools/replay.py` plays a
  recorded call plus LibriSpeech samples at real-time speed and reports partial/final latency p50/p95
  and WER against reference text.
- **Mac unit tests:** framer, resampler (48 kHz stereo → 16 kHz mono), transcript model.
- **Manual test plan:** Zoom test call and Teams "make a test call"; AirPods connect/disconnect
  mid-call; system-audio permission denied; Spark unreachable for 20 s then back (resume without gaps);
  60-minute call for lag build-up; an in-person meeting (mic only); notes typed during a call come out
  expanded at stop; a question planted in a test call brings up the expected qmx hint.

## 12. Milestones

| | Milestone | Exit criterion |
|---|---|---|
| **M0** | Spark spike with qmx running: install (Plan A, else B, else C); stream sample WAVs and recorded calls through Nemotron EN at 560 ms and 1.12 s, and parakeet-unified-en at 560 ms | Per-step time, memory and WER (vs a reference transcript) recorded here; model, chunk size and install route picked |
| **M1** | Server: protocol, VAD, partial/final, store, `replay.py`, systemd unit | Replay of a 10-min call: partial p50 ≤ 1.0 s, no lag growth, JSONL + MD written |
| **M2** | Mac capture CLI (no UI): tap + mic → server, transcript printed in Terminal | Live Zoom and Teams calls transcribed for 30 min; AirPods switch survives; helper processes for Zoom/WebEx confirmed |
| **M3** | Mac app: menu bar, overlay, reconnect/resume, permission UX, Markdown copy, **in-person mode**, **quick-note hotkey** | Daily-usable on real calls and in-person meetings; notes saved with timestamps |
| **M4** | Hardening + **note expansion at stop**: echo filter, call auto-detect (`IsRunningOutput`), silence watchdog, `INFRA.md` | A week of real meetings without manual fixes; expanded notes ready ≤ 2 min after stop |
| **M5** | **Live assist via qmx**: question detector, qmx `query`, hint card; meetings indexed into qmx | Over a week, at least half the hints shown are useful (my judgement); past meetings findable via qmx |

**MVP (2026-10-17, branch `feat/mvp-mic`):** the core of M1 plus a mic-only client — `memoir-asr`
(WebSocket, NeMo streaming pipeline, partials / finals, late-punctuation fix, JSONL store, bearer
token) and the Swift `memoir listen` command (Mac mic → 16 kHz → server, live transcript in the
terminal). Not yet: the call tap, the overlay app, notes, assist, resume. Run it: [`INSTALL.md`](./INSTALL.md).

**Later:** full summaries / action items; expanding a note live, during the meeting; LLM-composed
answers in hints by default; word timestamps via Qwen3-ForcedAligner; telling remote speakers apart;
`spark-0f50` fail-over; ScreenCaptureKit as a capture fallback.

## 13. Open questions

1. **Nemotron EN or parakeet-unified-en, and 560 ms or 1.12 s chunks?** Decided by M0 on our own
   recorded calls.
2. **Install route** — NeMo venv (A), Transformers venv (B) or container (C), §5.2?
3. ~~Default language~~ — **decided: English only** (D10).
4. **Zoom / WebEx helper processes** — which one actually plays call audio (M2)?
5. **Where transcripts live** — Spark as source of truth with a Mac Markdown copy (current plan), or
   mirror both ways?
6. **Headphones-only for v1** acceptable until the M4 echo filter?
7. **Quick-note hotkey** — is ⌃⌥N free in my setup?
8. **Assist** — is the punctuation / interrogative heuristic good enough, or do we need an LLM
   classifier? And query the Spark's shared qmx index (current plan) or the Mac's personal one?
9. **qmx indexing while its server runs** — confirm `qmx index` is safe alongside the resident
   `qmx-mcp` on the same `index.db`.
10. **Numbers as digits?** The model writes "forty two thousand dollars". Add ITN (NeMo's streaming
    pipeline has it) for finals only, both partials and finals, or neither?
11. **Segment cuts mid-sentence** (seen live: "…the design of new" / "system"). Lengthen the
    end-of-utterance window (800 ms → ~1.2 s), or merge a final that has no closing punctuation into
    the next one?
12. **Names** (seen live: a first name misheard). NeMo's phrase boosting can bias towards a list of
    names; it runs a Triton kernel, which works now on uv's managed Python (INSTALL.md #4). Feed it
    from qmx or a per-meeting list?

## Appendix A — changes from the first blueprint

| First blueprint | v1 | Reason |
|---|---|---|
| Qwen-Audio-Chat, `AutoModelForCausalLM` | Nemotron Speech Streaming EN 0.6B on NeMo | The draft never passed audio to the model (`raw_samples` unused) and mixed Qwen2-Audio's prompt format with a Qwen-1 model. |
| Fixed 1.5 s windows, 0.3 s overlap | Native cache-aware streaming; VAD closes segments | Windows cut words, duplicated the overlap, and made "< 800 ms" impossible (1.5 s buffering alone). |
| `model.generate()` inside the async handler | Dedicated ASR thread + scheduler | Blocking the event loop stalled the socket and grew an unbounded backlog. |
| BlackHole + Multi-Output / Aggregate Device | Process tap + separate mic | No driver, volume keys work, AirPods switching works, Me/Them labels. |
| `installTap` at 16 kHz on the input node | Tap at hardware format + `AVAudioConverter` | The input node doesn't convert formats — the draft would crash at start. |
| Input = system default device | Explicit tap target + mic device | The draft never actually selected BlackHole. |
| Transcript text replaced on each message | Segments: partial replaces, final appends | The draft only ever showed the last 1.5 s. |
| "LIVE" set as soon as the socket was created | Status from the server's `ready` | Real connection state, plus reconnect/resume. |
| Nothing saved | JSONL + Markdown per meeting | A memoir needs a record. |
| `0.0.0.0:8000`, no auth | `:8770` + bearer token | Avoids vLLM's default port; meeting audio is sensitive. |

An intermediate draft (same day) used **Qwen3-ASR-1.7B on vLLM**. It was replaced by Nemotron after the
English-only decision (D10): Qwen's streaming re-reads the whole utterance on every chunk (so
utterances had to be capped and lag could build), it needed vLLM with a hard memory cap, and its
context biasing was buggy.

## Appendix B — ideas taken from Google AI Edge Foresight

Foresight (Google Labs, Oct 2026) is an offline Mac meeting-notes app: mic + system audio, shorthand
notes expanded from the live transcript, and Q&A over a personal knowledge base (EmbeddingGemma 2 +
Gemma 4). Compared on 2026-10-17:

| Idea | Taken? | Where |
|---|---|---|
| In-person meetings (mic only) | Yes | D7, §4, M3 |
| Shorthand notes expanded from the transcript | Yes | D8, §4.5, §5.6, M3–M4 |
| Live answers from a personal knowledge base | Yes — via qmx | D9, §5.7, M5 |
| On-device transcription when the Spark is unreachable | **No** — home-LAN only, by decision | §1 non-goals |

## References

- Nemotron Speech Streaming EN 0.6B — https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b ·
  NeMo cache-aware streaming example
  https://github.com/NVIDIA-NeMo/NeMo/blob/main/examples/asr/asr_cache_aware_streaming/speech_to_text_cache_aware_streaming_infer.py
  · streaming pipeline config
  https://github.com/NVIDIA-NeMo/NeMo/blob/main/examples/asr/conf/asr_streaming_inference/cache_aware_rnnt.yaml
- M0 comparison — https://huggingface.co/nvidia/parakeet-unified-en-0.6b · multilingual sibling (not
  used) https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- Spark — driver / CUDA ceiling https://forums.developer.nvidia.com/t/379168 · GB10 container recipe
  https://github.com/cjlapao/qwen3-audio-gb10
- Considered and replaced — Qwen3-ASR https://github.com/QwenLM/Qwen3-ASR · its DGX Spark port
  https://github.com/allen2c/Qwen3-ASR
- Core Audio taps — Apple sample
  https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps ·
  AudioCap https://github.com/insidegui/AudioCap · Heard (call-app bundle IDs)
  https://github.com/execsumo/Heard · Teams helper processes
  https://github.com/pasrom/meeting-transcriber/issues/79,
  https://github.com/pasrom/meeting-transcriber/issues/791 · all-zero buffers
  https://developer.apple.com/forums/thread/825780 · audiotee https://github.com/makeusabrew/audiotee
- qmx deployment pattern on the same Spark — `qmx/INFRA.md`
- Google AI Edge Foresight — https://developers.google.com/edge/foresight · coverage
  https://9to5google.com/2026/10/08/google-ai-edge-foresight/
