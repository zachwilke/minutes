import Foundation
import Combine

/// Single source of truth for the meeting library. Each meeting is a directory
/// containing its own `meeting.json`, so the library is a plain filesystem scan
/// and there is no database to corrupt or migrate.
///
/// `meetings` is an index: every field except the transcript, which is most of
/// a library's size and which nothing in the list, the sidebar or the filters
/// shows. Transcripts stay on disk and are read when something needs them —
/// `fullMeeting(id:)` for the meeting on screen and the pipeline, a small
/// cache for the few opened recently, and `TranscriptSearchText` for search.
@MainActor
final class MeetingStore: ObservableObject {
    /// Index copies, newest first: `transcriptLoaded` is false on every one.
    @Published private(set) var meetings: [Meeting] = []
    /// Meetings in the trash, most recently deleted first.
    @Published private(set) var trashed: [TrashedMeeting] = []

    struct TrashedMeeting: Identifiable {
        var meeting: Meeting
        var deletedAt: Date
        var id: UUID { meeting.id }
    }

    static let trashLifetime: TimeInterval = 30 * 86_400

    /// Transcripts read recently, so the meeting on screen is not re-read from
    /// disk on every render. Always identical to what is on disk — every save
    /// writes through — so evicting one only costs a re-read. Not published:
    /// `fullMeeting(id:)` fills it from inside view updates.
    private var transcripts: [UUID: CachedTranscript] = [:]
    /// Least recently used first.
    private var transcriptUse: [UUID] = []
    static let transcriptCacheLimit = 8

    private struct CachedTranscript {
        var segments: [TranscriptSegment]
        var liveTranscript: String
        /// The last write failed (a full disk), so this copy is the only one;
        /// it is never evicted until a save succeeds.
        var unsaved = false
    }

    /// Lowercased UTF-8 of each meeting's title, notes, summary and attendees,
    /// built on first search and invalidated on save. Small; the transcript
    /// part of search reads `TranscriptSearchText` files instead.
    private var metadataSearchCache: [UUID: [UInt8]] = [:]
    /// Meetings whose search text file is known to be current this session,
    /// which spares search two file stats per meeting per keystroke.
    private var searchTextFresh: Set<UUID> = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init() {
        AppPaths.ensureDirectories()
        let began = Date()
        reload()
        recoverInterruptedRecordings()
        purgeExpiredTrash()
        applyAudioRetention()
        // The one launch cost that grows with use — every meeting.json is read
        // at startup, though only its index fields are kept. Logged so a slow
        // launch names its culprit.
        Log.info("Library loaded: \(meetings.count) meetings in \(Int(Date().timeIntervalSince(began) * 1000))ms")
    }

    func reload() {
        meetings = Self.loadIndex()
        transcripts.removeAll()
        transcriptUse.removeAll()
        metadataSearchCache.removeAll()
        searchTextFresh.removeAll()
        reloadTrash()
    }

    /// Reads every meeting from disk without its transcript, newest first.
    ///
    /// Nonisolated so the command line diagnostics can read the library without
    /// hopping to the main actor — they block the main thread while they run, so
    /// such a hop would deadlock.
    nonisolated static func loadIndex() -> [Meeting] {
        load(indexOnly: true)
    }

    /// Reads every meeting in full, transcripts included. Only for one-off
    /// command line work; the app keeps `loadIndex()` resident.
    nonisolated static func loadAll() -> [Meeting] {
        load(indexOnly: false)
    }

