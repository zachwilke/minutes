# Contributing

Thanks for taking a look. Issues and pull requests are both welcome.

## Before you start

For anything beyond a small fix, open an issue first and say what you have in
mind. The macOS app is the reference implementation; the Windows port follows
[`windows/PLAN.md`](windows/PLAN.md) and is not yet an app.

## Getting set up

**macOS app** — needs macOS 27 or later on Apple silicon and **full Xcode**, not
just the Command Line Tools: SwiftUI's property wrappers are macros on macOS
26+ and the plugin that expands them ships only with Xcode.

```bash
swift build --package-path macos
```

```bash
swift test --package-path macos
```

`./macos/Scripts/install.sh` installs the runtime dependencies (whisper-cpp and
the speech model) and builds the app into `/Applications`.

**Windows core** — a .NET SDK matching the target framework in the `.csproj`
files. It builds and tests on macOS and Linux too, which is how prompt parity
is checked.

```bash
dotnet test windows/Minutes.sln
```

## The rules that are easy to break

**Prompts are shared.** Every paragraph the model reads lives in
[`shared/prompts/`](shared/prompts/) as JSON and is generated into each
platform's source. Do not edit `macos/Sources/Minutes/Generated/Prompts.swift`
or `windows/src/Minutes.Core/Prompts/SharedPrompts.g.cs` by hand — edit the
JSON, run both generators, and commit all three:

```bash
macos/Scripts/generate-prompts.py && windows/Scripts/generate-prompts.py
```

`build-app.sh` runs the generator with `--check` and refuses to build when the
generated file is stale.

**The prompt baseline is a contract.** `shared/prompts/baseline.txt` is the full
rendered output of every prompt against fixed fixtures, and both platforms must
produce it byte for byte. If a change alters it legitimately, regenerate it in
the same commit:

```bash
macos/.build/release/Minutes --dump-prompts > shared/prompts/baseline.txt
```

**The storage format is a contract too.** A library has to open on either
platform; [`shared/spec/meeting-format.md`](shared/spec/meeting-format.md) is
the specification. Readers must tolerate fields they do not know and writers
must preserve them, so a newer build or the other platform never loses data.

**Nothing new should leave the machine.** Recording, transcription, speaker
labels and search are local, and only two things reach Claude: writing a
meeting's notes, and a question the user asked. A change that sends anything
else anywhere needs to be discussed in an issue first.

## Pull requests

- One topic per pull request.
- Tests pass on both platforms (`swift test`, `dotnet test`).
- No real names, client names, email addresses or recordings in test fixtures
  or documentation — use invented ones.
- Say in the description what you changed and why; the "why" is the part that
  is hard to recover later.

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE).
