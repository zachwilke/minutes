import SwiftUI

/// Ask questions across the whole meeting library, or — embedded in a meeting —
/// about that one meeting, with the rest of the library still in reach.
struct ChatView: View {
    @ObservedObject var chat: ChatController
    /// Embedded in a meeting's pane: no page header, meeting-specific wording.
    var embedded = false
    @EnvironmentObject private var store: MeetingStore

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !embedded { header }
            transcript
            composer
        }
    }

    private var isScoped: Bool { chat.scope != nil }

    /// Recipes that make sense here: meeting ones need a meeting to be about.
    private var recipes: [SharedPrompts.Recipes.Recipe] {
        SharedPrompts.Recipes.all.filter { $0.scope == "any" || $0.scope == (isScoped ? "meeting" : "library") }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask")
                    .font(Typeface.display())
                    .foregroundStyle(Palette.ink)
                Text(store.meetings.isEmpty
                     ? "No meetings recorded yet."
                     : "Across \(store.meetings.count) meeting\(store.meetings.count == 1 ? "" : "s")")
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            if !chat.messages.isEmpty {
                IconButton(symbol: "trash",
                           help: "Clear this conversation",
                           emphasis: .plain) { chat.clear() }
            }
        }
        .frame(maxWidth: Layout.documentWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.documentGutter)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty {
                        suggestions
                    }
                    ForEach(chat.messages) { message in
                        bubble(message).id(message.id)
                    }
                    // Anchor for autoscroll; scrolling to the last message is not
                    // enough while it is still growing.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                // Standalone, the conversation is the page, so it takes the
                // same reading column the notes do instead of stretching the
                // full width of a maximised window.
                .padding(embedded ? Layout.cardPadding : 0)
                .frame(maxWidth: embedded ? .infinity : Layout.documentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, embedded ? 0 : Layout.documentGutter)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: chat.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: chat.messages.count) { _, _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private static let bottomAnchor = "chat-bottom"

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(Palette.fill)
                    }
                    .textSelection(.enabled)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if message.text.isEmpty, chat.isResponding {
                    thinking
                } else if message.isError {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.warning)
                        Text(message.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    MarkdownView(markdown: message.text).equatable()
                    HStack(alignment: .top, spacing: 8) {
                        grounding(message)
                        Spacer(minLength: 0)
                        // An answer is often the thing to paste somewhere — a
                        // follow-up email above all.
                        if !(chat.isResponding && message.id == chat.messages.last?.id) {
                            IconButton(symbol: "doc.on.doc", help: "Copy this answer",
                                       emphasis: .plain, size: 10) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.text, forType: .string)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thinking: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
            Text("Reading your meetings…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    /// What the answer was actually based on. Worth showing: it is the difference
    /// between a grounded answer and a plausible one.
    @ViewBuilder
    private func grounding(_ message: ChatMessage) -> some View {
        let titles = chat.groundingTitles(for: message)
        if !titles.isEmpty {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "text.quote")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(titles.prefix(4).joined(separator: " · ")
                     + (titles.count > 4 ? " and \(titles.count - 4) more" : ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(store.meetings.isEmpty
                 ? "Record a meeting and you can ask about it here."
                 : isScoped ? "Ask anything about this meeting, or start from one of these:" : "Try asking:")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if !store.meetings.isEmpty {
                // Recipes send straight away; examples are a starting point to edit.
                ForEach(recipes, id: \.id) { recipe in
                    suggestionChip(recipe.title, symbol: "sparkles") { chat.send(recipe.prompt) }
                }
                if !isScoped {
                    ForEach(Self.examples, id: \.self) { example in
                        suggestionChip(example, symbol: "arrow.turn.down.right") {
                            draft = example
                            inputFocused = true
                        }
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func suggestionChip(_ text: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.inkTertiary)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background { Capsule().fill(Palette.fill) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private static let examples = [
        "What did I commit to last week?",
        "Summarise everything discussed about the file server.",
        "Which meetings are still missing follow-up?",
        "When did I last speak to this client, and what about?"
    ]

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !recipes.isEmpty {
                Menu {
                    ForEach(recipes, id: \.id) { recipe in
                        Button(recipe.title) { chat.send(recipe.prompt) }
                    }
                } label: {
                    Image(systemName: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Recipes")
                .disabled(chat.isResponding)
                .padding(.bottom, 8)
            }
            // .vertical axis lets a long question grow instead of scrolling in a
            // one-line field.
            TextField(isScoped ? "Ask about this meeting…" : "Ask about your meetings…",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background { Capsule().fill(Palette.surface) }
                .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5) }

            if chat.isResponding {
                IconButton(symbol: "stop.fill",
                            help: "Stop generating",
                            emphasis: .prominent,
                            tint: Palette.recording,
                            size: 13) { chat.cancel() }
            } else {
                IconButton(symbol: "arrow.up",
                            help: "Ask Claude",
                            emphasis: .prominent,
                            size: 13,
                            action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: embedded ? .infinity : Layout.documentWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, embedded ? Layout.cardPadding : Layout.documentGutter)
        .padding(.top, 10)
        .padding(.bottom, embedded ? Layout.cardPadding : Layout.windowInset)
    }

    private func send() {
        let question = draft
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        chat.send(question)
    }
}
