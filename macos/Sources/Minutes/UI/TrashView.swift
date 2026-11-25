import SwiftUI

/// Meetings deleted in the last 30 days, restorable until they expire.
struct TrashView: View {
    @EnvironmentObject private var store: MeetingStore
    @State private var confirmEmpty = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recently Deleted")
                            .font(Typeface.documentTitle)
                            .foregroundStyle(Palette.ink)
                        Text("Meetings are removed for good 30 days after you delete them.")
                            .font(Typeface.label)
                            .foregroundStyle(Palette.inkSecondary)
                    }
                    Spacer()
                    if !store.trashed.isEmpty {
                        PillButton(title: "Empty") { confirmEmpty = true }
                    }
                }
                .padding(.bottom, 22)

                if store.trashed.isEmpty {
                    Text("Nothing here.")
                        .font(Typeface.documentBody)
                        .foregroundStyle(Palette.inkTertiary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.trashed.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Rectangle().fill(Palette.hairline).frame(height: 0.5)
                            }
                            row(item)
                        }
                    }
                }
            }
            .frame(maxWidth: Layout.documentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Layout.documentGutter)
            .padding(.top, 30)
            .padding(.bottom, 40)
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog("Permanently delete \(store.trashed.count) meeting\(store.trashed.count == 1 ? "" : "s")?",
                            isPresented: $confirmEmpty) {
            Button("Delete Permanently", role: .destructive) { store.emptyTrash() }
        } message: {
            Text("Recordings, transcripts and notes are removed and cannot be restored.")
        }
    }

    private func row(_ item: MeetingStore.TrashedMeeting) -> some View {
        let remaining = max(0, Int((MeetingStore.trashLifetime - Date().timeIntervalSince(item.deletedAt)) / 86_400))
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.meeting.displayTitle)
                    .font(Typeface.rowTitle)
                    .foregroundStyle(Palette.ink)
                Text("\(item.meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · "
                     + "\(item.meeting.durationLabel) · deleted in \(remaining) day\(remaining == 1 ? "" : "s")")
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer()
            PillButton(title: "Restore") { store.restore(item) }
            Button("Delete", role: .destructive) { store.deletePermanently(item) }
                .controlSize(.small)
        }
        .padding(.vertical, 11)
    }
}
