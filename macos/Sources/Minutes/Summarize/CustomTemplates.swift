import Foundation
import Combine

/// Summary styles the user writes themselves, alongside the six built in.
///
/// Stored in `templates.json` beside the library rather than in each meeting,
/// so editing a style changes it everywhere it is used next. Ids start with
/// `custom-`, which keeps them from ever colliding with a built-in id.
@MainActor
final class CustomTemplates: ObservableObject {
    static let shared = CustomTemplates()

    struct Entry: Codable, Identifiable, Hashable, Sendable {
        var id: String = "custom-\(UUID().uuidString.lowercased())"
        var name: String
        var blurb: String = ""
        var instructions: String
    }

    @Published private(set) var entries: [Entry] = []

    private let file = AppPaths.supportRoot.appendingPathComponent("templates.json")

    private init() {
        entries = Self.load(from: file)
        Snapshot.set(entries)
    }

    func save(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        persist()
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    private func persist() {
        Snapshot.set(entries)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: file, options: .atomic)
        } catch {
            Log.error("Could not save templates: \(error.localizedDescription)")
        }
    }

    nonisolated fileprivate static func load(from file: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            Log.warn("Could not read templates.json: \(error.localizedDescription)")
            return []
        }
    }

    /// A lock-guarded copy, so `SummaryTemplate.all` can be read from any
    /// thread — the command line diagnostics never touch the main actor.
    enum Snapshot {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var current: [Entry]?

        static func set(_ entries: [Entry]) {
            lock.lock(); current = entries; lock.unlock()
        }

        static var entries: [Entry] {
            lock.lock()
            if let current { lock.unlock(); return current }
            lock.unlock()
            // Not loaded through the main actor yet (command line use): read
            // the file directly.
            let file = AppPaths.supportRoot.appendingPathComponent("templates.json")
            let loaded = CustomTemplates.load(from: file)
            set(loaded)
            return loaded
        }
    }
}
