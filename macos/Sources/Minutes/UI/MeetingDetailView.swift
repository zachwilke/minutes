import SwiftUI
import AppKit

/// One meeting, as a page.
///
/// The previous build put your notes and the written notes side by side, each
/// in its own card, which made the screen a comparison of two documents. It is
/// not a comparison: during the call there is one thing to look at — what you
/// are typing — and afterwards there is one thing to look at, which is the
/// notes that grew out of it. So this is a single column that *changes* when
/// the meeting ends, with a switch back to your raw notes for the times you
/// want to see what you actually wrote.
///
/// The transcript and Ask are not peers of that column. They are references you
/// consult while reading it, so they open as a panel beside the page rather
/// than replacing it.
struct MeetingDetailView: View {
    let meetingID: UUID

    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var meetingChats: MeetingChats
    @ObservedObject private var settings = AppSettings.shared
    /// Observed so the style menu lists styles added in Settings.
    @ObservedObject private var customTemplates = CustomTemplates.shared

    @State private var notes = ""
    @State private var title = ""
    /// The values as last loaded or saved. Only fields the user has changed since
    /// are written back, so typing a note no longer rolls back a title the
    /// pipeline set meanwhile — the calendar name, applied after load.
    @State private var savedNotes = ""
    @State private var savedTitle = ""
    @State private var saveTask: Task<Void, Never>?
    /// Which text the page is showing.
    @State private var mode: Mode = .written
    /// The reference panel, if one is open.
    @State private var panel: Panel?
    /// Hand-editing the generated notes.
    @State private var editingSummary = false
    @State private var summaryDraft = ""
    @State private var summarySaveTask: Task<Void, Never>?
    /// Regenerating would replace hand edits; this holds the action until the
    /// user confirms.
    @State private var pendingOverwrite: (() -> Void)?
    @State private var namingSpeakers = false
    @State private var newFolderFor: Meeting?
    /// What was just copied, for the moment the button shows a checkmark.
    @State private var copied: CopyTarget?

    enum CopyTarget { case notes, transcript }
    @State private var newFolderName = ""

    /// What the document column is showing.
    enum Mode: String, CaseIterable, Identifiable {
        /// The notes Claude wrote. The default once they exist.
        case written = "Notes"
        /// What you typed yourself, untouched.
        case mine = "My notes"
        var id: String { rawValue }
    }

