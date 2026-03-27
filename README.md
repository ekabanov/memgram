# Memgram

> *Every word, perfectly remembered.*

Memgram is a private, offline-first macOS meeting recorder. It silently captures microphone and system audio, transcribes locally via WhisperKit, generates AI summaries, and provides semantic search — entirely on your Mac. No servers. No bots. No audio stored.

## Features

- **Menu bar app** — always available, never in the way
- **Dual-channel capture** — mic (you) + system audio (remote) simultaneously
- **Local transcription** — WhisperKit (Metal decoder + Neural Engine encoder), auto-selects model based on your RAM
- **Speaker diarisation** — stereo routing separates "You" from "Remote"
- **AI summaries** — generated after each meeting; structured Markdown with participants, topics, decisions, action items
- **Inline search** — filter transcript segments by text or speaker; global semantic search (Cmd+F)
- **Summary tab** — rendered Markdown with Copy and Regenerate (choose model inline)
- **Auto-titling** — LLM generates a 4–8 word title from the summary
- **iCloud sync** — meetings, transcripts, and speaker names sync across Macs via CloudKit

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

On first launch: grant microphone + system audio permissions, choose English or Multilingual transcription, optionally pre-load the model.

## Transcription

WhisperKit downloads and caches models automatically. The model is chosen automatically based on your Mac's RAM and language preference (set in the model picker):

| RAM | Model | Size |
|-----|-------|------|
| 16 GB+ | Large v3 Turbo (full precision) | 954 MB |
| 8 GB | Large v3 Turbo Q (quantized) ★ | 632 MB |
| < 8 GB | Small / Small EN | 244 MB |

CoreML compilation happens once on first use. Subsequent sessions are fast.

## AI Summaries

Configure your LLM in **Settings → AI** (gear icon in the popover):

| Backend | Notes |
|---------|-------|
| **Qwen 3.5 9B (Local)** | In-process via Apple MLX. Downloads ~4.5 GB. Requires Apple Silicon. |
| **Ollama** | Requires [Ollama](https://ollama.ai) running locally |
| **Custom Server** | Any OpenAI-compatible server (LM Studio, vLLM, mlx_lm.server) |
| **Claude / OpenAI / Gemini** | Cloud API, key stored in Keychain |

All providers use a 10-minute request timeout. API keys are Keychain-only — never UserDefaults or SQLite.

## Architecture

```
MicrophoneCapture (16kHz mono)
       ↓
   StereoMixer  ←  CoreAudioTap / ScreenCaptureKit
       ↓ 30s stereo chunks
 TranscriptionEngine (WhisperKit, Metal + ANE)
       ↓ segments → MeetingStore (GRDB, WAL, FTS5)
 SummaryEngine (background Task)
       ↓ Markdown summary + auto-title
   SearchEngine (FTS5 BM25 × 0.4 + cosine × 0.6)
```

SQLite at `~/Library/Application Support/Memgram/memgram.db`. Audio discarded after transcription.

### iCloud Sync

Meetings, transcript segments, and speaker names sync automatically via CloudKit (`CKSyncEngine`, macOS 14+). Data lives in a custom zone (`MemgramZone`) in the CloudKit private database. Embeddings and FTS indexes are not synced — they are regenerated locally.

On first launch with sync enabled, all existing local data is uploaded. Subsequent changes are synced incrementally. Conflict resolution is last-writer-wins.

## Package Dependencies

| Package | Purpose |
|---------|---------|
| GRDB 6.x | SQLite with WAL and FTS5 |
| WhisperKit 0.9+ | Transcription (auto-downloads models) |
| mlx-swift-lm (pinned commit) | Qwen local inference via Apple MLX |
| swift-markdown-ui 2.x | Markdown rendering in summary tab |

> **Note on mlx-swift-lm:** Pinned to a specific commit because WhisperKit and the mlx-swift-lm main branch require incompatible versions of `swift-transformers`. Update when WhisperKit supports `swift-transformers >= 1.2.0`.

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
