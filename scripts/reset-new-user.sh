#!/usr/bin/env bash
# reset-new-user.sh — Reset Memgram to a clean first-launch state for testing.
# Usage: ./scripts/reset-new-user.sh [--keep-meetings] [--keep-models]

set -euo pipefail

BUNDLE_ID="com.memgram.app"
KEEP_MEETINGS=false
KEEP_MODELS=false

for arg in "$@"; do
  case $arg in
    --keep-meetings) KEEP_MEETINGS=true ;;
    --keep-models)   KEEP_MODELS=true ;;
  esac
done

echo "🔄  Resetting Memgram to new-user state…"

# 1. Kill app if running
if pgrep -x Memgram &>/dev/null; then
  echo "   Stopping Memgram…"
  pkill -x Memgram || true
  sleep 1
fi

# 2. Clear UserDefaults
echo "   Clearing UserDefaults…"
defaults delete "$BUNDLE_ID" 2>/dev/null || true

# 3. Revoke TCC permissions
echo "   Revoking mic + screen capture permissions…"
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true

# 4. Remove database (meetings, segments, embeddings)
if [ "$KEEP_MEETINGS" = false ]; then
  echo "   Removing SQLite database…"
  rm -rf ~/Library/Containers/"$BUNDLE_ID"/Data/Library/Application\ Support/Memgram
fi

# 5. Remove model caches
if [ "$KEEP_MODELS" = false ]; then
  echo "   Removing WhisperKit model cache…"
  rm -rf ~/Library/Caches/huggingface
  echo "   Removing Qwen/MLX model cache…"
  rm -rf ~/Library/Containers/"$BUNDLE_ID"/Data/Library/Caches/models
fi

echo ""
echo "✅  Done. Launch Memgram from Xcode — you'll see the first-launch experience."
echo ""
echo "   Options:"
echo "     --keep-meetings   Skip database deletion (keep recorded meetings)"
echo "     --keep-models     Skip model cache deletion (skip re-download)"