    /// The reference panel beside the page.
    enum Panel: String, Identifiable {
        case transcript = "Transcript"
        case ask = "Ask"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .transcript: return "text.alignleft"
            case .ask: return "bubble.left.and.text.bubble.right"
            }
        }
    }

    /// With its transcript: this view shows it and copies it. The store keeps
    /// only the last few opened in memory.
    private var meeting: Meeting? { store.fullMeeting(id: meetingID) }
    private var isActive: Bool { coordinator.activeMeetingID == meetingID }
    private var hasWrittenNotes: Bool { meeting?.summaryMarkdown?.isEmpty == false }

    var body: some View {
        Group {
            if let meeting {
                HStack(spacing: 0) {
                    document(meeting)
                        .overlay(alignment: .bottom) { bottomBar(meeting) }
                    if let panel {
                        SidePanel(panel: panel,
                                  meeting: meeting,
                                  isActive: isActive,
                                  transcriptCopied: copied == .transcript,
                                  onCopyTranscript: { copyTranscript(meeting) },
                                  onNameSpeakers: { namingSpeakers = true },
                                  onClose: { withAnimation(.easeOut(duration: 0.16)) { self.panel = nil } })
                            .frame(width: Layout.panelWidth)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                // Actions live in the titlebar row, beside the traffic lights'
                // row, rather than in a second bar of their own under it.
                .toolbar { pageToolbar(meeting) }
                .onAppear { load(meeting) }
                // The view is reused across meetings, so the previous meeting's
                // pending save is written before its text is replaced. Without
                // this, switching within the debounce dropped the last keystrokes.
                .onChange(of: meetingID) { previous, _ in
                    flushPendingSave(for: previous)
                    finishSummaryEditing(for: previous)
                    if let meeting = self.meeting { load(meeting) }
                }
                .onChange(of: meeting.title) { _, stored in
                    // Adopt a title changed elsewhere unless the user is editing it.
                    if title == savedTitle { title = stored; savedTitle = stored }
                }
                // The moment the notes land, the page becomes them. This is the
                // whole point of the single column: you watch what you typed
                // turn into what you meant, in the place you were already
                // looking.
                .onChange(of: meeting.summaryMarkdown) { previous, current in
                    guard previous?.isEmpty != false, current?.isEmpty == false else { return }
                    withAnimation(.easeOut(duration: 0.25)) { mode = .written }
                }
                .onDisappear {
                    flushPendingSave(for: meetingID)
                    finishSummaryEditing(for: meetingID)
                }
            } else {
                Text("This meeting is no longer available.")
                    .font(Typeface.label)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog(overwriteIsEdited ? "Replace your edited notes?" : "Write these notes again?",
                            isPresented: Binding(get: { pendingOverwrite != nil },
                                                 set: { if !$0 { pendingOverwrite = nil } })) {
            Button("Rewrite Notes", role: overwriteIsEdited ? .destructive : nil) {
                pendingOverwrite?()
                pendingOverwrite = nil
            }
        } message: {
            Text(overwriteIsEdited
                 ? "You've edited these notes by hand. Writing them again with Claude replaces your edits."
                 : "Claude reads the whole transcript again, which counts against your Claude plan's usage. The new notes replace these.")
        }
        .sheet(isPresented: $namingSpeakers) {
            if let meeting {
                SpeakerNamesSheet(names: meeting.speakerNames) { names in
                    store.update(id: meetingID) { $0.speakerNames = names }
                    namingSpeakers = false
                } onCancel: { namingSpeakers = false }
            }
        }
        .alert("New Folder", isPresented: Binding(get: { newFolderFor != nil },
                                                  set: { if !$0 { newFolderFor = nil } })) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let meeting = newFolderFor, !name.isEmpty {
                    store.update(id: meeting.id) { $0.folder = name }
                }
                newFolderFor = nil
            }
            Button("Cancel", role: .cancel) { newFolderFor = nil }
        } message: {
            Text("The meeting is moved into it.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func pageToolbar(_ meeting: Meeting) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            actions(meeting)
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ViewBuilder
    private func statusChip(_ meeting: Meeting) -> some View {
        // Pipeline state is per meeting now, so the chip shows THIS meeting's
        // progress regardless of what else is recording or processing.
        if case .transcribing(let progress) = coordinator.processing[meetingID] {
            chip("Transcribing \(Int(progress * 100))%", tint: Palette.inkSecondary, spinner: true)
        } else if coordinator.processing[meetingID] == .summarizing {
            chip("Writing notes", tint: Palette.inkSecondary, spinner: true)
        } else if meeting.state == .failed {
            chip(meeting.failureReason ?? "Failed", tint: Palette.warning, spinner: false)
        }
    }

    private func chip(_ text: String, tint: Color, spinner: Bool) -> some View {
        HStack(spacing: 6) {
            if spinner { ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10) }
            Text(text).lineLimit(1)
        }
        .font(Typeface.meta)
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background { Capsule().fill(Palette.fill) }
    }

    private func actions(_ meeting: Meeting) -> some View {
        HStack(spacing: 2) {
            IconButton(symbol: "sparkles",
                       help: meeting.summaryMarkdown == nil
                           ? "Write notes with Claude as \(SummaryTemplate.named(meeting.templateID).name)"
                           : "Rewrite these notes as \(SummaryTemplate.named(meeting.templateID).name)",
                       emphasis: .plain,
                       size: 13) {
                confirmingOverwrite(meeting, evenIfUnedited: true) { Task { await coordinator.summarize(meetingID: meetingID) } }
            }
            .disabled(coordinator.processing[meetingID] != nil
                      || (isActive && coordinator.phase.isRecording)
                      || meeting.transcriptText.isEmpty)

            if hasWrittenNotes, mode == .written, coordinator.processing[meetingID] == nil {
                IconButton(symbol: editingSummary ? "checkmark" : "pencil",
                           help: editingSummary ? "Done editing" : "Edit these notes",
                           emphasis: .plain,
                           tint: editingSummary ? Palette.ink : nil,
                           size: 12) {
                    toggleSummaryEditing(meeting)
                }
            }

            IconButton(symbol: copied == .notes ? "checkmark" : "doc.on.doc",
                       help: mode == .mine ? "Copy your notes" : "Copy the notes",
                       emphasis: .plain, size: 12) { copyNotes(meeting) }
                .disabled(notesToCopy(meeting).isEmpty)

            IconButton(symbol: copied == .transcript ? "checkmark" : "text.quote",
                       help: "Copy the transcript", emphasis: .plain, size: 12) { copyTranscript(meeting) }
                .disabled(meeting.transcriptText.isEmpty)

            Menu {
                Picker("Summary style", selection: Binding(
                    get: { meeting.templateID },
                    set: { newValue in
                        guard let updated = store.update(id: meetingID, { $0.templateID = newValue }) else { return }
                        if let series = updated.calendarEventTitle, !series.isEmpty {
                            AppSettings.shared.setTemplate(newValue, forSeries: series)
                        }
                    })) {
                        ForEach(SummaryTemplate.all) { template in
                            Text(template.name).tag(template.id)
                        }
                    }

                Divider()

                Button("Re-transcribe and rewrite") {
                    confirmingOverwrite(meeting) { Task { await coordinator.process(meetingID: meetingID) } }
                }
                .disabled(coordinator.processing[meetingID] != nil
                          || !FileManager.default.fileExists(atPath: meeting.mixedAudioFile.path))

                Divider()

                Button("Export notes as Markdown…") { export(meeting) }
                    .disabled(meeting.summaryMarkdown == nil)

                Divider()

                Button("Name speakers…") { namingSpeakers = true }
                    .disabled(meeting.segments.isEmpty)

                Button("Play recording") {
                    NSWorkspace.shared.open(meeting.mixedAudioFile)
                }
                .disabled(!FileManager.default.fileExists(atPath: meeting.mixedAudioFile.path))

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([meeting.directory])
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect(cornerRadius: Radius.control, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for this meeting")
        }
    }

    // MARK: - The page

    private func document(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Untitled meeting", text: $title)
                    .textFieldStyle(.plain)
                    .font(Typeface.documentTitle)
                    .foregroundStyle(Palette.ink)
                    .onChange(of: title) { _, _ in scheduleSave() }

                chipsRow(meeting)
                    .padding(.top, 12)

                if mode == .written, meeting.summaryIsStale, hasWrittenNotes {
                    staleNotice(meeting).padding(.top, 18)
                }

                body(meeting)
                    .padding(.top, 22)
            }
            .frame(maxWidth: Layout.documentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Layout.documentGutter)
            .padding(.top, 30)
            // Room to scroll the last line clear of the Ask bar.
            .padding(.bottom, 110)
        }
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity)
    }

    /// What, when, who and where it is filed, as small chips under the title.
    /// The folder chip is a menu: filing a meeting happens here, on the
    /// meeting, the way Granola's "Add to" does.
    private func chipsRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 6) {
            MetaChip(symbol: "calendar",
                     text: "\(Formats.dayAndTime(meeting.startedAt)) · \(meeting.durationLabel)")
            if !meeting.attendees.isEmpty {
                MetaChip(symbol: "person.2",
                         text: "\(meeting.attendees.count) \(meeting.attendees.count == 1 ? "person" : "people")")
                    .help(meeting.attendees.joined(separator: "\n"))
            } else if let app = meeting.detectedAppName {
                MetaChip(symbol: "video", text: app)
            }
            Menu {
                FolderMenuItems(meeting: meeting) {
                    newFolderName = ""
                    newFolderFor = meeting
                }
            } label: {
                MetaChip(symbol: "folder", text: meeting.folder ?? "Add to folder",
                         muted: meeting.folder == nil)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            statusChip(meeting)
            Spacer(minLength: 8)
            if hasWrittenNotes || !notes.isEmpty {
                ModeSwitch(mode: $mode, hasWrittenNotes: hasWrittenNotes)
            }
        }
    }

    // MARK: - Bottom bar

    /// Ask about this meeting, and the transcript — the two things consulted
    /// while reading — in one bar along the bottom of the page. While
    /// recording it also carries the clock, levels and stop.
    private func bottomBar(_ meeting: Meeting) -> some View {
        AskBar(placeholder: "Ask about this meeting",
               suggestion: SharedPrompts.Recipes.named("follow-up-email"),
               showsField: panel != .ask) {
            HStack(spacing: 4) {
                if isActive, coordinator.phase.isRecording {
                    RecordingSegment(activity: coordinator.activity) {
                        Task { await coordinator.stopRecording() }
                    }
                }
                IconButton(symbol: "waveform",
                           help: panel == .transcript ? "Hide the transcript" : "Show the transcript",
                           emphasis: panel == .transcript ? .bordered : .plain,
                           tint: panel == .transcript ? Palette.ink : nil,
                           size: 13) {
                    withAnimation(.easeOut(duration: 0.16)) {
                        panel = panel == .transcript ? nil : .transcript
                    }
                }
            }
        } onAsk: { question in
            withAnimation(.easeOut(duration: 0.16)) { panel = .ask }
            meetingChats.controller(for: meetingID).send(question)
        }
        .frame(maxWidth: Layout.documentWidth + 40)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func body(_ meeting: Meeting) -> some View {
        switch mode {
        case .mine: myNotesEditor
        case .written: writtenNotes(meeting)
        }
    }

    /// What you type during the call. No card, no header, no label — on the
    /// page it is simply the text, which is what makes typing into it feel like
    /// writing rather than filling in a field.
    private var myNotesEditor: some View {
        TextEditor(text: $notes)
            .font(Typeface.documentBody)
            .foregroundStyle(Palette.ink)
            .lineSpacing(Typeface.documentLineSpacing)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(minHeight: 320, alignment: .topLeading)
            // TextEditor insets its text by a few points that no padding can
            // reach; pulling back by the same amount puts the first character
            // on the title's left edge.
            .padding(.leading, -5)
            .onChange(of: notes) { _, _ in scheduleSave() }
            .overlay(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Jot down what matters as the meeting goes.\nClaude expands these using the transcript.")
                        .font(Typeface.documentBody)
                        .lineSpacing(Typeface.documentLineSpacing)
                        .foregroundStyle(Palette.inkTertiary)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func writtenNotes(_ meeting: Meeting) -> some View {
        if editingSummary {
            // Plain Markdown, edited in place; rendered again when done.
            TextEditor(text: $summaryDraft)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(minHeight: 420, alignment: .topLeading)
                .padding(.leading, -5)
                .onChange(of: summaryDraft) { _, _ in scheduleSummarySave() }
        } else if let summary = meeting.summaryMarkdown, !summary.isEmpty {
            MarkdownView(markdown: summary).equatable()
        } else if coordinator.processing[meetingID] == .summarizing {
            placeholder("Claude is writing your notes…", spinner: true)
        } else if case .transcribing = coordinator.processing[meetingID] {
            placeholder("Transcribing the recording…", spinner: true)
        } else if coordinator.phase.isRecording, isActive {
            placeholder("Notes are written when you stop recording.", spinner: false)
        } else if meeting.transcriptText.isEmpty {
            placeholder("Nothing was transcribed for this meeting.", spinner: false)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("No notes yet.")
                    .font(Typeface.documentBody)
                    .foregroundStyle(Palette.inkSecondary)
                PillButton(title: "Write notes", symbol: "sparkles", prominent: true) {
                    confirmingOverwrite(meeting) { Task { await coordinator.summarize(meetingID: meetingID) } }
                }
                .disabled(coordinator.processing[meetingID] != nil)
            }
            .padding(.top, 10)
        }
    }

    /// Shown when the summary style was changed after the notes were written, so
    /// the picker and the content on screen disagree.
    private func staleNotice(_ meeting: Meeting) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Palette.warning)
            Text("These notes were written as \(SummaryTemplate.named(meeting.summaryTemplateID ?? "").name). "
                 + "Rewrite to apply \(SummaryTemplate.named(meeting.templateID).name).")
                .font(Typeface.label)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            PillButton(title: "Rewrite", symbol: "sparkles") {
                confirmingOverwrite(meeting) { Task { await coordinator.summarize(meetingID: meetingID) } }
            }
            .disabled(coordinator.processing[meetingID] != nil)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Palette.warning.opacity(0.08))
        }
    }

    private func placeholder(_ text: String, spinner: Bool) -> some View {
        HStack(spacing: 9) {
            if spinner { ProgressView().controlSize(.small) }
            Text(text).font(Typeface.documentBody).foregroundStyle(Palette.inkTertiary)
        }
        .padding(.top, 6)
    }

    // MARK: - Copying

    /// What "Copy notes" copies: the page as shown — the written notes, or
    /// your own on the My notes side.
    private func notesToCopy(_ meeting: Meeting) -> String {
        let text = mode == .mine ? notes : (meeting.summaryMarkdown ?? "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Written notes go on the clipboard twice: formatted, so headings, bullets
    /// and tables survive a paste into Outlook or Teams, and as the Markdown,
    /// for anywhere that takes plain text.
    private func copyNotes(_ meeting: Meeting) {
        let text = notesToCopy(meeting)
        guard !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        if mode == .written {
            let rich = MarkdownText.attributed(text)
            if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
                board.setData(rtf, forType: .rtf)
            }
        }
        board.setString(text, forType: .string)
        flash(.notes)
    }

    private func copyTranscript(_ meeting: Meeting) {
        guard !meeting.transcriptText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.transcriptText, forType: .string)
        flash(.transcript)
    }

    private func flash(_ target: CopyTarget) {
        copied = target
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copied == target { copied = nil }
        }
    }

    // MARK: - Persistence

    private func load(_ meeting: Meeting) {
        notes = meeting.notes
        title = meeting.title
        savedNotes = meeting.notes
        savedTitle = meeting.title
        // While a meeting is being recorded you are writing, not reading, so the
        // page opens on your own notes; afterwards it opens on the written ones
        // if they exist.
        let recording = coordinator.activeMeetingID == meeting.id && coordinator.phase.isRecording
        mode = (meeting.summaryMarkdown?.isEmpty == false && !recording) ? .written : .mine
        panel = nil
        editingSummary = false
    }

    /// Runs `action` now, or after confirmation when it would replace notes the
    /// user edited by hand.
    /// Runs `action` now, or after confirmation when it would replace notes.
    ///
    /// Hand-edited notes always ask. `evenIfUnedited` also asks before
    /// rewriting notes nobody touched — for the one-click controls in the
    /// toolbar, where a stray click used to resend a long transcript to Claude
    /// for a near-identical result. Buttons whose label already says "rewrite"
    /// do not ask twice.
    private func confirmingOverwrite(_ meeting: Meeting, evenIfUnedited: Bool = false,
                                     _ action: @escaping () -> Void) {
        if editingSummary { finishSummaryEditing(for: meetingID) }
        let current = store.meeting(id: meetingID)
        if current?.summaryEditedAt != nil
            || (evenIfUnedited && current?.summaryMarkdown?.isEmpty == false) {
            pendingOverwrite = action
        } else {
            action()
        }
    }

    private var overwriteIsEdited: Bool { meeting?.summaryEditedAt != nil }

    private func toggleSummaryEditing(_ meeting: Meeting) {
        if editingSummary {
            finishSummaryEditing(for: meetingID)
        } else {
            summaryDraft = meeting.summaryMarkdown ?? ""
            editingSummary = true
        }
    }

    private func scheduleSummarySave() {
        summarySaveTask?.cancel()
        let id = meetingID
        summarySaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistSummaryDraft(to: id)
        }
    }

    private func finishSummaryEditing(for id: UUID) {
        guard editingSummary else { return }
        summarySaveTask?.cancel()
        summarySaveTask = nil
        persistSummaryDraft(to: id)
        editingSummary = false
    }

    private func persistSummaryDraft(to id: UUID) {
        let draft = summaryDraft
        guard store.meeting(id: id)?.summaryMarkdown != draft else { return }
        store.update(id: id) {
            $0.summaryMarkdown = draft
            $0.summaryEditedAt = Date()
        }
    }

    /// Debounced so typing doesn't hit the disk on every keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        let id = meetingID
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            persistEdits(to: id)
        }
    }

    private func flushPendingSave(for id: UUID) {
        guard let pending = saveTask else { return }
        pending.cancel()
        saveTask = nil
        persistEdits(to: id)
    }

    /// Writes only what the user changed, onto the latest stored copy.
    private func persistEdits(to id: UUID) {
        let notesChanged = notes != savedNotes
        let titleChanged = title != savedTitle
        guard notesChanged || titleChanged else { return }
        let notes = notes, title = title
        store.update(id: id) { meeting in
            if notesChanged { meeting.notes = notes }
            if titleChanged { meeting.title = title }
        }
        savedNotes = notes
        savedTitle = title
    }

    private func export(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.displayTitle).md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? (meeting.summaryMarkdown ?? "").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A small outlined label under the meeting title.
