#!/bin/bash
# Downloads a Whisper model into the app's Models folder.
# Usage: ./Scripts/fetch-model.sh [large-v3-turbo|large-v3-turbo-q5_0|medium.en|small.en|base.en]
#
# With no argument, picks for this Mac: the 5-bit quantized copy on 8 GB or
# less (about 1 GB less memory while transcribing), full precision otherwise.
# The app makes the same choice.
set -euo pipefail

if [ -n "${1:-}" ]; then
  MODEL="$1"
elif [ "$(sysctl -n hw.memsize)" -le $((8 * 1024 * 1024 * 1024)) ]; then
  MODEL="large-v3-turbo-q5_0"
else
  MODEL="large-v3-turbo"
fi
DEST="$HOME/Library/Application Support/Minutes/Models"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"

mkdir -p "$DEST"
TARGET="$DEST/ggml-${MODEL}.bin"

if [ -f "$TARGET" ]; then
  echo "Already present: $TARGET"
  exit 0
fi

echo "Downloading ggml-${MODEL}.bin from huggingface.co…"
curl -L --fail --progress-bar -o "$TARGET.part" "$URL"

# Pinned hashes for the default models (Hugging Face's LFS X-Linked-ETag). A
# truncated or corrupted model still loads, then fails at the end of a meeting.
EXPECTED=""
case "$MODEL" in
  large-v3-turbo)      EXPECTED="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69" ;;
  large-v3-turbo-q5_0) EXPECTED="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2" ;;
esac
if [ -n "$EXPECTED" ]; then
  ACTUAL="$(shasum -a 256 "$TARGET.part" | cut -d' ' -f1)"
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    rm -f "$TARGET.part"
    echo "error: checksum mismatch for ggml-${MODEL}.bin (got $ACTUAL)" >&2
    exit 1
  fi
  echo "Checksum verified."
fi
mv "$TARGET.part" "$TARGET"
echo "Installed: $TARGET"
ls -lh "$TARGET"
