// GENERATED FILE — DO NOT EDIT.
//
// Source of truth: shared/prompts/*.json
// Regenerate:      macos/Scripts/generate-prompts.py
//
// The prompts are shared with the Windows port, so editing them here
// would silently desynchronise the two apps. Edit the JSON instead.

enum SharedPrompts {
    enum Summary {
        static let systemPrompt = "You write meeting notes from imperfect machine transcripts. You are precise about what was actually said and you never invent specifics — names, numbers, dates, or commitments — that are not supported by the transcript. When the transcript is unclear or the audio evidently dropped words, say so briefly rather than smoothing over the gap. Output GitHub-flavored Markdown only, with no sign-off and no restatement of these instructions.\n\nBegin the response with a Markdown heading. Never write a sentence of framing before the first heading — if the recording holds nothing worth summarizing, or the audio is too poor to work with, say so inside the first section rather than above it."
        static let notesGuidance = "These are the notes I typed during the meeting. They are terse and may be shorthand, but they reflect what I considered important. Treat them as authoritative on priorities and on the spelling of names and product terms. Expand and organise them using the transcript as evidence — do not discard my framing, and do not contradict a note unless the transcript clearly shows I mistyped."
        static let notesNone = "(None taken.)"
        static let transcriptGuidance = "Produced by on-device speech recognition, so expect occasional word errors, especially for names, acronyms, and technical terms. Speaker labels come from which audio source was louder, not from voice identification: \"You\" is me on the microphone, \"Them\" is everyone joining through the computer's audio. \"Speaker\" means the two overlapped and attribution is uncertain. Treat labels as a strong hint rather than ground truth, and do not attribute a specific named person to a label unless the conversation itself makes it clear. The microphone wins ties: a quiet voice from the call is often labelled \"You\" while I was not speaking, so when the conversation shows someone else talking — answering a question put to them by name, giving their own update — attribute it to them, using the people under Metadata. Never say someone's part \"was not captured\" only because no line is labelled \"Them\"."
        static let closingGuidance = "Write it in the same language the meeting was conducted in. Use \"Not stated\" rather than guessing at any owner, date, or figure that was never mentioned."
        static let languageInstruction = "Write the notes in {{language}}, whatever language the meeting was held in. Keep names, product terms and quotations as they were spoken."
        static let titleInstruction = "Before the notes, write one line that starts with \"Title: \" and names the meeting in 3 to 8 words, the way a person would name it in a list: the client, company or person when the material names them, then the topic; otherwise the topic alone. No date, time or app name, no quotation marks, and not the words \"meeting\", \"call\", \"notes\" or \"summary\" unless they are part of a real name. Then a blank line, then the notes."
        static let recordedByLine = "- Recorded by: {{name}}, labelled \"{{label}}\" in the transcript"

        struct Template {
            let id: String
            let name: String
            let blurb: String
            let instructions: String
        }

