import SwiftUI

/// The floating "Ask anything" bar along the bottom of a page.
///
/// Asking is the second most common thing to do with a meeting after reading
/// it, so it lives on the page you are reading instead of one click away in
/// the sidebar. One suggestion sits in the bar while it is empty — enough to
/// show what kind of question works, not a menu to read.
struct AskBar<Leading: View>: View {
    var placeholder = "Ask anything"
    var suggestion: SharedPrompts.Recipes.Recipe?
    /// False hides the text field and keeps only `leading` — for when a
    /// conversation is already open beside the page and has its own composer.
    var showsField = true
    var isBusy = false
    @ViewBuilder var leading: Leading
    let onAsk: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading
            if showsField {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.leading, leadingIsEmpty ? 10 : 0)
                if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let suggestion {
                        SuggestionChip(title: suggestion.title) { onAsk(suggestion.prompt) }
                            .disabled(isBusy)
                    }
                } else {
                    IconButton(symbol: "arrow.up", help: "Ask Claude",
                               emphasis: .prominent, size: 12, action: send)
                        .disabled(isBusy)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 50)
        .frame(maxWidth: showsField ? .infinity : nil)
        .background {
            Capsule()
                .fill(Palette.raised)
                .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
        }
        .overlay { Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5) }
    }

    private var leadingIsEmpty: Bool { Leading.self == EmptyView.self }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return }
        draft = ""
        onAsk(question)
    }
}

extension AskBar where Leading == EmptyView {
    init(placeholder: String = "Ask anything",
         suggestion: SharedPrompts.Recipes.Recipe? = nil,
         isBusy: Bool = false,
         onAsk: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.suggestion = suggestion
        self.isBusy = isBusy
        self.leading = EmptyView()
        self.onAsk = onAsk
    }
}

/// An outlined suggestion inside the bar.
private struct SuggestionChip: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkSecondary)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(isHovering ? Palette.fill : Palette.raised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

extension SharedPrompts.Recipes {
    /// A recipe by id, for the one suggestion a bar shows.
    static func named(_ id: String) -> Recipe? { all.first { $0.id == id } }
}
