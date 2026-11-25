#!/bin/bash
# One-command setup from a clone: checks every dependency, installs what it can,
# is explicit about what it cannot, then builds and installs the app.
#
# Everything here is also fixable from inside the app (the setup sheet on first
# launch), so this script is for people starting from the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

status() { printf "==> %s\n" "$1"; }
ok()     { printf "    ✓ %s\n" "$1"; }
warn()   { printf "    ! %s\n" "$1"; }

status "Xcode"
FOUND_XCODE=""
for candidate in /Applications/Xcode.app /Applications/Xcode-beta*.app /Applications/Xcode*.app; do
  [ -d "$candidate/Contents/Developer" ] && FOUND_XCODE="$candidate" && break
done
if [ -n "$FOUND_XCODE" ]; then
  ok "$FOUND_XCODE"
else
  warn "Full Xcode is required to build (SwiftUI's macro plugin is not in Command Line Tools)."
  warn "Install it from the App Store, then re-run this script."
  exit 1
fi

status "Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "$(command -v brew)"
else
  warn "Homebrew is not installed. It is needed for whisper-cpp."
  warn "Install it from https://brew.sh then re-run. (Its installer wants your"
  warn "password, so this script will not run it for you.)"
  exit 1
fi

status "whisper-cpp"
if command -v whisper-cli >/dev/null 2>&1; then
  ok "$(command -v whisper-cli)"
else
  echo "    installing with Homebrew…"
  HOMEBREW_NO_AUTO_UPDATE=1 brew install whisper-cpp
  ok "$(command -v whisper-cli)"
fi

status "Whisper model"
# Any large-v3-turbo counts; fetch-model.sh picks the precision for this Mac.
MODEL="$(ls "$HOME/Library/Application Support/Minutes/Models/"ggml-large-v3-turbo*.bin 2>/dev/null | head -1 || true)"
if [ -n "$MODEL" ] && [ -f "$MODEL" ]; then
  ok "$(basename "$MODEL") ($(du -m "$MODEL" | cut -f1) MB)"
else
  echo "    downloading (once)…"
  ./Scripts/fetch-model.sh
fi

status "Claude Code"
if command -v claude >/dev/null 2>&1; then
  if claude auth status 2>/dev/null | grep -q '"loggedIn": true'; then
    ok "installed and signed in"
  else
    warn "Installed but signed out. Run:  claude auth login"
    warn "Summaries and chat will fail until you do; recording still works."
  fi
else
  warn "The claude CLI is not installed. It writes the meeting notes on your"
  warn "Claude subscription. Get it at https://claude.com/claude-code, then run"
  warn "\`claude\` once to sign in. Recording works without it; notes will not."
fi

status "Building and installing Minutes"
./Scripts/build-app.sh --install

echo
echo "Done. Minutes is in /Applications and running."
echo "First recording asks for Microphone and Audio Recording permission —"
echo "grant both, then Settings > Permissions > Test now confirms system audio."