    /// One meeting in full, from disk.
    nonisolated static func loadMeeting(id: UUID) -> Meeting? {
        let file = AppPaths.meetingDir(id).appendingPathComponent("meeting.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decode(data, indexOnly: false)
    }

    nonisolated private static func decode(_ data: Data, indexOnly: Bool) throws -> Meeting {
        // A decoder per call: JSONDecoder makes no promise about concurrent use.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if indexOnly { decoder.userInfo[.meetingIndexOnly] = true }
        return try decoder.decode(Meeting.self, from: data)
    }

    /// Parsed in parallel. This runs on the main thread at launch; every core
    /// takes a share of the files.
    nonisolated private static func load(indexOnly: Bool) -> [Meeting] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppPaths.meetingsRoot,
                                                includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        let lock = NSLock()
        nonisolated(unsafe) var loaded: [Meeting] = []
        loaded.reserveCapacity(dirs.count)
        DispatchQueue.concurrentPerform(iterations: dirs.count) { index in
            let dir = dirs[index]
            let file = dir.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: file) else { return }
            do {
                let meeting = try decode(data, indexOnly: indexOnly)
                lock.lock(); loaded.append(meeting); lock.unlock()
            } catch {
                Log.warn("Skipping unreadable meeting at \(dir.lastPathComponent): \(error)")
            }
        }
        return loaded.sorted { $0.startedAt > $1.startedAt }
    }

    /// Reconciles meetings left mid-recording by a crash, a force-quit, or the
    /// Mac shutting down.
    ///
    /// Such a meeting keeps `state == .recording` and no `endedAt`, which makes
    /// `duration` count up against the present forever — the library shows a
    /// meeting that appears to still be running. Its WAV header is also still
    /// zero-length, so the audio is unplayable even though the samples are on
    /// disk. Both are fixable after the fact.
    private func recoverInterruptedRecordings() {
        let orphans = meetings.filter { $0.state == .recording }
        guard !orphans.isEmpty else { return }

        for var meeting in orphans {
            let recovered = WAVWriter.repairHeaderIfNeeded(at: meeting.mixedAudioFile)

            guard let recovered, recovered >= 1 else {
                // Nothing was captured, so there is nothing to keep. Only discard
                // when the meeting also carries no work of the user's own.
                let hasUserContent = !meeting.notes.isEmpty
                    || !(meeting.summaryMarkdown ?? "").isEmpty
                    || meeting.hasSegments
                if hasUserContent {
                    meeting.endedAt = meeting.startedAt
                    meeting.state = .failed
                    meeting.failureReason = "Recording was interrupted and no audio was captured."
                    save(meeting)
                } else {
                    Log.info("Discarding empty interrupted recording \(meeting.id)")
                    delete(meeting)
                }
                continue
            }

            meeting.endedAt = meeting.startedAt.addingTimeInterval(recovered)
            meeting.state = .failed
            meeting.failureReason = "Recording was interrupted, so it was never transcribed. "
                + "The audio was recovered — use Re-transcribe to process it."
            save(meeting)
            Log.info("Recovered interrupted recording \(meeting.id): \(String(format: "%.1f", recovered))s")
        }
    }

    /// The index copy: everything but the transcript. Use `fullMeeting(id:)`
    /// to read or change `segments` or `liveTranscript`.
    func meeting(id: UUID) -> Meeting? {
        meetings.first { $0.id == id }
    }

    /// The meeting with its transcript, from the cache or disk. Cheap to call
    /// repeatedly — the meeting on screen calls it on every render.
    func fullMeeting(id: UUID) -> Meeting? {
        meeting(id: id).map(withTranscript)
    }

    /// Fills in an index copy's transcript; a full copy comes back unchanged.
    func withTranscript(_ meeting: Meeting) -> Meeting {
        guard !meeting.transcriptLoaded else { return meeting }
        var full = meeting
        full.transcriptLoaded = true
        if let cached = cachedTranscript(meeting.id) {
            full.segments = cached.segments
            full.liveTranscript = cached.liveTranscript
        } else if meeting.hasTranscript {
            guard let disk = Self.loadMeeting(id: meeting.id) else {
                // Unreadable right now. Stay an index copy, which cannot be
                // written, rather than pass off an empty transcript as the real one.
                Log.warn("Could not read the transcript of \(meeting.id)")
                return meeting
            }
            full.segments = disk.segments
            full.liveTranscript = disk.liveTranscript
            remember(full, unsaved: false)
        }
        return full
    }

    private func cachedTranscript(_ id: UUID) -> CachedTranscript? {
        guard let cached = transcripts[id] else { return nil }
        transcriptUse.removeAll { $0 == id }
        transcriptUse.append(id)
        return cached
    }

    private func remember(_ meeting: Meeting, unsaved: Bool) {
        transcripts[meeting.id] = CachedTranscript(segments: meeting.segments,
                                                   liveTranscript: meeting.liveTranscript,
                                                   unsaved: unsaved)
        transcriptUse.removeAll { $0 == meeting.id }
        transcriptUse.append(meeting.id)
        while transcripts.count > Self.transcriptCacheLimit,
              let victim = transcriptUse.first(where: { transcripts[$0]?.unsaved == false }) {
            transcripts[victim] = nil
            transcriptUse.removeAll { $0 == victim }
        }
    }

    private func forget(_ id: UUID) {
        transcripts[id] = nil
        transcriptUse.removeAll { $0 == id }
        metadataSearchCache[id] = nil
        searchTextFresh.remove(id)
    }

    /// Whether a meeting's transcript is in memory. For tests.
    func isTranscriptCached(_ id: UUID) -> Bool { transcripts[id] != nil }

    /// Inserts or replaces a meeting and writes it to disk immediately. Called on
    /// every keystroke in the notes editor, so writes must stay cheap and atomic.
    ///
    /// Takes a full copy or an index copy. An index copy keeps the transcript
    /// already stored, except for a field the caller filled in itself: setting
    /// `liveTranscript` on an index copy and saving it does what it says.
    func save(_ meeting: Meeting) {
        var full = meeting
        if !meeting.transcriptLoaded {
            let stored = withTranscript(meeting.indexCopy)
            guard stored.transcriptLoaded else {
                Log.error("Not saving \(meeting.id): its transcript could not be read, and saving would erase it")
                return
            }
            full = stored
            if !meeting.segments.isEmpty { full.segments = meeting.segments }
            if !meeting.liveTranscript.isEmpty { full.liveTranscript = meeting.liveTranscript }
        }

        var previous: Meeting?
        if let index = meetings.firstIndex(where: { $0.id == full.id }) {
            previous = meetings[index]
            meetings[index] = full.indexCopy
        } else {
            meetings.insert(full.indexCopy, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        metadataSearchCache[full.id] = nil
        searchTextFresh.remove(full.id)
        let saved = persist(full, previous: previous)
        remember(full, unsaved: !saved)
    }

    /// Applies a change to the latest stored copy of a meeting, transcript
    /// included.
    ///
    /// Long-running work — Whisper, Claude — must use this rather than saving a
    /// copy it read minutes ago: the user keeps editing notes and the title while
    /// a meeting processes, and a stale save rolls those edits back. Unlike
    /// `save`, it never recreates a meeting that was deleted in the meantime.
    @discardableResult
    func update(id: UUID, _ change: (inout Meeting) -> Void) -> Meeting? {
        guard var current = fullMeeting(id: id), current.transcriptLoaded else { return nil }
        change(&current)
        save(current)
        return current
    }

    /// Returns whether the meeting reached the disk.
    @discardableResult
    private func persist(_ meeting: Meeting, previous: Meeting?) -> Bool {
        do {
            try FileManager.default.createDirectory(at: meeting.directory, withIntermediateDirectories: true)
            let data = try encoder.encode(meeting)
            // Write to a sibling then move, so a crash mid-write cannot truncate
            // an existing meeting's metadata.
            let tmp = meeting.directory.appendingPathComponent("meeting.json.tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(meeting.metadataFile, withItemAt: tmp)

            // The summary file only changes when the summary does. Saves happen
            // on the notes keystroke debounce, and rewriting an unchanged
            // summary each time was a wasted write per pause in typing.
            if let summary = meeting.summaryMarkdown, !summary.isEmpty,
               summary != previous?.summaryMarkdown
                || !FileManager.default.fileExists(atPath: meeting.summaryFile.path) {
                try? summary.write(to: meeting.summaryFile, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            Log.error("Failed to persist meeting \(meeting.id): \(error)")
            return false
        }
    }

    /// Meetings whose pipeline was cut off by a quit or crash — including ones
    /// stopped while the app was quitting. The coordinator re-queues them.
    var interruptedPipelines: [UUID] {
        meetings.filter { $0.state == .transcribing || $0.state == .summarizing }
            .sorted { $0.startedAt < $1.startedAt }
            .map(\.id)
    }

    // MARK: - Trash

    /// Moves a meeting to the trash. Restorable for 30 days.
    func moveToTrash(_ meeting: Meeting) {
        let destination = AppPaths.trashRoot.appendingPathComponent(meeting.id.uuidString, isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: meeting.directory, to: destination)
            try ISO8601DateFormatter().string(from: Date())
                .write(to: destination.appendingPathComponent(Self.deletedMarker), atomically: true, encoding: .utf8)
        } catch {
            Log.error("Could not move meeting \(meeting.id) to the trash: \(error)")
            return
        }
        meetings.removeAll { $0.id == meeting.id }
        forget(meeting.id)
        TranscriptSearchText.remove(meeting.id)
        reloadTrash()
    }

    func restore(_ trashed: TrashedMeeting) {
        let source = AppPaths.trashRoot.appendingPathComponent(trashed.id.uuidString, isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: source.appendingPathComponent(Self.deletedMarker))
            try FileManager.default.moveItem(at: source, to: trashed.meeting.directory)
        } catch {
            Log.error("Could not restore meeting \(trashed.id): \(error)")
            return
        }
        meetings.append(trashed.meeting)
        meetings.sort { $0.startedAt > $1.startedAt }
        reloadTrash()
    }

    func deletePermanently(_ trashed: TrashedMeeting) {
        try? FileManager.default.removeItem(
            at: AppPaths.trashRoot.appendingPathComponent(trashed.id.uuidString, isDirectory: true))
        reloadTrash()
    }

    func emptyTrash() {
        trashed.forEach { try? FileManager.default.removeItem(
            at: AppPaths.trashRoot.appendingPathComponent($0.id.uuidString, isDirectory: true)) }
        reloadTrash()
    }

    private static let deletedMarker = ".deleted-at"

    private func reloadTrash() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: AppPaths.trashRoot, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        trashed = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
                  let meeting = try? Self.decode(data, indexOnly: true) else { return nil }
            let stamp = (try? String(contentsOf: dir.appendingPathComponent(Self.deletedMarker), encoding: .utf8))
                .flatMap { ISO8601DateFormatter().date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return TrashedMeeting(meeting: meeting, deletedAt: stamp ?? Date())
        }
        .sorted { $0.deletedAt > $1.deletedAt }
    }

    private func purgeExpiredTrash() {
        for item in trashed where Date().timeIntervalSince(item.deletedAt) > Self.trashLifetime {
            Log.info("Purging \(item.id) from the trash")
            deletePermanently(item)
        }
    }

    /// Drops audio from finished meetings past the retention age. The audio is
    /// the bulkiest and most sensitive part; the transcript is what is used.
    func applyAudioRetention() {
        let days = AppSettings.shared.audioRetentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for meeting in meetings where meeting.startedAt < cutoff && meeting.state == .complete
            && meeting.hasSegments {
            for file in [meeting.mixedAudioFile, meeting.energyLogFile]
            where FileManager.default.fileExists(atPath: file.path) {
                try? FileManager.default.removeItem(at: file)
                Log.info("Removed \(file.lastPathComponent) from \(meeting.id) (older than \(days) days)")
            }
        }
    }

    /// Removes a meeting outright, bypassing the trash.
    func delete(_ meeting: Meeting) {
        meetings.removeAll { $0.id == meeting.id }
        forget(meeting.id)
        TranscriptSearchText.remove(meeting.id)
        do {
            try FileManager.default.removeItem(at: meeting.directory)
        } catch {
            Log.error("Failed to delete meeting directory: \(error)")
        }
    }

    // MARK: - Facets

    /// Folder names in use, alphabetically.
    var folders: [String] {
        Array(Set(meetings.compactMap(\.folder))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The people met with most, most frequent first.
    func frequentPeople(limit: Int = 15) -> [String] {
        ranked(meetings.flatMap(\.attendees), limit: limit)
    }

    /// The companies met with most, by invitee email domain.
    func frequentCompanies(limit: Int = 15) -> [String] {
        ranked(meetings.flatMap(\.companies), limit: limit)
    }

    private func ranked(_ values: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        values.forEach { counts[$0, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }

    /// Full-text search across title, notes, transcript and summary.
    ///
    /// Titles, notes and summaries are searched in memory. Transcripts are
    /// searched in their `TranscriptSearchText` files, memory-mapped in
    /// parallel, so they never need to be resident. Matching is by bytes on
    /// lowercased UTF-8 — `String.contains` over a library of transcripts took
    /// most of a second per keystroke.
    func search(_ query: String) -> [Meeting] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return meetings }
        let needle = Array(q.utf8)

        var hits = [Bool](repeating: false, count: meetings.count)
        var candidates: [Int] = []
        for (index, meeting) in meetings.enumerated() {
            if metadataHaystack(for: meeting).contains(bytes: needle) {
                hits[index] = true
            } else if meeting.hasTranscript {
                candidates.append(index)
            }
        }

        if !candidates.isEmpty {
            prepareSearchText(for: candidates.map { meetings[$0] })
            let ids = candidates.map { meetings[$0].id }
            var found = [Bool](repeating: false, count: ids.count)
            found.withUnsafeMutableBufferPointer { buffer in
                let buffer = buffer
                DispatchQueue.concurrentPerform(iterations: ids.count) { i in
                    buffer[i] = TranscriptSearchText.contains(needle, in: ids[i])
                }
            }
            for (i, index) in candidates.enumerated() where found[i] { hits[index] = true }
        }
        return meetings.indices.filter { hits[$0] }.map { meetings[$0] }
    }

    private func metadataHaystack(for meeting: Meeting) -> [UInt8] {
        if let cached = metadataSearchCache[meeting.id] { return cached }
        let built = Array([
            meeting.displayTitle,
            meeting.notes,
            meeting.summaryMarkdown ?? "",
            meeting.attendees.joined(separator: " ")
        ].joined(separator: "\n").lowercased().utf8)
        metadataSearchCache[meeting.id] = built
        return built
    }

    /// Brings these meetings' search text files up to date, in parallel. A
    /// transcript already in memory is written from there; any other is read
    /// from its `meeting.json` one at a time per core and let go.
    private func prepareSearchText(for meetings: [Meeting]) {
        let stale = meetings.filter { !searchTextFresh.contains($0.id) }
        guard !stale.isEmpty else { return }
        let loaded: [UUID: Meeting] = Dictionary(uniqueKeysWithValues: stale.compactMap { meeting in
            transcripts[meeting.id].map { _ in (meeting.id, withTranscript(meeting)) }
        })
        DispatchQueue.concurrentPerform(iterations: stale.count) { i in
            let id = stale[i].id
            if let full = loaded[id] {
                if !TranscriptSearchText.isFresh(id) { TranscriptSearchText.write(full) }
            } else {
                TranscriptSearchText.ensure(id)
            }
        }
        searchTextFresh.formUnion(stale.map(\.id))
    }

    /// Builds any missing or stale search text in the background, so the first
    /// search after launch — or after upgrading to a build that keeps it — does
    /// not stop to read every transcript. After the first time, launches find
    /// the files current and this only checks dates.
    func prewarmSearchText() {
        let ids = meetings.filter(\.hasTranscript).map(\.id)
        guard !ids.isEmpty else { return }
        // GCD rather than a detached Task: this blocks on file reads for as
        // long as it takes, which the Swift concurrency pool must not.
        DispatchQueue.global(qos: .utility).async {
            let began = Date()
            for id in ids { TranscriptSearchText.ensure(id) }
            Log.info("Search text checked for \(ids.count) meetings in \(Int(Date().timeIntervalSince(began) * 1000))ms")
        }
    }
}
