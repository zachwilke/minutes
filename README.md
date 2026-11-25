# Minutes

A local meeting notetaker: it records both sides of a meeting, transcribes on
the machine, and writes structured notes through your own Claude subscription.
No bot joins your calls, no audio leaves the device, no API key. Claude Desktop
and Claude Code can search your meetings through its local MCP server.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

This is a monorepo:

| Directory | What it is |
|---|---|
| [`macos/`](macos/) | The shipping macOS app (SwiftUI, macOS 27+, Apple silicon), currently **2.0.2**. See its README for what's new, install, build, and architecture. |
| [`windows/`](windows/) | The Windows port, in progress: audio, pipeline and prompts, no app yet. See [`windows/PLAN.md`](windows/PLAN.md). |
| [`shared/`](shared/) | Contracts both apps must honour: the meeting storage format, the palette, and the prompt inventory. |

## Quick start (macOS)

Download the latest DMG from the
[releases page](https://github.com/zachwilke/minutes/releases)
and drag Minutes to Applications. Releases are notarized, so they open normally.
Or build from source:

```bash
./macos/Scripts/install.sh
```

That checks and installs the dependencies (whisper-cpp, the speech model),
reports whether the `claude` CLI is signed in, and leaves the app in
`/Applications`. Recording and transcription work without Claude; writing notes
and asking questions do not.

Coming from **ITEMinutes**, the name this app shipped under before: delete the
old app. Your meetings move across on first launch, but macOS will ask for
Microphone and Audio Recording permission again, because the bundle identifier
changed. See [`macos/README.md`](macos/README.md#upgrading-from-iteminutes).

## Privacy

Audio is captured, transcribed and stored on your own machine, as plain files
under `~/Library/Application Support/Minutes/`. Nothing is uploaded, and there
is no account, telemetry or server component.

Two things reach Claude, through your own `claude` sign-in and subject to your
own subscription's terms: writing a meeting's notes when it ends, and any
question you ask. Both are spelled out in
[What reaches Claude](macos/README.md#what-reaches-claude).

**Recording other people has legal and ethical weight**, and the rules differ by
jurisdiction — some require every participant's consent. Minutes makes recording
visible (a menu bar indicator, a visible stop) but it is your responsibility to
tell the people you are meeting and to comply with the law where you are.

## Development

| Task | Command |
|---|---|
| Build the macOS app | `swift build --package-path macos` |
| Test the macOS app | `swift test --package-path macos` |
| Build and test Windows core | `dotnet test windows/Minutes.sln` |
| Regenerate prompt constants | `macos/Scripts/generate-prompts.py` and `windows/Scripts/generate-prompts.py` |
| Regenerate the prompt baseline | `macos/.build/release/Minutes --dump-prompts > shared/prompts/baseline.txt` |

Prompts live in [`shared/prompts/`](shared/prompts/) as JSON and are generated
into each platform's source, so the two apps cannot quietly drift apart;
`shared/prompts/baseline.txt` is the parity contract both must render byte for
byte. See [`shared/prompts/README.md`](shared/prompts/README.md).

Building the macOS app needs full Xcode, not just the Command Line Tools —
SwiftUI's property wrappers are macros on macOS 26+ and the plugin that expands
them ships only with Xcode.

## Releases

Per-platform, tagged from each platform's version: macOS releases are cut with
`macos/Scripts/release.sh` (builds, signs, notarizes, staples, publishes).
Signing and notarization need your own Apple Developer credentials — see
[Code signing](macos/README.md#code-signing). `v2.0.0` is the first release as
Minutes; tags `v1.x` predate both the rename and the monorepo.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE).
