# Memgram

> *Every word, perfectly remembered.*

Memgram is a private, offline-first macOS meeting recorder. It silently captures microphone and system audio, transcribes locally via whisper.cpp, generates AI summaries, and provides semantic search across all past meetings — entirely on your Mac. No servers. No bots. No audio stored.

## Features

- **Menu bar app** — always available, never in the way
- **Dual-channel capture** — mic (you) + system audio (remote) captured simultaneously
- **Local transcription** — whisper.cpp via Metal GPU, models from tiny.en to medium.en
- **Speaker diarisation** — stereo routing separates "You" from "Remote" speakers
- **AI summaries** — triggered automatically after each meeting; choose your LLM backend
- **Semantic search** — hybrid FTS5 + cosine similarity across all transcripts
- **Full main window** — browseable meeting history with editable titles, action items, and transcript

## Requirements

- macOS 13.0 (Ventura) or later
- macOS 14.4+ recommended for CoreAudio tap (system audio without Screen Recording prompt)
- Xcode 15+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) to regenerate the project after editing `project.yml`

## Getting Started

```bash
git clone https://github.com/ekabanov/memgram
cd memgram
xcodegen generate
open Memgram.xcodeproj
```

Build and run from Xcode. On first launch, Memgram will walk you through microphone and screen-capture permissions, then prompt you to download a Whisper model.

## Transcription Models

Whisper models are downloaded on demand to `~/Library/Application Support/Memgram/models/`. Open the model picker from the menu bar popover to switch between:

| Model | Size | Speed |
|-------|------|-------|
| tiny.en | 75 MB | Fastest |
| base.en | 142 MB | Fast |
| small.en | 466 MB | Good |
| medium.en | 1.5 GB | Best accuracy |

Each model also downloads a CoreML encoder (~80 MB) for Neural Engine acceleration.

## AI Summaries & Search

Configure your LLM backend in **Settings → AI**:

- **Ollama (local)** — requires [Ollama](https://ollama.ai) running locally with `llama3.2` and `nomic-embed-text`
- **Claude API** — uses `claude-sonnet-4-6`; embeddings delegate to local Ollama
- **OpenAI API** — uses `gpt-4o-mini` + `text-embedding-3-small`

API keys are stored in the macOS Keychain — never in UserDefaults or SQLite.

## Architecture

```
MicrophoneCapture (AVAudioEngine, 16kHz mono)
       ↓
   StereoMixer  ←  SystemAudioCaptureProvider (CoreAudioTap / ScreenCaptureKit)
       ↓ 30s stereo chunks
 TranscriptionEngine (SwiftWhisper + whisper.cpp)
       ↓ TranscriptSegments
   MeetingStore (GRDB SQLite, WAL mode, FTS5)
       ↓
 SummaryEngine + EmbeddingEngine (background, post-recording)
       ↓
   SearchEngine (FTS5 BM25 × 0.4 + cosine × 0.6)
```

Data lives in `~/Library/Application Support/Memgram/memgram.db`. Audio is discarded immediately after transcription — transcripts only.

## Privacy

- No audio is ever stored or transmitted
- Transcripts are stored locally in SQLite only
- Network requests only occur if you configure Claude API or OpenAI in Settings
- The app requests Screen Recording permission only to capture system audio; no screen content is ever captured or stored

## Build System

The Xcode project is generated from `project.yml` via [xcodegen](https://github.com/yonaskolb/XcodeGen). After adding new Swift files, run `xcodegen generate` before building.

```bash
xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build
```

## License

MIT
