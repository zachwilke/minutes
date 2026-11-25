# Minutes for Windows — execution plan

The goal is the same product: record both sides of a meeting locally,
transcribe on the machine, write notes with the user's Claude subscription —
with the same care for feel and the same performance discipline. This plan maps
every macOS subsystem to its Windows equivalent, sequences the work, and states
what "done" means per phase.

**Ground rule:** everything the macOS build learned the hard way is a
requirement here, not a rediscovery — timeline-based audio alignment, first-
source capture gating, per-meeting pipeline state, prompts asked with context,
honest degraded modes.

## Constraints and budgets

- Local-only: no audio or transcript leaves the machine; notes via `claude` CLI.
- Same on-disk library format (`shared/spec/meeting-format.md`) — a library is
  portable between Macs and PCs.
- Performance budgets (matching measured macOS numbers): idle < 1% CPU and
  < 100 MB working set; click→capture < 150 ms; window visible < 500 ms after
  process start; level meters must not re-render whole views.
- Windows 11 (21H2+) x64/ARM64. Win10 is out of scope (process-loopback and
  Mica both want Win11).

## Subsystem mapping

| Concern | macOS (shipped) | Windows (planned) |
|---|---|---|
| System audio | Core Audio process tap | WASAPI **loopback** on the default render endpoint (`AUDCLNT_STREAMFLAGS_LOOPBACK`). Simpler than macOS: no permission gate at all. Exclude our own playback with process-loopback (`ActivateAudioInterfaceAsync` + `PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE`) — unlike macOS, exclusion works here. |
| Microphone | AVAudioEngine | WASAPI capture, shared mode, event-driven. Consent: packaged apps go through the Settings › Privacy › Microphone gate; handle denial like macOS does. |
| Clock alignment | host-time timeline, silence-filled gaps | identical design; WASAPI gives QPC timestamps per buffer (`IAudioCaptureClient::GetBuffer` position + `GetDevicePosition`). Loopback goes silent when nothing plays — same burstiness, same fix. |
| Meeting detection | `kAudioProcessPropertyIsRunningInput` per process | `IAudioSessionManager2` on the capture endpoint → enumerate sessions → `AudioSessionStateActive` + PID → process image name. Same known-app table, same two-poll confirmation, browsers ambiguous. |
| Live transcript | Apple SpeechAnalyzer | whisper.cpp **stream** mode with `base.en`/`small` (Windows offline dictation is not good enough). Live text is a convenience; the final pass is authoritative either way. |
| Final transcript | whisper-cli via brew | **Bundle** whisper.cpp binaries in the installer (CPU + Vulkan builds; pick at runtime). No package manager needed — smoother than the Mac. Model downloaded on first run exactly like the Mac setup sheet. |
| Notes / chat | `claude -p`, stream-json | identical — Claude Code ships a native Windows CLI. Same `auth status` check, same stream parsing, same context builder. |
| Speaker labels | mic-vs-system energy | identical (`energy.bin` format shared). |
| Menu bar | MenuBarExtra | tray icon (`NotifyIcon`) + WinUI flyout; detection prompt as a **toast** with Record/Ignore buttons (`AppNotificationManager`), floating fallback not needed — toasts don't have macOS's denial trap, but handle Focus Assist. |
| Vibrancy / glass | NSVisualEffectView + glassEffect | **Mica** window backdrop + **Acrylic** for floating surfaces (`SystemBackdrop` in WinUI 3). Same palette (`shared/design/palette.md`), same capsule/card shape language. |
| Onboarding | first-launch walkthrough | same flow, shorter: loopback needs no permission, so pages are mic, notifications, done. |
| Packaging | DMG, Developer ID, notarized | **MSIX**, Authenticode-signed. SmartScreen reputation is the notarization analogue — see risks. |
| Releases | `release.sh` + gh | same, tags `windows-vX.Y`; macOS moves to `macos-vX.Y` from its next release. |

## Stack decision

**C# / .NET 9 / WinUI 3 (Windows App SDK 1.6+), Native AOT.**

- WinUI 3 is the only stack where Mica/Acrylic, toasts with buttons, and the
  Fluent look are first-class rather than imitated — "beautiful" on Windows
  means looking native there, not porting Liquid Glass.
