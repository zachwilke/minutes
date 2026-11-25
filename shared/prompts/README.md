# Shared prompts

The text that steers Claude is the product. If it drifts between platforms, the
two apps quietly stop behaving the same — same buttons, different notes. So the
prose lives here, once, and each platform generates code from it.

| File | Contents |
|---|---|
| `summary.json` | Summary system prompt, the prose blocks used when assembling a summary request, and the six summary templates (id, name, blurb, instructions). |
| `chat.json` | Ask system prompt and the two prose notes in the retrieval context. |
| `recipes.json` | Saved chat prompts offered in Ask: id, title, scope (`meeting`, `library`, `any`, or `upcoming` for calendar briefs, which fill `{{title}}`, `{{start}}` and `{{attendees}}` — the last as ", with A, B" or empty) and the prompt sent as the question. |
| `detection-apps.json` | The conferencing apps meeting detection recognises: bundle/executable prefix, display name, and whether it is ambiguous (browsers ask first). |
| `baseline.txt` | The parity contract — see below. |

## Generated, not loaded

Each platform generates constants at build time rather than reading these files
at runtime:

- macOS: `macos/Scripts/generate-prompts.py` → `macos/Sources/Minutes/Generated/Prompts.swift`
- Windows: `windows/Scripts/generate-prompts.py` → `windows/src/Minutes.Core/Prompts/SharedPrompts.g.cs`

That is deliberate. A missing or malformed resource would fail at the worst
possible moment — the end of a meeting, with the audio already captured — while
a generation step fails at build time on a developer's machine.
`macos/Scripts/build-app.sh` runs the generator with `--check` and refuses to
build if the generated file is stale, so the two can never silently diverge.

Edit the JSON, run the generator, commit both.

## What is here and what is not

**Here:** every paragraph of instruction the model reads.

**Not here:** the structural scaffolding that frames those paragraphs — section
headings (`## Metadata`, `## My notes`, `## Transcript`, `## What to produce`,
`## Every meeting in the library (N)`, `## Notes from these meetings`,
`## Full transcripts`, `## Coverage`, `# Conversation so far`,
`# The user's question`), the metadata bullet labels (`- Title:`, `- Date:`,
`- Duration:`, `- Platform:`, `- Invited:`), and the triple-backtick fences.
Those are format rather than instruction, and keeping them in code keeps the
assembly readable. They are still part of the prompt, so parity is enforced by
the baseline rather than by sharing the strings.

## The parity contract

`baseline.txt` is the full rendered output of every prompt — system prompts,
all six templates, assembled summary requests with and without user notes, and
the chat context and assembled chat prompt — against fixed fixtures with the
timezone pinned to UTC.

Regenerate and compare on macOS:

```bash
macos/.build/release/Minutes --dump-prompts | diff shared/prompts/baseline.txt -
```

The Windows port must produce this file byte for byte from the same fixtures.
That single check covers the prose, the scaffolding, the assembly order and the
retrieval layering all at once — a stronger guarantee than sharing strings
alone, because it tests the composed result rather than its ingredients.

Fixtures are defined in `macos/Sources/Minutes/Support/PromptAudit.swift`;
the Windows equivalent must use the same values.