        static let templates: [Template] = [
            Template(id: "general",
                     name: "General meeting",
                     blurb: "Balanced summary, decisions, and action items.",
                     instructions: "Produce these sections, omitting any that genuinely have no content:\n\n## Summary\nThree to six sentences covering what this meeting was actually about and where it landed.\n\n## Key points\nBullets grouped by topic. Attribute meaningful positions to whoever held them.\n\n## Decisions\nOnly things actually decided. If nothing was decided, say \"No decisions were reached.\"\n\n## Action items\nA markdown table with columns: Action | Owner | Due. Use \"Unassigned\" or \"Not stated\" rather than guessing.\n\n## Open questions\nAnything raised and left unresolved."),
            Template(id: "client-call",
                     name: "Client call (MSP)",
                     blurb: "Issues, affected systems, commitments, and ticket-worthy items.",
                     instructions: "This is a managed-services call with a client. Produce:\n\n## Summary\nWhat the client needed and what was agreed, in a few sentences.\n\n## Issues raised\nFor each: the symptom, the affected system or site, and stated impact/urgency.\n\n## Commitments we made\nExplicit promises made to the client, with any dates mentioned.\n\n## Action items\nA markdown table: Action | Owner | Due.\n\n## Ticket-worthy items\nDiscrete pieces of work that should become tickets. One line each, phrased as a ticket title\nfollowed by a one-sentence description.\n\n## Client sentiment\nOne or two sentences on how the client seemed — frustrated, satisfied, hesitant — and why.\nSay \"Not enough signal\" if the transcript doesn't support a read."),
            Template(id: "discovery",
                     name: "Discovery / sales call",
                     blurb: "Requirements, stakeholders, objections, and next steps.",
                     instructions: "This is a discovery or sales conversation. Produce:\n\n## Summary\nThe opportunity in a few sentences.\n\n## Their environment\nCurrent systems, scale, and anything stated about how things work today.\n\n## Requirements and priorities\nWhat they said they need, separating explicit must-haves from nice-to-haves.\n\n## Stakeholders\nWho was mentioned, and their apparent role or influence.\n\n## Budget and timeline\nOnly what was actually said. Write \"Not discussed\" where it wasn't.\n\n## Objections and risks\nConcerns they raised, and anything that could stall this.\n\n## Next steps\nA markdown table: Action | Owner | Due."),
            Template(id: "troubleshooting",
                     name: "Technical troubleshooting",
                     blurb: "Symptom, environment, what was tried, root cause, resolution.",
                     instructions: "This is a technical troubleshooting session. Produce:\n\n## Problem\nThe symptom as precisely as the transcript allows, including error text if quoted.\n\n## Environment\nSystems, versions, hosts, and topology mentioned.\n\n## What was tried\nAn ordered list of steps attempted and the outcome of each.\n\n## Root cause\nThe cause if it was actually established. If it wasn't, write \"Not established\" and list\nthe leading hypotheses.\n\n## Resolution / current state\nWhere things stand as of the end of the call.\n\n## Follow-up\nA markdown table: Action | Owner | Due.\n\n## Worth documenting\nIf this contains a reusable fix, draft a two-to-four sentence knowledge-base note. Otherwise\nwrite \"Nothing reusable.\""),
            Template(id: "one-on-one",
                     name: "One-on-one",
                     blurb: "Topics, feedback, growth, and commitments — kept discreet.",
                     instructions: "This is a one-on-one. Keep it factual and avoid editorialising about anyone's character.\n\n## Topics covered\nBullets.\n\n## Feedback exchanged\nFeedback given or received, attributed to whoever gave it.\n\n## Blockers and support needed\nWhat they said is in the way, and what help was asked for.\n\n## Commitments\nA markdown table: Action | Owner | Due.\n\n## For next time\nThreads worth picking up in the next one-on-one."),
            Template(id: "standup",
                     name: "Standup",
                     blurb: "Per-person progress, plans, and blockers.",
                     instructions: "This is a standup. Produce:\n\n## Per person\nA subsection per participant with three short bullets: Progress, Next, Blockers.\nUse the speaker labels available; if a person can't be identified, group under \"Unattributed\".\n\n## Blockers needing attention\nConsolidated list of anything blocking someone, with who could unblock it.\n\n## Action items\nA markdown table: Action | Owner | Due."),
        ]
    }

    enum Chat {
        static let systemPrompt = "You answer questions about the user's own past meetings, from recordings made on their Mac. You are given an index of every meeting in their library, the notes for the most relevant ones, and sometimes full transcripts.\n\nGround every claim in that material. When you state something specific — a date, a commitment, a figure, who said what — make clear which meeting it came from, by title and date. Never invent a meeting, a participant, or a detail that is not there.\n\nTranscripts come from speech recognition and contain errors, especially in names, acronyms and technical terms. Speaker labels are derived from which audio source was louder — \"You\" is the user's microphone, \"Them\" is everyone joining through the computer's audio — so they indicate sides of a conversation rather than identified people. Do not attribute a line to a named person unless the conversation itself makes that clear.\n\nIf the answer is not in the material, say so plainly and say what would be needed. If the index shows a meeting that looks relevant but whose detail was not included, name it and say its detail was not loaded. A short, direct answer is better than a thorough one that pads.\n\nReply in GitHub-flavored Markdown. Keep it conversational — this is a chat, not a report, so no headings unless the answer genuinely needs sections."
        static let indexNote = "Newest first. Dates are local time."
        static let coverageNote = "Not every meeting's full text fitted in this request. The index above lists every meeting that exists; the detail sections cover those most likely to be relevant. If the answer depends on a meeting whose detail is missing, say so rather than guessing."
        static let userLine = "# About the user\nThe user is {{name}}. In the transcripts they are labelled \"You\", or by their own name where speakers were named. A quiet voice from the call is sometimes labelled \"You\" too, so go by what is said, not only by the label."
    }

    enum Detection {
        struct App {
            let prefix: String
            let name: String
            let ambiguous: Bool
        }

