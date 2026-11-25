# Minutes for Windows

Phases 1–2 of [PLAN.md](PLAN.md): the capture core and the pipeline. **Not yet a
shippable app** — there is no UI. What exists is the whole headless path from
audio to written notes, and the parts worth trusting are tested.

```
src/Minutes.Core/           audio, pipeline and prompts — OS-agnostic, 33 tests
src/Minutes.Windows.Audio/  WASAPI interop + the headless harness
tests/Minutes.Core.Tests/   the tests, including fixtures from the macOS app
```

## Status, honestly

| Component | State |
|---|---|
| Resampler (48 kHz → 16 kHz, band-limited) | written, **tested** |
| Capture timeline + mixer (timestamp placement, gap filling) | written, **tested** |
| WAV writer, periodic header refresh, repair | written, **tested against macOS output** |
| Energy track + speaker attribution | written, **tested against a real macOS energy.bin** |
| Capture session (parallel start, first-source gating, degradation) | written, **tested with synthetic sources** |
| WASAPI microphone + loopback capture | written, **compiles, never run against hardware** |
| Meeting storage format (meeting.json) | written, **tested against a real macOS meeting.json** |
| Prompt generation from shared/prompts | written, **byte-identical to macOS** |
| Whisper transcription + segment labelling | written, **run for real** |
| Claude notes + stream-json chat | written, **run for real** |

The last row is the honest gap. `net10.0-windows` cross-compiles on macOS, so the
COM interop is type-checked and the harness builds — but no line of it has
touched a real audio endpoint. Vtable order, HRESULT paths and the QPC timestamp
basis are the things most likely to be wrong, and only a Windows machine can say.

Deliberately deferred to when hardware exists: process-loopback exclusion
(`ActivateAudioInterfaceAsync`) so the app does not capture its own output. Plain
endpoint loopback is in place, which is the documented fallback in PLAN.md.

## Running it

Everything except the real devices runs on any OS:

```bash
dotnet test tests/Minutes.Core.Tests
dotnet run --project src/Minutes.Windows.Audio -- --doctor
dotnet run --project src/Minutes.Windows.Audio -- --selftest some.wav
dotnet run --project src/Minutes.Windows.Audio -- --test-capture 3 --synthetic
dotnet run --project src/Minutes.Windows.Audio -- --time-start --synthetic
```

`--doctor` and `--selftest` work on macOS too, because the pipeline shells out to
the same `whisper-cli` and `claude` on both platforms — which is how the pipeline
was verified before any Windows hardware existed.

## Prompt parity

`SharedPrompts.g.cs` is generated from `shared/prompts/*.json` by
`Scripts/generate-prompts.py`, and the build fails if it is stale.
`PromptParityTests` then renders every prompt against the same fixtures the
macOS app uses and diffs the result against `shared/prompts/baseline.txt`. That
one test covers the prose, the section scaffolding, the assembly order and the
retrieval layering at once — the two apps cannot start steering Claude
differently without it failing.

On Windows, drop `--synthetic` to use the real microphone and loopback. That is
the phase-1 acceptance test: both sources capturing with real peaks,
click-to-capture under 150 ms, and a killed process leaving a readable WAV.

## Why the split

Every mistake that hurt the macOS build lived in logic, not in the OS calls: a
mixer that appended buffers in arrival order and drifted the far side of the call
earlier and earlier; a WAV header left claiming zero length by a force-quit; a
capture start that waited for the slowest device. So the logic sits in a project
with no OS dependency, where it can be tested on a laptop, and the OS calls are a
thin shim behind an interface.

`MixerTimelineTests` encodes the drift bug directly: a bursty source that speaks
for 10% of the time must still produce a recording as long as the wall clock. The
synthetic harness demonstrates the same thing end to end — 30 microphone buffers
against 3 loopback buffers, and exactly 3.00 s of audio out.
