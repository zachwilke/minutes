# Minutes

A local meeting notetaker for macOS, in the spirit of Granola, but writing
notes through your own Claude subscription instead of a hosted service.

It listens to both sides of a meeting, transcribes on this Mac, lets you take
your own notes while it runs, and turns the transcript plus those notes into
structured notes when the meeting ends. No bot joins your calls, no audio leaves
the machine, and there is no API key or per-token billing. Current version:
**3.0.0**.

## What's new in 3.0

The first open-source release, and a breaking one.

- **Now simply Minutes.** The last of the old ITEMinutes naming is gone from the
  app, the code and the build. The bundle identifier is
  `com.minutesapp.Minutes`, so **microphone and Audio Recording permissions must
  be granted once more**; the library moves itself to
  `~/Library/Application Support/Minutes/` on first launch. See
  [Upgrading from ITEMinutes](#upgrading-from-iteminutes).
- **The CRM integration is gone.** It was built around one company's connector
  and had no place in a general notetaker. The MCP server is now strictly
  read-only.
- **MIT licensed**, with the source on GitHub.

## What arrived in 2.0

- **A new name and a new look.** The app became Minutes, with a calmer
  paper-and-ink look modelled on
  Granola: a Home page with **Coming up** from your calendar and every meeting
  by day, an **Ask anything** bar, serif titles, and each meeting as a single
  page that turns into the written notes when they land.
- **Impromptu calls are offered, scheduled ones record.** A Teams, Zoom or Meet
  call that isn't on your calendar asks Record / Ignore; one that is records by
  itself. Google Meet, and Teams and Zoom on the web, are recognised from the
  browser tab. Brief false starts are thrown away.
- **Your Outlook calendar**, synced into macOS from Internet Accounts, with a
  choice of which calendars count.
- **Meetings name themselves** from the calendar, the Teams call window, or — for
  impromptu calls — the notes.
- **Notes know who's speaking**: you by name, the invitees, and that a quiet
  voice from the call can be mislabelled as you.
- **Ask Claude about your meetings** from Claude Desktop or Claude Code, through
  a local MCP server with passage search. **Settings › Claude** connects it.
- **Less Claude usage**: only notes and Ask reach Claude, each call without
  Claude Code's own 3,200-token system prompt, and Ask sends a third as much.
- **Runs on an 8 GB M1**: a smaller Whisper model there, transcription that stays
  out of the way of a live call, and a library that loads without its
  transcripts.
- A new icon, a menu bar icon that shows when you're recording, and dates and
  times in your own format.

## How it works

| Stage | What does it |
|---|---|
| System audio | Core Audio process tap (everyone on the call) |
| Microphone | AVAudioEngine (you, and in-person meetings) |
| Live text | Apple's on-device `SpeechTranscriber` |
| Final transcript | `whisper-cli` with `ggml-large-v3-turbo` (5-bit quantized on 8 GB Macs) |
| Speaker labels | Derived from mic-vs-system loudness, no diarization model |
| Notes and Ask | `claude -p`, which authenticates with your Claude subscription |

Recording and transcription never leave the Mac. Writing notes and answering
Ask questions are the only things that reach Claude; see
[What reaches Claude](#what-reaches-claude).

**Settings › Notes › Claude** reports whether writing notes will actually
work. Checking that the binary exists says very little — it can be present and
signed out, or signed in to an account without access to the chosen model. The
routine check reads `claude auth status`, which returns the account as JSON and
costs no tokens, so it runs on its own. A round trip through the model sits
behind a separate button, because it spends subscription quota and should be a
choice rather than a side effect of opening Settings.

Audio is captured from two independent hardware clocks. A process tap only fires
while something is actually playing, so buffers are placed on a shared timeline
by host timestamp and gaps are filled with real silence — otherwise the remote
side would slowly drift earlier than your microphone over a long meeting.

Because we know how loud each source was at every moment, each transcript segment
is labelled **You** or **Them** without running speaker diarization. Where the
two overlap it reports **Speaker** rather than guessing. The labels are a hint,
not identification: a quiet voice from the call against a noisy microphone is
often labelled **You**. So Claude is told your name (**Settings › Notes › You**,
from your Mac account), who was invited, and to attribute lines by what is said —
someone answering a question put to them by name — rather than by label alone.

## Upgrading from ITEMinutes

The app used to be called ITEMinutes and shipped under a different bundle
identifier. Drag Minutes into Applications and delete `ITEMinutes.app`
(`build-app.sh --install` removes it for you). Then:

- **Your meetings come with you.** On first launch the app moves
  `~/Library/Application Support/ITEMinutes/` to
  `~/Library/Application Support/Minutes/` — meetings, models and settings
  together. If a `Minutes` folder already exists the old one is left alone for
  you to look at.
- **Permissions have to be granted again.** macOS keys microphone and Audio
  Recording grants to the bundle identifier, which changed to
  `com.minutesapp.Minutes`. **Settings › General › Permissions** raises both
  prompts without starting a recording.
- **Reconnect the MCP server.** It is now called `minutes`; connect it again
  from **Settings › Claude**.

Window titles left over from older builds — "Acme Status Call | Example Corp |
you@example.com" — are tidied once on first launch.

## Requirements

- macOS 27 or later, so Apple silicon (it uses the `SpeechAnalyzer` API, Core
  Audio process taps, and `AVAudioEngine`'s `installAudioTap`, new in 27). An
  M1 with 8 GB is the smallest Mac it targets.
- `brew install whisper-cpp` — the app offers to install it.
- Claude Code installed and signed in (`claude`), for notes and Ask. Recording
  and transcription work without it.
- **Full Xcode** to build from source. SwiftUI's property wrappers are macros on
  macOS 26+, and the plugin that expands them ships only with Xcode — Command
  Line Tools alone cannot build this. The build script finds Xcode
  automatically.

## Install

**From a release:** download the DMG from the
[releases page](https://github.com/zachwilke/minutes/releases),
drag Minutes to Applications. Notarized releases open normally; if a release
notes says it is unnotarized, open it once, let macOS block it, then choose
**Open Anyway** in System Settings › Privacy & Security. (The old right-click ›
Open bypass no longer works on current macOS.) On first launch the app
checks its own dependencies and offers to fix what it can: it installs
whisper-cpp through Homebrew and downloads the speech model itself, and points
you at Claude Code if the `claude` CLI is missing or signed out. Recording works
without Claude; notes and chat do not.

**From source:**

```bash
./Scripts/install.sh              # checks and installs everything, then builds
```

That script installs whisper-cpp if missing, downloads the model if missing
(the 5-bit quantized one on a Mac with 8 GB or less),
reports the Claude CLI state, and finishes with the app in /Applications. The
individual pieces remain available: `fetch-model.sh`, `build-app.sh [--install]`,
`make-dmg.sh` to package a DMG, and `release.sh` to publish one to GitHub.

**Notarization** happens automatically in `make-dmg.sh` once credentials exist —
twice: the app is notarized and stapled first, so the ticket travels inside the
bundle and a copy dragged to Applications opens offline too, then the DMG
around it is notarized and stapled for the download. Credentials:
run `./Scripts/setup-notary.sh` once, choosing either an app-specific password
(account.apple.com › Sign-In and Security) or an App Store Connect API key. The
credentials live in the keychain as the `Minutes-Notary` profile. Signing
uses `--timestamp` — a secure timestamp is required for notarization, so builds
must be signed online. Without credentials the DMG still builds, unnotarized,
and the release notes say so.

## Permissions

On the first recording macOS asks for two things:

- **Microphone** — your voice and in-person meetings.
- **Audio Recording** — the audio your Mac plays, i.e. everyone else on the call.

Until Audio Recording is granted the tap runs but returns pure silence, which
looks like a working recording with nothing in it. If a recording comes back
empty, check System Settings › Privacy & Security › Audio Recording first.

Both live in **Settings › General › Permissions**, which shows the current state and can
raise the prompt directly — you don't have to start a recording to grant them.
Audio Recording cannot be read by any API, so that row has a **Test now** button
that plays a sound and listens for it.

Grants persist across rebuilds, provided the app is signed with a real
certificate — see [Code signing](#code-signing). If the microphone reads
**Denied** and Minutes is not listed in System Settings at all, so there is
nothing there to switch on, use **Reset & ask again**, which runs
`tccutil reset Microphone com.minutesapp.Minutes`, then relaunch.

`Scripts/Minutes.entitlements` is applied at signing time, and
`com.apple.security.device.audio-input` in that file is load-bearing: under the
Hardened Runtime, microphone and audio-tap access are refused without it —
silently, with no prompt and no System Settings entry. The build script verifies
the entitlement survived signing and warns if it did not.

## Calendar

Calendar access is **off by default**. Turned on (**Settings › General › Use my
calendar**), it:

- names recordings after the event you are in and pulls in its invitees —
  including after the fact, if the calendar was not readable when the meeting
  was recorded;
- decides whether a call was scheduled, which is what lets it record by itself
  rather than ask;
- fills **Coming up** at the top of Home with today and tomorrow, each event a
  click from **Brief me** (Ask on what happened last time with those people,
  what is still open, and what you committed to) or **Record**;
- a minute before each meeting, posts a reminder whose **Join & Record** opens
  the call link (Teams, Zoom, Meet, Webex and others, found in the event's URL,
  location or notes) and starts recording. The call that then takes the
  microphone is adopted by that recording, so it stops when the call ends.

Declined events, and ones with no invitees and no join link — focus blocks,
lunch — are ignored. A summary style chosen for a calendar meeting is remembered
for that series, so the weekly 1:1 is written as a 1:1 without picking it again.
**Settings › General › Calendar** lists every calendar with a switch, so only the
ones you choose count; one added later counts until you switch it off.

**Outlook.** Minutes reads the calendars macOS has. New Outlook keeps its own
copy private — no shared database, and its AppleScript sees an empty stub — so
add your Microsoft 365 account in **System Settings › Internet Accounts ›
Microsoft Exchange** with only Calendars switched on. It syncs into macOS by
itself and appears in Minutes within a minute, with no restart. Home says so,
with a button to that pane, when no Exchange account is present.

## Code signing

macOS records a permission decision against an app's **code identity**, so this
matters more than it looks. An ad-hoc signature is derived from the binary's
hash: it changes on every rebuild, TCC treats each build as a different app, and
the microphone and Audio Recording grants have to be given again every time.

`build-app.sh` picks an identity automatically, in this order:

1. `$MINUTES_SIGN_IDENTITY`, to pin a specific one
2. an Apple **Developer ID Application** certificate, if you have one
3. the self-signed identity from `./Scripts/create-signing-identity.sh`
4. ad-hoc, which works but forgets permissions on every rebuild

A Developer ID is the best of these. Its designated requirement — the string TCC
actually matches against — comes out as:

```
identifier "com.minutesapp.Minutes" and anchor apple generic
  and certificate 1[field.1.2.840.113635.100.6.2.6] exists
  and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
  and certificate leaf[subject.OU] = <team id>
```

There is no hash of the binary anywhere in it. It names the bundle identifier and
the team, which means permissions survive not just a rebuild but a certificate
renewal. Verified by rebuilding with a changed bundle: the code hash changed
completely, the designated requirement was byte-identical.

A self-signed certificate is tied to its own hash (`certificate leaf = H"..."`),
so it is stable across rebuilds but resets permissions once if you ever
regenerate it. Use it when there is no Developer ID available:

```bash
./Scripts/create-signing-identity.sh
```

That one is interactive by necessity — macOS wants your password to add trust
settings, and the keychain asks before letting `codesign` use a new key. Choose
"Always Allow" for the keychain prompt.

The build prints the identity, how long the certificate has left, and the
resulting designated requirement, and warns under 45 days remaining. Signing
fails outright once a certificate expires.

Note that `spctl` reports the app as an *unnotarized* Developer ID build. That is
expected: Gatekeeper only enforces notarization on apps carrying a quarantine
flag from a download, and a locally built app has none. Notarizing would mean
signing with `--timestamp` and submitting to Apple's notary service, which is
only worth doing if you distribute it to another machine.

## Using it

### When a call starts

Core Audio reports, per process, whether that process is capturing audio input.
Zoom idling in the dock reads false; Zoom in a call reads true. When a known
conferencing app holds the microphone for two consecutive polls (about six
seconds), that is a call, and **Settings › General › When a call starts**
decides what happens:

- **Record calendar meetings, offer the rest** (the default). A call during a
  meeting on your calendar records by itself, with a notice carrying **Stop**
  and **Discard**. A call that isn't on your calendar is offered with **Record**
  and **Ignore** — impromptu calls include the ones nobody wants recorded. With
  no calendar access, every call is offered.
- **Ask first.** Every call is offered.

Let people know you are recording; some places require everyone's consent.

Zoom, Teams, Meet, Webex, Slack, FaceTime, Discord, Chime, GoTo, RingCentral,
BlueJeans, Jitsi and Dialpad are recognised. Matching is by case-insensitive
bundle-identifier prefix, which catches the helper processes that actually hold
the microphone — current Teams uses `com.microsoft.teams2.modulehost`, not
`com.microsoft.teams2`.

A browser holds the microphone for plenty of non-meeting reasons, so on its own
it is only ever offered. But with the Accessibility permission (the same one
that names Teams calls), the front tab's title says which meeting it is in:
"Meet - …" is Google Meet, "… | Microsoft Teams" is Teams on the web, "Zoom
Meeting" is Zoom. A recognised tab is offered — or recorded, if scheduled — as
that call, and a Meet tab with a real name names the recording. A call in a
background tab falls back to the generic question.

An automatic recording whose call ends within 45 seconds, with nothing typed
into it, was a microphone blip — a device test, a declined ring — and is deleted
rather than left in the library.

Each app is tracked separately, so back-to-back calls get their own
recordings: a Teams call joined before Zoom has fully dropped is offered as
soon as the Zoom recording ends, rather than merging into it.

Recording stops by itself when the call's app releases the microphone for
about fifteen seconds (long enough that switching headsets does not split a
meeting), after fifteen minutes of silence, or when the Mac goes to sleep.
Pressing **New note** (or ⇧⌘R) records straight away; a call that starts within
two minutes, or one already under way, is adopted by that recording, named from
its window, and ends it.

Notices arrive as notification banners. If notification permission is denied
the banner never appears, so it falls back to a small floating window near the
menu bar — the notice is not optional just because notifications are. Neither
takes keyboard focus.

If a call is not detected, `--watch-detection` (below) prints every process that
takes or releases the microphone while you join, recognised or not.

### The meeting page

Each meeting is a single page. Type your own notes on it while the meeting
runs; when the meeting ends and the notes are written, the page becomes them,
with a **Notes / My notes** switch to see exactly what you typed. Your notes are
not replaced by the summary — they steer it. The prompt treats them as
authoritative on priorities and on the spelling of names and product terms, and
expands them using the transcript as evidence.

Under the title, chips show when, how long, who was invited, and the folder —
**Add to folder** files it. Along the bottom, the waveform button opens the
transcript beside the page, and the **Ask** bar asks about this meeting. While
recording, the bar also carries the clock, level meters and Stop.

A meeting's name comes from, in order: the calendar event; the call's window
title, tidied ("Call with Priya Raman", not "Teams call with Priya Raman |
Example Corp | you@example.com"); or, for an impromptu call left as "Meeting at
9:32 AM", a few words Claude writes from the notes in the same run that writes
them. A name you type is never replaced.

Six summary styles ship with it: general, MSP client call, discovery/sales,
technical troubleshooting, one-on-one, and standup. Pick one per meeting from
the ⋯ menu, or set a default in Settings.

Controls are icons rather than labels, so hover for a tooltip if one is not
obvious. Words are kept where an icon would be a guess: dropdown menu items,
dialog buttons, and anything destructive.

### The menu bar

The menu bar icon is the app's mark in three states: idle; recording, with the
tallest bar red and pulsing once a second; and writing notes, with the bars
dimmed. **Settings › Appearance › Menu bar** adds the recording clock, or the
next meeting when one starts within fifteen minutes. Clicking it opens Coming up,
recent meetings, and record and stop.

## Asking about past meetings

**Ask** is in the sidebar, and the **Ask anything** bar at the bottom of Home goes
to it. It answers questions across the whole
library — "what did I commit to last week?", "when did I last speak to them, and
about what?" — through the same `claude` CLI, streaming the reply as it arrives.
The conversation is kept, so follow-ups work.

The interesting problem is what Claude gets to see. A library cannot fit in one
prompt, but naive retrieval is worse than it looks: send only the top few matches
and it cannot answer "when did I last…" or "how many times…", because it has no
idea what else exists. So the context is layered:

1. **Every** meeting, always, as a compact index — date, title, duration,
   attendees, one line of summary. Cheap, and it makes the shape of the library
   known.
2. Full notes for the most relevant meetings, added in relevance order until a
   budget of 80,000 characters (about 20,000 tokens) runs out.
3. Full transcripts after that, if room remains — notes are the better text per
   character, so they get the budget first.
4. An explicit statement when something did not fit, so a partial answer can be
   reported as partial.

Relevance is weighted keyword overlap — no embeddings, nothing to index or keep
in sync — weighted by how deliberate each field is: a term in a title or in your
own notes counts for far more than one buried in a transcript. Recent questions
feed into the terms too, so "and what did they decide?" still finds the right
meeting.

Each answer shows which meetings it drew on. That line is the difference between
a grounded answer and a plausible one.

Every meeting also has its own **Ask**, from the bar at the bottom of its page,
answered in a panel beside it. That conversation is about the one
meeting — its notes and transcript go in first, in full — with the rest of the
library still in reach behind it, and it is saved in the meeting's folder.

**Recipes** (the ✨ menu, or the suggestions in an empty chat) are saved
prompts: draft a follow-up email, list action items by owner, catch up someone
who missed it, prepare for next time, coach me; and across the library, what I
committed to this week and what looks unresolved. They live in
`shared/prompts/recipes.json`, so both platforms offer the same ones. Answers
have a copy button, since the point of a follow-up email is to paste it.

You can also ask from the command line:

```bash
/Applications/Minutes.app/Contents/MacOS/Minutes --ask "what did I agree to?"
```

## Asking Claude about your meetings

`Minutes --mcp` is a local [MCP](https://modelcontextprotocol.io) server over
stdio. **Settings › Claude** connects it to Claude Desktop and Claude Code with one
button each, shows whether each is connected (or still pointing at an old copy
of the app), and tests the server without using any of your Claude plan.
Claude Desktop needs a restart to see a change. Or run it yourself:

```bash
claude mcp add --scope user minutes -- \
  /Applications/Minutes.app/Contents/MacOS/Minutes --mcp
```

Tools:

- `search_meetings` returns the passages that match, from transcripts, your
  notes and the written notes, each with its meeting, date, time in the
  recording and speaker, plus the lines either side. Filler words in a
  question are ignored. This answers most questions in one call without pulling
  whole transcripts into Claude's context.
- `list_meetings` browses by date, person or topic; `get_meeting` returns one
  meeting's notes and transcript.

Every tool is read-only: the server never writes to the library. It tells Claude
whose library it is (your name from Settings) and that speaker labels come from
loudness, so "what did I promise Marcus?" resolves properly. It reads the same
files the app does and opens no network connections; each Claude app starts it
on this Mac when it needs it.

## What reaches Claude

Recording, transcription, speaker labels, search and the library itself stay on
the Mac. Two things go to Claude, through your own `claude` sign-in:

- **Writing a meeting's notes** — once per meeting, automatically when it ends
  (switch that off in **Settings › Notes**). The prompt carries your notes, the
  transcript, the invitees and your name. For a meeting with only a placeholder
  name, the same run also writes its title.
- **Ask** — only when you ask, each question with the library context above.

The connection test is on request too.

Each run replaces Claude Code's own system prompt (its instructions for editing
code and using tools) with ours and turns off skills: measured on CLI 2.1.329, a
one-line question went from 4,258 input tokens to 1,037. Rewriting notes from the
✦ button asks first, because a long transcript sent again for a near-identical
result is usage for nothing. Notes are written with **Sonnet** by default;
**Settings › Notes › Model** can make them cheaper (Haiku) or richer (Opus).

## On an 8 GB Mac

The floor is an M1 with 8 GB, and several things exist for it:

- **The Whisper model.** Full-precision `large-v3-turbo` peaks at 2.2 GB while
  transcribing; the 5-bit copy at 1.1 GB, as fast, with a transcript within the
  variation of one decoding setting. New installs on 8 GB or less download the
  5-bit one; elsewhere the full one. Both run without carrying text between
  windows (`-mc 0`), which stops Whisper looping on one phrase or skipping speech
  it took for a repeat.
- **Transcription stays out of the way.** Whisper runs at utility priority with
  four threads — measured as fast as eight at default priority, since the GPU
  does the work — so it doesn't compete with the next call.
- **The library loads without transcripts.** Launch reads a light index in
  parallel; transcripts load when a meeting is opened, searched or summarized.
- **Redraws.** The recording clock, the level meters and the live transcript
  publish separately, so what shows the clock does not redraw at the meter rate.
- **A full disk** is said once, instead of a recording silently saving nothing,
  and recording warns at the start with under 500 MB free.

## Running from the menu bar only

**Settings › Appearance › Dock** turns off the Dock icon, leaving the app in the
menu bar. The window still opens from the menu bar icon; it just no longer
appears by itself on launch.

This is done by switching the activation policy at runtime rather than by setting
`LSUIElement` in Info.plist, and the ordering is deliberate. An `LSUIElement` app
never builds a main menu, and the standard editing shortcuts — ⌘C, ⌘V, ⌘Z in the
notes editor — are key equivalents on that menu. Launching as a regular app and
*then* dropping to accessory keeps the menu installed, so text editing keeps
working with no Dock icon and no visible menu bar. The cost is a brief Dock icon
at launch before the policy applies, which is a better trade than losing paste in
a note-taking app.

## Where things are kept

```
~/Library/Application Support/Minutes/
├── Meetings/<uuid>/
│   ├── meeting.json     metadata, your notes, transcript segments
│   ├── audio.wav        16 kHz mono mixdown
│   ├── energy.bin       per-chunk loudness, used for speaker labels
│   ├── summary.md
│   └── chat.json        this meeting's Ask conversation, if any
├── Trash/               deleted meetings, for 30 days
├── Models/              Whisper models
├── Cache/SearchText/    lowercased transcripts for search; rebuilt if deleted
├── chat.json            the Ask conversation
└── Logs/minutes.log
```

Plain files, one directory per meeting. Nothing to migrate, and deleting a folder
deletes the meeting.

Deleting a meeting (right-click it on Home › Delete) moves it to `Trash/`
instead, under **Recently Deleted** — the trash icon at the bottom of the
sidebar — and restorable for 30 days. **Settings › Transcription ›
Delete audio after** removes old recordings' audio while keeping the transcript,
notes and summary. Discarding an automatic recording deletes it outright.

Meetings can be filed in folders (**Add to folder** on the page, or right-click ›
Move to Folder), which then appear in the sidebar. Search (⌘F) has a filter for
a person or a company — companies come from invitees' email domains, so they
need the calendar turned on.

## Diagnostics

```bash
/Applications/Minutes.app/Contents/MacOS/Minutes --doctor
/Applications/Minutes.app/Contents/MacOS/Minutes --test-capture 5
/Applications/Minutes.app/Contents/MacOS/Minutes --selftest some.wav
```

```bash
/Applications/Minutes.app/Contents/MacOS/Minutes --test-detection
/Applications/Minutes.app/Contents/MacOS/Minutes --watch-detection 300
/Applications/Minutes.app/Contents/MacOS/Minutes --test-prompt
```

`--doctor` checks the tools, the model, the Claude sign-in, and permission
state. `--test-detection` explains what meeting detection can currently see;
`--watch-detection` prints, live, every process that takes or releases the
microphone while you join a call — recognised or not, which is how to find what
a new app is called — and, for a browser, which meeting its tab is in when
Terminal has the Accessibility permission. And `--test-prompt` puts the
detection prompt on screen for a few seconds and reports the size it settled on.

`--test-prompt` cannot check *placement*: it runs in its own process, where the
menu bar item — which belongs to the running app — does not exist, so it falls
back to the top-right corner and says so. The running app logs the answer at
launch instead:

```bash
grep "Menu bar anchor" ~/Library/Application\ Support/Minutes/Logs/minutes.log
```

That reports the icon's position and display, or warns that no anchor was found.
The same log records what the calendar returned whenever it changes ("Calendar:
6 meetings ahead from 5 calendars, Exchange account present"). `--test-capture` records briefly and
reports what each source actually delivered, including peak levels — this is the
fastest way to tell a permissions problem from a device problem. `--selftest`
runs an existing WAV through Whisper and Claude.