private struct MetaChip: View {
    let symbol: String
    let text: String
    var muted = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(text).font(.system(size: 12)).lineLimit(1)
        }
        .foregroundStyle(muted ? Palette.inkTertiary : Palette.inkSecondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 0.75) }
        .contentShape(Capsule())
    }
}

/// The switch between what Claude wrote and what you typed.
///
/// Two words in a pill, the selected one on a raised surface. It is a *view*
/// switch, not a tab bar — both show the same meeting — so it is small and sits
/// out of the way rather than announcing itself across the top of the pane.
private struct ModeSwitch: View {
    @Binding var mode: MeetingDetailView.Mode
    let hasWrittenNotes: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MeetingDetailView.Mode.allCases) { option in
                let isSelected = mode == option
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { mode = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Palette.ink : Palette.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                                    .fill(Palette.surface)
                                    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                            }
                        }
                        .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(option == .written && !hasWrittenNotes)
                .opacity(option == .written && !hasWrittenNotes ? 0.4 : 1)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Palette.fill) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Which notes to show")
    }
}

// MARK: - The reference panel

/// The transcript or Ask, beside the page rather than instead of it.
private struct SidePanel: View {
    let panel: MeetingDetailView.Panel
    let meeting: Meeting
    let isActive: Bool
    let transcriptCopied: Bool
    let onCopyTranscript: () -> Void
    let onNameSpeakers: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var coordinator: RecordingCoordinator
    @EnvironmentObject private var meetingChats: MeetingChats

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(panel.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if panel == .transcript, !meeting.segments.isEmpty {
                    IconButton(symbol: transcriptCopied ? "checkmark" : "doc.on.doc",
                               help: "Copy the transcript", emphasis: .plain, size: 11, action: onCopyTranscript)
                    IconButton(symbol: "person.text.rectangle",
                               help: "Replace You and Them with names, here and in what Claude reads",
                               emphasis: .plain, size: 11, action: onNameSpeakers)
                }
                IconButton(symbol: "sidebar.right", help: "Close this panel",
                           emphasis: .plain, size: 11, action: onClose)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            switch panel {
            case .ask:
                // Its own scroll view and composer; a chat inside a ScrollView
                // would scroll the input away with the messages.
                ChatView(chat: meetingChats.controller(for: meeting.id), embedded: true)
            case .transcript:
                ScrollView {
                    transcript.padding(.horizontal, 14).padding(.bottom, 20)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.paper)
        .hairline(.leading)
    }

    @ViewBuilder
    private var transcript: some View {
        if !meeting.segments.isEmpty {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(meeting.segments) { segment in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(meeting.label(for: segment.speaker))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(color(for: segment.speaker))
                            Text(segment.timestampLabel)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.inkTertiary)
                        }
                        Text(segment.text)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.ink)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isActive, coordinator.phase.isRecording {
            LiveTranscriptText(live: coordinator.activity.live)
        } else if !meeting.liveTranscript.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Live transcript (Whisper pass unavailable)")
                    .font(Typeface.eyebrow)
                    .foregroundStyle(Palette.inkTertiary)
                Text(meeting.liveTranscript)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(4)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("No transcript yet.")
                .font(Typeface.label)
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        }
    }

    private func color(for speaker: Speaker) -> Color {
        switch speaker {
        case .me: return Palette.ink
        case .others: return Palette.speakerOther
        case .unknown: return Palette.inkTertiary
        }
    }
}