- C# keeps the codebase readable next to Swift (similar idioms: async/await,
  value types, property observation). Native AOT + trimming keeps launch and
  memory inside budget; the audio path uses preallocated buffers and
  `ArrayPool`, no GC pressure at 10 Hz.
- Audio interop via CsWinRT/`IAudioClient` P/Invoke directly — **no NAudio
  dependency** for the capture core; we need process-loopback and precise QPC
  timestamps, and owning the interop is how the macOS port stayed debuggable.

Considered and rejected: Avalonia (best if Linux ever matters, but backdrop
materials and toasts are imitations), Electron/Tauri (feel + memory budget),
C++/WinRT (velocity; C# AOT closes most of the perf gap).

## Phases

**Phase 0 — shared extraction. DONE.**
Prompt prose, the six summary templates and the conferencing-app table now live
in `shared/prompts/*.json`; macOS generates `Prompts.swift` from them at build
time and `build-app.sh` refuses to build if the generated file is stale.
Verified byte-identical via a new `--dump-prompts` audit (fixed fixtures, UTC
pinned) — hash unchanged across the whole refactor. `shared/prompts/baseline.txt`
is the rendered output of every prompt and is the parity contract Windows must
reproduce exactly; `shared/prompts/README.md` records what is shared, what stays
as per-platform scaffolding, and why generation beats runtime loading.

One defect surfaced and was fixed as a separate, visible change: the shipped
summary system prompt contained two five-space runs, collateral from an earlier
patch where line continuations collapsed with their indentation.

**Phase 1 — capture core (headless). CODE COMPLETE; HARDWARE VERIFICATION PENDING.**
Built as two layers so the risky half could be verified without Windows: all the
logic — band-limited resampler, timestamp-placed capture timeline, mixer, WAV
writer with periodic header refresh and repair, energy track, and the capture
session with parallel start and first-source gating — sits in `Minutes.Core`
with no OS dependency and 22 passing tests, several of which read files the
shipping macOS app actually wrote. The WASAPI interop compiles (a
`net10.0-windows` target cross-compiles on macOS) but has never touched a real
endpoint. The harness runs end to end with synthetic sources, including a
deliberately bursty one: 30 microphone buffers against 3 loopback buffers still
produced exactly 3.00 s of audio, which is the macOS drift bug demonstrably
absent. Remaining: run `--test-capture` and `--time-start` on real hardware, and
add process-loopback exclusion. See `windows/README.md`.

*Review, 2026-10-02.* Real capture could not have started: resamplers were built
from `SampleRate` before the device was open (0 → throw). Fixed — resamplers are
built per source from its first buffer and rebuilt if the rate changes. Also
fixed: sources now open in parallel for real (WASAPI's synchronous COM setup
had serialised them); every COM method is `[PreserveSig]` (the HRESULT checks
were dead and failures threw unobserved on the capture thread); the pump
reopens the endpoint on device invalidation and when the default endpoint
changes (polled every 2 s); drain and buffer timestamps share `CaptureClock`
(QPC) instead of TickCount64; the resampler's short-block history shift. Three
timeline tests asserted only duration and now check placement — verified by
forcing arrival-order mixing, which they catch. Still unverified on hardware.
Native AOT for the audio project still needs a `[GeneratedComInterface]` rewrite.

**Phase 2 — pipeline. CODE COMPLETE, verified off-Windows; Windows run pending.**
Whisper integration, segment parsing with energy labelling, the claude
subprocess with stream-json parsing, and meeting.json against `shared/spec`.
Both acceptance criteria are met, and earlier than expected: `--selftest`
produced a real transcript and a real summary using this machine's whisper-cli
and claude, and a macOS-created library opens and lists correctly — the C#
`--doctor` reads the same three meetings the macOS build reports. Prompt parity
is proven: the C# rendering of all thirteen prompt sections is byte-identical to
`shared/prompts/baseline.txt`, and the build fails if the generated prompts drift
from the shared JSON. JSON is source-generated rather than reflection-based, since
the AOT analyzers correctly refused the reflection path the performance budget
rules out. Remaining for Windows hardware: run `--selftest` and `--doctor` on
Windows itself — the claude/whisper lookup, `%APPDATA%` paths and argument
passing have only run on macOS. *Review, 2026-10-02:* the claude runner now
uses the same lockdown flags as macOS (no tools, no user settings or MCP, no
session persistence; parity-tested against the Swift source), resolves an npm
`claude.cmd` to `node cli.js` instead of routing arguments through cmd.exe,
starts its deadline at launch, reports cancellation as cancellation, and
prompt dates are local time (they were UTC). The build uses `py -3` on Windows.

**Phase 3 — app shell.**
WinUI 3 window (Mica), sidebar + notes/summary panes, tray icon, record
control, per-meeting pipeline state (recording never blocks on processing —
the back-to-back rule), settings. Done when: record → stop → notes end-to-end
in the UI; meters render without re-laying-out the window (verify with the
Composition/XAML frame counters, the WinUI analogue of the 10 Hz fan-out bug).

**Phase 4 — detection, live text, chat, onboarding.**
Session-based meeting detection with the known-app table; toast prompts;
whisper stream live text; Ask chat with the shared context builder; onboarding.
Done when: joining a Teams call on the VM raises a toast whose Record button
starts a capture < 150 ms after click.

**Phase 5 — packaging and release.**
MSIX, Authenticode signing, first-run setup sheet (model download; whisper is
bundled so that step disappears), `windows/Scripts/release.ps1` mirroring the
Mac release script, GitHub release `windows-v0.1`. Done when: a clean Windows
11 VM goes from DMG-equivalent download to summarized test meeting with no
terminal.

Each phase lands as its own set of commits; phases 1–2 are pure logic and can
be developed test-first without touching UI.

## Risks, named now

- **Code-signing cert:** the macOS Apple cert does nothing here. Buy an
  Authenticode cert (OV works; **EV or Azure Trusted Signing bypasses
  SmartScreen reputation faster** — otherwise early downloads get "Windows
  protected your PC", the exact analogue of the pre-notarization right-click).
  Longest lead time in the whole plan; order first.
- **Process-loopback quirks:** excluding our own process tree is Win11-solid
  but per-session; virtual audio devices (VoiceMeeter, some conferencing
  drivers) can bypass the default endpoint. Fallback: plain endpoint loopback
  and accept hearing our own notification sounds (we barely make any).
- **whisper on weak hardware:** no Apple-silicon guarantee. Bundle Vulkan
  build for GPUs, pick model size by benchmark at first run (large-v3-turbo on
  capable machines, small otherwise), and say so in the setup sheet.
- **Claude CLI on Windows** is newer than on macOS; pin a known-good version in
  the setup check and test `auth status` + stream-json against it explicitly.
- **Dev/test environment:** none of this can be built from the Mac. Needs a
  Windows 11 machine or VM (ARM Parallels VM on this Mac works for most of it;
  audio endpoint behaviour should also be spot-checked on real x64 hardware),
  plus a GitHub Actions runner if CI is wanted.

## What stays deliberately shared vs. per-platform

Shared: storage format, prompts/templates, palette + shape scale, the known
conferencing-app table (move to `shared/` in phase 0), release notes voice.
Per-platform: everything that touches OS APIs, UI code (no cross-platform UI
framework — that trade was considered and rejected above), installers.

## Detection rules to match (added with macOS auto-record)

Phase 4 must reproduce the macOS detector and coordinator, not just the app
table. See `macos/Sources/Minutes/Meetings/MeetingDetector.swift` and
`macos/Tests/MinutesTests/MeetingDetectorTests.swift`:

- Each app is tracked separately, keyed by display name (helper processes swap
  bundle IDs mid-call). Start after 2 consecutive polls (3 s apart); end after 5
  polls without the microphone.
- Default mode records automatically for dedicated apps with a Stop/Discard
  notice; browsers ask unless the current calendar event has a meeting link.
  "Ask first" is a setting.
- Auto-stop: the recording's app ends, 15 minutes below RMS 0.008, or system
  sleep. A manual recording adopts a call starting within 2 minutes.
- Ignored or manually stopped calls stay suppressed until that app's call ends;
  when a recording ends, the next unhandled call in progress is offered.
- Custom summary styles live in `templates.json` under the app-data root:
  `[{id, name, blurb, instructions}]`, ids prefixed `custom-`. Hand-edited
  notes set `summaryEditedAt`; regenerating asks before replacing them.
- `speakerNames` replaces You/Them in `TranscriptText` (implemented in Core,
  parity-tested). Settings still to build on Windows: transcription language
  (Whisper `-l`, default `auto`) and notes language (`SummaryPrompt.Build`'s
  `notesLanguage`, already implemented and parity-tested).
