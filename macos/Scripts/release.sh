#!/bin/bash
# Builds the DMG and publishes it as a GitHub release.
# Usage: ./Scripts/release.sh            (uses VERSION from build-app.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' Scripts/build-app.sh | head -1)"
TAG="v$VERSION"
DMG="build/Minutes-$VERSION.dmg"

command -v gh >/dev/null || { echo "error: the gh CLI is required (brew install gh)" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || { echo "error: commit or stash changes before releasing" >&2; exit 1; }

# A tag that already has a release keeps its original assets — a second upload
# with the same name leaves the release half-updated (new notes applied, old
# DMG still served). Different bits get a new version.
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "error: release $TAG already exists. Bump VERSION in Scripts/build-app.sh" >&2
  echo "       and release the new build under its own tag." >&2
  exit 1
fi

# A tag left behind by a failed earlier run must name this commit, or the
# release would publish a DMG built from different code than its tag.
if git rev-parse "$TAG" >/dev/null 2>&1 \
   && [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
  echo "error: tag $TAG already exists on a different commit." >&2
  echo "       Delete it (git tag -d $TAG; git push origin :$TAG) or bump VERSION." >&2
  exit 1
fi

./Scripts/make-dmg.sh

# make-dmg.sh accepts any signature build-app.sh fell back to. A public release
# must be Developer ID signed: ad-hoc and self-signed builds cannot be opened
# from a download at all, and the notes below would misdescribe them.
# Captured first: under pipefail, `codesign | grep -q` fails whenever grep
# exits on its first match and codesign is still writing.
SIGNING="$(codesign -dvv build/Minutes.app 2>&1 || true)"
case "$SIGNING" in
  *"Authority=Developer ID Application"*) ;;
  *) echo "error: the app is not Developer ID signed — refusing to release" >&2; exit 1 ;;
esac

echo "==> Tagging $TAG"
if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag -a "$TAG" -m "Minutes $VERSION"
  git push origin "$TAG"
fi

# The release notes tell the truth about Gatekeeper: stapled builds open
# normally, unstapled ones need a one-time approval in System Settings.
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  GATEKEEPER_NOTE="This build is notarized — it downloads and opens normally."
else
  GATEKEEPER_NOTE="**First open:** this build is Developer ID signed but not notarized, so a
downloaded copy is blocked on first launch. Open it once, then go to System
Settings › Privacy & Security and choose **Open Anyway**. After that it opens
normally."
fi

echo "==> Creating GitHub release"
gh release create "$TAG" "$DMG" \
  --title "Minutes $VERSION" \
  --notes "$(cat <<NOTES
Drag Minutes to Applications. If ITEMinutes is installed, delete it — your meetings move across on first launch, and macOS will ask for Microphone and Audio Recording again.

$GATEKEEPER_NOTE

On first launch the app checks its dependencies (whisper-cpp, the speech model,
the claude CLI) and offers to install what is missing. Recording asks for
Microphone and Audio Recording permission the first time.

Requires macOS 27+ on Apple silicon and a Claude subscription for notes.
NOTES
)"

echo "==> Done"
gh release view "$TAG" 2>/dev/null | head -8 || true