/// The streaming live transcript. A leaf view: it is the only thing that needs
/// to re-render as text arrives, so it is the only subscriber.
private struct LiveTranscriptText: View {
    @ObservedObject var live: RecordingActivity.LiveText

    var body: some View {
        if live.text.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Listening…").font(Typeface.label).foregroundStyle(Palette.inkTertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else {
            Text(live.text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Recording

/// Clock, levels and stop, at the leading end of the bottom bar while
/// recording. In the bar rather than floating on its own so the page has one
/// thing along its bottom edge, not two competing ones.
private struct RecordingSegment: View {
    @ObservedObject var activity: RecordingActivity
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Palette.recording).frame(width: 7, height: 7)
            Text(MenuBarView.timeLabel(activity.elapsed))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.ink)
            MiniMeters(meters: activity.meters)
            RecordButton(isRecording: true, isBusy: false, size: 10, start: {}, stop: stop)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background { Capsule().fill(Palette.recording.opacity(0.08)) }
    }
}

/// Both sources' meters: the only part of the segment that redraws at the
/// level rate.
private struct MiniMeters: View {
    @ObservedObject var meters: RecordingActivity.Meters

    var body: some View {
        HStack(spacing: 8) {
            MiniMeter(level: meters.levels.mic).help("Your microphone")
            MiniMeter(level: meters.levels.system).help("The call's audio")
        }
    }
}

