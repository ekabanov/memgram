# Memgram

> *Every word, perfectly remembered.*

Memgram is a private, offline-first macOS meeting recorder. It silently captures microphone and system audio, transcribes locally via WhisperKit, generates AI summaries, and provides semantic search — entirely on your Mac. No servers. No bots. No audio stored.

## Features

- **Menu bar app** — always available, never in the way
- **Dual-channel capture** — mic (you) + system audio (remote) simultaneously
- **Local transcription** — Parakeet TDT (ANE, default) or WhisperKit (multilingual, Metal + ANE), selectable in Settings → Recording
- **Speaker diarisation** — two Sortformer instances identify up to 2 in-room and 2 remote speakers; enroll your voice for named attribution
- **AI summaries** — stream word-by-word as the model generates; participants, topics, decisions, action items
- **Download progress** — Qwen and Whisper model downloads shown in the popover; both preload at launch
- **Inline search** — filter transcript segments by text or speaker; global semantic search (Cmd+F)
- **Summary tab** — live streaming Markdown with Copy, Export PDF, Share and Regenerate
- **Auto-titling** — LLM generates a 4–8 word title from the summary
- **iCloud sync** — meetings, transcripts, and speaker names sync across Macs via CloudKit
- **Calendar integration** — upcoming events shown in popover; menu bar icon pulses purple before a meeting; event title, notes and attendees improve AI summaries

## Requirements

- macOS 14.0 or later
- Apple Silicon (M1 or later) — required for local Qwen AI summaries
- Xcode 15+ to build

## Getting Started

```bash
git clone https://github.com/ekabanov/memgram
cd memgram
xcodegen generate
open Memgram.xcodeproj
```

On first launch: grant microphone + system audio permissions, then complete the onboarding flow (system audio → voice enrollment → done). Qwen and WhisperKit models download automatically in the background if selected.

To enable calendar integration: **Settings → Calendar** → toggle on → grant calendar access. Requires Google (or any other) calendar account added in **System Settings → Internet Accounts**.

## Transcription

The backend is selectable in **Settings → Recording**.

**Parakeet TDT (default)** — Apple ANE-based model via FluidAudio. No model download required. Lower latency on Apple Silicon.

**WhisperKit (alternative)** — downloads and caches models automatically. Model chosen by your Mac's RAM and language preference:

| RAM | Model | Size |
|-----|-------|------|
| 16 GB+ | Large v3 Turbo (full precision) | 954 MB |
| 8 GB | Large v3 Turbo Q (quantized) ★ | 632 MB |
| < 8 GB | Small (multilingual) | 244 MB |

WhisperKit CoreML compilation happens once on first use. Subsequent sessions are fast.

## Speaker Diarization

After each recording, Memgram identifies who spoke when using two Sortformer models (one for microphone, one for system audio). Speakers are labeled Room 1/2 (in-room) and Remote 1/2 (remote participants).

**Voice enrollment** — record a 5-second voice sample in **Settings → Recording → Enroll Voice**. Enrolled speakers are labeled by name in the transcript and AI summary. The LLM also uses calendar attendee names to resolve unnamed speakers.

## AI Summaries

Configure your LLM in **Settings → AI** (gear icon in the popover):

| Backend | Notes |
|---------|-------|
| **Qwen 3.5 (Local)** | In-process via Apple MLX. Downloads ~4.5 GB. Requires Apple Silicon. Streams tokens in real time. |
| **Custom Server** | Any OpenAI-compatible server (LM Studio, vLLM, Ollama, mlx_lm.server). Streams tokens in real time. |
| **Claude / OpenAI / Gemini** | Cloud API, key stored in Keychain. Streams tokens in real time. |

All providers use a 10-minute request timeout. API keys are Keychain-only — never UserDefaults or SQLite.

## Architecture

```
MicrophoneCapture (16kHz mono)
       ↓
   StereoMixer  ←  CoreAudioTap / ScreenCaptureKit
       ↓ 10s stereo chunks
 TranscriptionEngine (Parakeet/WhisperKit, ANE/Metal)
       ↓ segments → MeetingStore (GRDB, WAL, FTS5)
 SpeakerDiarizer (Sortformer × 2, batch post-processing)
       ↓ speaker labels per segment
 SummaryEngine (background Task)
       ↓ Markdown summary + auto-title
   SearchEngine (FTS5 BM25 × 0.4 + cosine × 0.6)
```

SQLite at `~/Library/Application Support/Memgram/memgram.db`. Audio discarded after transcription.

### iCloud Sync

Meetings, transcript segments, and speaker names sync automatically via CloudKit (`CKSyncEngine`, macOS 14+). Data lives in a custom zone (`MemgramZone`) in the CloudKit private database. Embeddings and FTS indexes are not synced — they are regenerated locally.

On first launch with sync enabled, all existing local data is uploaded. Subsequent changes are synced incrementally. Conflict resolution is last-writer-wins.

### Calendar Integration

Uses EventKit (no OAuth — works with any calendar source added to macOS). When enabled:

- Popover shows the next event starting within 15 minutes with a "Record This Meeting" button
- Menu bar icon turns purple `calendar.badge.clock` and pulses; reverts 10 minutes after event start
- A system notification fires 1 minute before the event with a "Start Recording" action
- Recording automatically attaches the event's title, notes, and attendee names
- The LLM summary prompt includes this metadata for better proper noun correction and speaker identification
- Calendar metadata (`calendarEventId`, `calendarContext` JSON) is stored on the meeting and synced via iCloud

Select which calendars to monitor in **Settings → Calendar → Calendars to Monitor** (all monitored by default).

## Package Dependencies

| Package | Purpose |
|---------|---------|
| GRDB 6.x | SQLite with WAL and FTS5 |
| FluidAudio | Parakeet TDT transcription (ANE) + Sortformer speaker diarization |
| WhisperKit (ekabanov fork) | Transcription — fork relaxes `swift-transformers` constraint to allow >= 1.2.0 |
| mlx-swift-lm (main) | Qwen local inference via Apple MLX |
| swift-markdown-ui 2.x | Markdown rendering in summary tab |

## Bug Reporting & Automated Fixes

Users can report bugs from **Settings → Help**. The form collects a description, steps to reproduce, and an anonymised diagnostic payload (app version, macOS version, hardware model, last 30 minutes of app logs, anonymous meeting metadata — never transcript or summary content).

Submitted reports go to the private [`ekabanov/memgram-bugs`](https://github.com/ekabanov/memgram-bugs) repo as GitHub Issues. A GitHub Actions workflow then:

1. Extracts the JSON payload from the issue body
2. Builds a structured prompt and runs a Claude Code agent against a full checkout of this repo
3. If the agent identifies the root cause and produces a passing build, it opens a PR automatically
4. A human reviews and merges (or closes) the PR; the original issue is linked via `Closes #N`

Issues that can't be auto-fixed are labeled `needs-human-review` for manual triage.

## Privacy

- Audio is never stored (discarded immediately after transcription)
- Transcripts stored locally in SQLite only
- Network requests only when using cloud LLM providers or syncing via iCloud
- CoreAudio ProcessTap (macOS 14.4+) for system audio — no screen content captured

## Build

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build
```

Add new Swift files → run `xcodegen generate` first.

## License

MIT
