# Memgram

> *Every word, perfectly remembered.*

Memgram is a private, offline-first macOS meeting recorder. It silently captures microphone and system audio during meetings, transcribes locally via WhisperKit, generates AI summaries, and provides semantic search across all past meetings — entirely on your Mac. No servers. No bots. No audio stored.

## Features

- **Menu bar app** — always available, never in the way
- **Dual-channel capture** — mic (you) + system audio (remote) captured simultaneously
- **Local transcription** — WhisperKit (Metal decoder + Neural Engine encoder), auto-downloads models
- **Speaker diarisation** — stereo routing separates "You" from "Remote" speakers
- **AI summaries** — triggered automatically after each meeting; structured SUMMARY / KEY DECISIONS / ACTION ITEMS
- **Semantic search** — hybrid FTS5 + cosine similarity across all transcripts (Cmd+F)
- **Full main window** — browseable meeting history with editable titles, action items, and transcript

## Requirements

- macOS 14.0 or later
- Apple Silicon (M1 or later) recommended — required for local Qwen AI summaries
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) to regenerate the project after editing `project.yml`

## Getting Started

```bash
git clone https://github.com/ekabanov/memgram
cd memgram
xcodegen generate
open Memgram.xcodeproj
```

Build and run from Xcode. On first launch, Memgram walks you through microphone and system audio permissions, then prompts to download a Whisper model.

## Transcription Models

WhisperKit downloads and caches models automatically from HuggingFace on first use. Select a model from the menu bar popover. Recommended: **Large v3 Turbo Q** (632 MB, fast, multilingual).

| Display Name | WhisperKit ID | Size |
|---|---|---|
| Tiny EN | openai_whisper-tiny.en | 39 MB |
| Small EN | openai_whisper-small.en | 244 MB |
| Large v3 Turbo Q ★ | openai_whisper-large-v3-v20240930_turbo_632MB | 632 MB |
| Large v3 | openai_whisper-large-v3-v20240930_626MB | 626 MB |

CoreML model compilation happens on first use (one-time, ~2–5 minutes). Subsequent sessions are fast.

## AI Summaries

Configure your LLM backend in **Settings → AI**:

| Backend | Notes |
|---|---|
| **Qwen 3.5 9B (Local)** ★ | In-process via Apple MLX. Download ~4.5 GB once. Requires Apple Silicon. |
| **Ollama** | Requires [Ollama](https://ollama.ai) running locally |
| **Custom Server** | Any OpenAI-compatible server (LM Studio, mlx_lm.server, vLLM) |
| **Claude** | Anthropic API key required |
| **OpenAI** | OpenAI API key required |
| **Gemini** | Google API key required |

API keys are stored in the macOS Keychain — never in UserDefaults or SQLite.

## Architecture

```
MicrophoneCapture (AVAudioEngine, 16kHz mono)
       ↓
   StereoMixer  ←  SystemAudioCaptureProvider (CoreAudioTap / ScreenCaptureKit)
       ↓ 30s stereo chunks
 TranscriptionEngine (WhisperKit, Metal + ANE)
       ↓ TranscriptSegments
   MeetingStore (GRDB SQLite, WAL mode, FTS5)
       ↓
 SummaryEngine + EmbeddingEngine (background, post-recording)
       ↓
   SearchEngine (FTS5 BM25 × 0.4 + cosine × 0.6)
```

Data lives in `~/Library/Application Support/Memgram/memgram.db`. Audio is discarded immediately after transcription — transcripts only.

## Package Dependencies

| Package | Version | Purpose |
|---|---|---|
| GRDB | 6.x | SQLite (WAL, FTS5) |
| WhisperKit | 0.9+ | Transcription (Metal/ANE, auto-downloads) |
| MLXSwiftLM | commit `4051621` | Qwen 3.5 local inference via Apple MLX |

> **Note on MLXSwiftLM:** Pinned to a specific commit because WhisperKit and the latest MLXSwiftLM main branch require incompatible versions of `swift-transformers`. When WhisperKit updates to support `swift-transformers >= 1.2.0`, switch MLXSwiftLM to `branch: main`.

## Privacy

- No audio is ever stored or transmitted
- Transcripts are stored locally in SQLite only
- Network requests only occur when using cloud LLM providers (Claude, OpenAI, Gemini)
- The app requests Screen Recording permission only to capture system audio on macOS < 14.4; no screen content is ever captured or stored
- CoreAudio ProcessTap (macOS 14.4+) requires a separate system audio permission — granted on first launch

## Build System

The Xcode project is generated from `project.yml` via [xcodegen](https://github.com/yonaskolb/XcodeGen). After adding new Swift files, run `xcodegen generate` before building.

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build
```

## License

MIT