/// A five-bar level indicator. Fits in a bar where a labelled meter does not.
private struct MiniMeter: View {
    let level: Float

    var body: some View {
        let lit = Int((LevelMeter.normalized(level) * 5).rounded())
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? Palette.ink : Palette.hairline)
                    .frame(width: 2.5, height: [6, 9, 12, 9, 6][index])
            }
        }
    }
}

// MARK: - Sheets

/// Names for the two sides of a transcript. Speaker labels come from which
/// audio source was louder, so there are only ever two sides to name — plus
/// "Speaker" where both were talking at once, which stays unnamed.
private struct SpeakerNamesSheet: View {
    @State var names: [String: String]
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void

    private func binding(_ speaker: Speaker) -> Binding<String> {
        Binding(get: { names[speaker.rawValue] ?? "" },
                set: { names[speaker.rawValue] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name speakers").font(Typeface.sectionHeading).foregroundStyle(Palette.ink)
            LabeledContent("You (your microphone)") {
                TextField("You", text: binding(.me)).frame(width: 220)
            }
            LabeledContent("Them (the call's audio)") {
                TextField("Them", text: binding(.others)).frame(width: 220)
            }
            Text("Used in the transcript and in what Claude reads when it writes notes or answers questions. Rewrite the notes to apply names to them. If several people spoke through the call, \"Them\" covers all of them.")
                .font(Typeface.meta)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(names.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .tint(Palette.ink)
    }
}