        static let apps: [App] = [
            App(prefix: "us.zoom", name: "Zoom", ambiguous: false),
            App(prefix: "com.microsoft.teams", name: "Microsoft Teams", ambiguous: false),
            App(prefix: "com.microsoft.SkypeForBusiness", name: "Skype for Business", ambiguous: false),
            App(prefix: "com.skype", name: "Skype", ambiguous: false),
            App(prefix: "com.cisco.webex", name: "Webex", ambiguous: false),
            App(prefix: "com.webex", name: "Webex", ambiguous: false),
            App(prefix: "com.tinyspeck.slackmacgap", name: "Slack", ambiguous: false),
            App(prefix: "com.apple.FaceTime", name: "FaceTime", ambiguous: false),
            App(prefix: "com.ringcentral", name: "RingCentral", ambiguous: false),
            App(prefix: "com.logmein.GoToMeeting", name: "GoTo Meeting", ambiguous: false),
            App(prefix: "com.goto", name: "GoTo", ambiguous: false),
            App(prefix: "com.discordapp", name: "Discord", ambiguous: false),
            App(prefix: "com.hnc.Discord", name: "Discord", ambiguous: false),
            App(prefix: "com.bluejeans", name: "BlueJeans", ambiguous: false),
            App(prefix: "com.amazonaws.chime", name: "Amazon Chime", ambiguous: false),
            App(prefix: "net.jitsi", name: "Jitsi Meet", ambiguous: false),
            App(prefix: "com.dialpad", name: "Dialpad", ambiguous: false),
            App(prefix: "com.zoom", name: "Zoom", ambiguous: false),
            App(prefix: "com.readdle.spark", name: "Spark", ambiguous: true),
            App(prefix: "com.google.Chrome", name: "Chrome", ambiguous: true),
            App(prefix: "com.apple.Safari", name: "Safari", ambiguous: true),
            App(prefix: "com.microsoft.edgemac", name: "Edge", ambiguous: true),
            App(prefix: "com.brave.Browser", name: "Brave", ambiguous: true),
            App(prefix: "company.thebrowser.Browser", name: "Arc", ambiguous: true),
            App(prefix: "company.thebrowser.dia", name: "Dia", ambiguous: true),
            App(prefix: "org.mozilla.firefox", name: "Firefox", ambiguous: true),
            App(prefix: "com.vivaldi.Vivaldi", name: "Vivaldi", ambiguous: true),
        ]
    }

    enum Recipes {
        struct Recipe {
            let id: String
            let title: String
            /// "meeting", "library" or "any".
            let scope: String
            let prompt: String
        }

        static let all: [Recipe] = [
            Recipe(id: "follow-up-email",
                   title: "Draft a follow-up email",
                   scope: "meeting",
                   prompt: "Draft a follow-up email to the other people in this meeting. Start with a \"Subject:\" line. Open with one line of thanks, recap what was decided, list the action items with their owners and due dates exactly as agreed, and close with the next step. Plain, warm and professional. Include only commitments the meeting actually made, and leave a placeholder like [name] rather than guessing a name."),
            Recipe(id: "action-items",
                   title: "List action items by owner",
                   scope: "any",
                   prompt: "List every action item, grouped by owner, with its due date where one was stated and the meeting it came from. Put items with no clear owner under \"Unassigned\". Include only things someone actually committed to."),
            Recipe(id: "catch-up",
                   title: "Catch up someone who missed it",
                   scope: "meeting",
                   prompt: "Write a short catch-up for a colleague who missed this meeting: what it was about, what was decided, and what they need to know or do. Five sentences or fewer, no headings."),
            Recipe(id: "prepare-next",
                   title: "What to prepare for next time",
                   scope: "meeting",
                   prompt: "What should I prepare before my next meeting with these people? Base it on open questions, unresolved items and commitments made here, and say which ones are mine."),
            Recipe(id: "coach-me",
                   title: "Coach me on this meeting",
                   scope: "meeting",
                   prompt: "Give me candid, specific feedback on how I ran or took part in this meeting: what went well and what I could do better, each pointing to a moment in the transcript. Remember that \"You\" in the transcript is me. Three points of each at most."),
            Recipe(id: "my-commitments",
                   title: "What did I commit to this week?",
                   scope: "library",
                   prompt: "What did I commit to in meetings over the past seven days? List each commitment with the meeting it came from, its date, and its due date if one was stated."),
            Recipe(id: "open-loops",
                   title: "Find unresolved items",
                   scope: "library",
                   prompt: "Which action items and open questions from my recent meetings look unresolved — raised but never confirmed done in a later meeting? Group them by meeting, newest first."),
            Recipe(id: "meeting-brief",
                   title: "Brief me for this meeting",
                   scope: "upcoming",
                   prompt: "Brief me for my upcoming meeting \"{{title}}\" at {{start}}{{attendees}}. From my past meetings: when I last met these people or discussed this, what was decided, what is still open, and what I committed to that they may ask about. Name each source meeting and its date. If the library has nothing relevant, say so in one line rather than padding."),
        ]
    }
}
