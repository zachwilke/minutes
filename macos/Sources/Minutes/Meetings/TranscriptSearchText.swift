import Foundation

/// A lowercased plain-text copy of each meeting's transcript, kept on disk for
/// search so the transcripts themselves need not stay in memory.
///
/// One file per meeting under `AppPaths.searchTextRoot`, outside the meeting
/// folders, so the storage format is untouched and Windows never sees it. It is
/// derived data: a file older than its `meeting.json` is stale and rebuilt, and
/// deleting the folder only costs a rebuild. Searching memory-maps each file,
/// so the text lives in the page cache — memory the system reclaims whenever it
/// needs to — rather than in the app's own footprint.
enum TranscriptSearchText {
    static func file(for id: UUID) -> URL {
        AppPaths.searchTextRoot.appendingPathComponent("\(id.uuidString).txt")
    }

    /// True when the file was built from the `meeting.json` now on disk. Each
    /// file is stamped with its source's modification date, so a meeting saved
    /// since — by this app, or by the Windows app on a shared library — has a
    /// newer date and its text is rebuilt.
    static func isFresh(_ id: UUID) -> Bool {
        guard let built = modificationTime(of: file(for: id)),
              let source = sourceDate(id) else { return false }
        return (built.tv_sec, built.tv_nsec) >= (source.tv_sec, source.tv_nsec)
    }

    private static func sourceDate(_ id: UUID) -> timespec? {
        modificationTime(of: AppPaths.meetingDir(id).appendingPathComponent("meeting.json"))
    }

    /// Exact, as the file system stores it. Through `Date` — a Double — the
    /// nanoseconds round, and a copied stamp could read back as older than
    /// the date it was copied from.
    private static func modificationTime(of url: URL) -> timespec? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_mtimespec
    }

    /// The text search matches against.
    static func text(of meeting: Meeting) -> String {
        precondition(meeting.transcriptLoaded, "search text needs the full transcript")
        return meeting.transcriptText.lowercased()
    }

    /// Writes the search text for a meeting whose transcript is loaded and
    /// matches its `meeting.json`.
    static func write(_ meeting: Meeting) {
        write(meeting, source: sourceDate(meeting.id))
    }

    /// `source` is the date of the `meeting.json` the meeting was read from,
    /// taken before reading it: if the file changes in between, the text is
    /// stamped older than it and so is rebuilt next time, never trusted.
    private static func write(_ meeting: Meeting, source: timespec?) {
        let url = file(for: meeting.id)
        do {
            try FileManager.default.createDirectory(at: AppPaths.searchTextRoot, withIntermediateDirectories: true)
            try Data(text(of: meeting).utf8).write(to: url, options: .atomic)
            if let source {
                // Access time left alone; modification time set to the source's.
                let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), source]
                guard utimensat(AT_FDCWD, url.path, times, 0) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        } catch {
            Log.warn("Could not write search text for \(meeting.id): \(error.localizedDescription)")
        }
    }

    /// Rebuilds the file from `meeting.json` unless it is already fresh.
    static func ensure(_ id: UUID) {
        guard !isFresh(id) else { return }
        let source = sourceDate(id)
        guard let meeting = MeetingStore.loadMeeting(id: id) else { return }
        write(meeting, source: source)
    }

    /// The lowercased transcript, rebuilding the file first if it is stale.
    static func lowercasedText(for id: UUID) -> String {
        ensure(id)
        return (try? String(contentsOf: file(for: id), encoding: .utf8)) ?? ""
    }

    /// Whether the meeting's search text contains `needle` (lowercased UTF-8).
    /// The file must already be fresh; see `ensure`.
    static func contains(_ needle: [UInt8], in id: UUID) -> Bool {
        guard !needle.isEmpty,
              let data = try? Data(contentsOf: file(for: id), options: .alwaysMapped) else { return false }
        return data.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { n in
                guard let base = haystack.baseAddress, let nBase = n.baseAddress else { return false }
                return memmem(base, haystack.count, nBase, n.count) != nil
            }
        }
    }

    static func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }
}

extension Array where Element == UInt8 {
    /// Byte-wise substring search; `memmem` rather than `String.contains`,
    /// which compares by grapheme and is two orders of magnitude slower.
    func contains(bytes needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        return withUnsafeBytes { haystack in
            needle.withUnsafeBytes { n in
                guard let base = haystack.baseAddress, let nBase = n.baseAddress else { return false }
                return memmem(base, haystack.count, nBase, n.count) != nil
            }
        }
    }
}
