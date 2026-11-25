import SwiftUI

/// What the window is showing.
///
/// Home and folders are lists of meetings; a meeting is reached from one of
/// them rather than from the sidebar, which is the arrangement Granola uses:
/// the sidebar says *where* you are, and the page says what is there.
enum SidebarItem: Hashable {
    case home
    case chat
    case folder(String)
    case meeting(UUID)
    case trash

    /// Lists a meeting can be opened from, which the back button returns to.
    var isList: Bool {
        switch self {
        case .home, .folder: return true
        default: return false
        }
    }
}

/// Narrows the library to one folder, person or company.
enum LibraryFilter: Hashable {
    case folder(String)
    case person(String)
    case company(String)

    var label: String {
        switch self {
        case .folder(let name), .person(let name), .company(let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder"
        case .person: return "person"
        case .company: return "building.2"
        }
    }

    func matches(_ meeting: Meeting) -> Bool {
        switch self {
        case .folder(let name): return meeting.folder == name
        case .person(let name): return meeting.attendees.contains(name)
        case .company(let domain): return meeting.companies.contains(domain)
        }
    }
}

/// Navigation: Home, Ask, and the folders meetings are filed in.
struct LibrarySidebar: View {
    @EnvironmentObject private var store: MeetingStore
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                NavRow(title: "Home", symbol: "house").tag(SidebarItem.home)
                NavRow(title: "Ask", symbol: "bubble.left").tag(SidebarItem.chat)
            }

            Section {
                if store.folders.isEmpty {
                    Text("File a meeting from its page to start a folder.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .selectionDisabled()
                } else {
                    ForEach(store.folders, id: \.self) { folder in
                        NavRow(title: folder, symbol: "folder",
                               count: store.meetings.lazy.filter { $0.folder == folder }.count)
                            .tag(SidebarItem.folder(folder))
                    }
                }
            } header: {
                Text("Folders")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.top, 10)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    /// The things you visit rarely, kept out of the list: deleted meetings and
    /// Settings, as quiet icons along the bottom edge.
    private var footer: some View {
        HStack(spacing: 2) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 28, height: 28)
                    .hoverFill()
            }
            .buttonStyle(.plain)
            .help("Settings")

            if !store.trashed.isEmpty {
                Button { selection = .trash } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(selection == .trash ? Palette.ink : Palette.inkSecondary)
                        .frame(width: 28, height: 28)
                        .hoverFill(isSelected: selection == .trash)
                }
                .buttonStyle(.plain)
                .help("Recently Deleted (\(store.trashed.count))")
            }
            Spacer()
        }
        .padding(.horizontal, Layout.sidebarInset + 4)
        .padding(.vertical, 10)
    }
}

private struct NavRow: View {
    let title: String
    let symbol: String
    var count: Int?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Palette.inkSecondary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }
}
