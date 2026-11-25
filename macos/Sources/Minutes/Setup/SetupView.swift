import SwiftUI

/// First-run setup: what is missing, why it matters, and a button that fixes it.
///
/// Shown as a sheet when a dependency the pipeline needs is absent, instead of
/// letting the first meeting fail at the end and explain itself in an error.
struct SetupView: View {
    @ObservedObject var setup: SetupService
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 14) {
                row(title: "Whisper (whisper-cli)",
                    state: setup.whisper,
                    fix: whisperFix)
                row(title: "Speech model",
                    state: setup.model,
                    fix: modelFix)
                row(title: "Claude Code",
                    state: setup.claude,
                    fix: claudeFix)
            }
            .padding(18)

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 520)
        .background(BrandBackground(translucent: AppSettings.shared.translucentWindow))
        .tint(Palette.ink)
        .task { await setup.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish setting up Minutes")
                    .font(.system(size: 15, weight: .semibold))
                Text("Recording works now; these are needed to transcribe and write notes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
    }

    private var footer: some View {
        HStack {
            IconButton(symbol: "arrow.clockwise", help: "Re-check everything") {
                Task { await setup.refresh() }
            }
            Spacer()
            Button(setup.needsSetup ? "Finish later" : "Done", action: dismiss)
                .buttonStyle(.borderedProminent)
                .tint(Palette.ink)
                .buttonBorderShape(.capsule)
                .keyboardShortcut(setup.needsSetup ? .cancelAction : .defaultAction)
        }
        .padding(14)
    }

    // MARK: - Rows

    private func row(title: String, state: SetupService.ItemState,
                     fix: some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusGlyph(state)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail(of: state))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            fix
        }
    }

    @ViewBuilder
    private func statusGlyph(_ state: SetupService.ItemState) -> some View {
        switch state {
        case .checking, .fixing:
            ProgressView().controlSize(.small).scaleEffect(0.65)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Palette.accent)
        case .missing:
            Image(systemName: "circle.dashed")
                .font(.system(size: 14))
                .foregroundStyle(Palette.warning)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.danger)
        }
    }

    private func detail(of state: SetupService.ItemState) -> String {
        switch state {
        case .checking: return "Checking…"
        case .ready(let detail): return detail
        case .missing(let detail): return detail
        case .fixing(let progress): return progress
        case .failed(let reason): return reason
        }
    }

    // MARK: - Fix buttons

    @ViewBuilder
    private var whisperFix: some View {
        switch setup.whisper {
        case .missing where setup.homebrewPresent, .failed where setup.homebrewPresent:
            IconButton(symbol: "arrow.down.circle",
                        help: "Run `brew install whisper-cpp`",
                        emphasis: .prominent) {
                Task { await setup.installWhisper() }
            }
        case .missing, .failed:
            IconButton(symbol: "safari",
                        help: "Homebrew is needed first — open brew.sh") {
                NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var modelFix: some View {
        switch setup.model {
        case .missing, .failed:
            IconButton(symbol: "arrow.down.circle",
                        help: "Download \(SetupService.modelToDownload.name) (\(SetupService.modelToDownload.approximateSize)) from Hugging Face",
                        emphasis: .prominent) {
                setup.downloadModel()
            }
        case .fixing:
            IconButton(symbol: "xmark", help: "Cancel the download") {
                setup.cancelModelDownload()
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var claudeFix: some View {
        switch setup.claude {
        case .missing, .failed:
            // Deliberately a pointer, not an installer: Claude Code's install
            // wants a sign-in in the user's own terminal, and running a vendor's
            // install script on their behalf is not this app's call.
            IconButton(symbol: "safari",
                        help: "Open the Claude Code page — install, then run `claude` once to sign in",
                        emphasis: .prominent) {
                setup.openClaudeCodePage()
            }
        default:
            EmptyView()
        }
    }
}
