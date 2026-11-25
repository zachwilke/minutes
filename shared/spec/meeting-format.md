# Meeting storage format

Both apps read and write the same on-disk library, so a library is portable
between platforms (and could later sync through a file service). This document
is the contract; the macOS implementation in
`macos/Sources/Minutes/Meetings/Meeting.swift` is the reference.

## Layout

One directory per meeting, named by UUID, under the platform's app-data root
(`~/Library/Application Support/Minutes/Meetings/` on macOS,
`%APPDATA%\Minutes\Meetings\` on Windows):

```
<uuid>/
├── meeting.json     metadata, user notes, transcript segments (authoritative)
├── audio.wav        16 kHz mono 16-bit PCM mixdown of mic + system audio
├── energy.bin       per-chunk loudness, for speaker attribution
├── summary.md       the generated notes, also embedded in meeting.json
└── chat.json        optional, the meeting's own Ask conversation
```

Deleting the directory deletes the meeting. There is no database.

## meeting.json

JSON, ISO-8601 dates, camelCase keys. Fields (all optional unless noted).
Readers must tolerate missing fields and unknown values, and writers must keep
fields they do not recognise, so either app — or a newer build — can save a
meeting without losing what the other wrote.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID string | required; must match the directory name |
| `title` | string | required; user-editable |
| `startedAt` / `endedAt` | ISO-8601 | `endedAt` absent only while recording |
| `state` | string | `recording` `transcribing` `summarizing` `complete` `failed` |
| `detectedAppBundleID` / `detectedAppName` | string | platform-native app identifier |
| `calendarEventTitle`, `attendees` | string, [string] | from the calendar, when enabled |
| `attendeeEmails` | [string] | invitees' addresses, excluding the user's own; companies are derived from their domains |
| `folder` | string | folder name; absent means unfiled |
| `speakerNames` | object | user-given names keyed by speaker (`me`, `others`, `unknown`); they replace You / Them / Speaker wherever the transcript is shown or sent to Claude |
| `notes` | string | the user's own notes; steers the summary |
| `liveTranscript` | string | rough on-device live text; fallback only |
| `segments` | array | the authoritative transcript, see below |
| `summaryMarkdown` | string | GitHub-flavored Markdown |
| `templateID` / `summaryTemplateID` | string | chosen style / style the summary was written with; custom styles have ids starting `custom-` |
| `summaryEditedAt` | ISO-8601 | set when the user edits `summaryMarkdown` by hand; cleared when it is regenerated |
| `failureReason` | string | human-readable |

Segment: `{ id, start, end, speaker, text }` — start/end in seconds from
recording start; `speaker` is `me` | `others` | `unknown` (derived from
mic-vs-system loudness, not voice identification).

## energy.bin

Flat little-endian Float32 triples: `time, mic, system` (seconds, RMS 0–1).
Used to label segments after Whisper runs; safe to regenerate or drop.

## audio.wav

16 kHz, mono, 16-bit PCM, standard RIFF header. Sources are placed on one
timeline by capture timestamp with silence filling gaps — see the macOS
`AudioCaptureEngine` for the reference behaviour. Writers must keep the header
sizes valid during recording (rewrite periodically) so a crash never leaves an
unreadable file.
