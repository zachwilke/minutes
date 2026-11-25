import Foundation
import Combine

/// Owns the conversation and drives Claude.
///
/// Lives at app level rather than inside the chat view, so navigating away to a
/// meeting mid-answer does not abandon the request or lose the reply.
@MainActor
final class ChatController: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isResponding = false

    private let archive: ChatArchive
    private let service = MeetingChatService()
    private let meetings: MeetingStore
    /// The meeting this conversation is about, or nil for the whole library.
    let scope: UUID?
    private var task: Task<Void, Never>?
    /// The id of the assistant message the in-flight request owns. Cancelling
    /// kills the claude subprocess, but a reply already on its way back can
    /// still arrive; without this check it would land in whatever bubble
    /// happened to be last, including a NEWER question's.
    private var inFlightMessageID: UUID?

    init(meetings: MeetingStore, scope: UUID? = nil) {
        self.meetings = meetings
        self.scope = scope
        // A meeting's own conversation lives in its folder, so deleting the
        // meeting deletes it too.
        self.archive = ChatArchive(file: scope.map { AppPaths.meetingDir($0).appendingPathComponent("chat.json") }
                                   ?? AppPaths.supportRoot.appendingPathComponent("chat.json"))
        messages = archive.load()
    }

    var canSend: Bool { !isResponding }

    func send(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }

        // History as it stood before this question, which is what Claude should
        // see — the new question is presented separately.
        let history = messages
        messages.append(ChatMessage(role: .user, text: trimmed))
        let placeholder = ChatMessage(role: .assistant, text: "")
        messages.append(placeholder)
        inFlightMessageID = placeholder.id
        archive.save(messages)
        isResponding = true

        let owner = placeholder.id
        task = Task { [weak self] in
            guard let self else { return }
            // Index copies: the context builder reads each transcript from
            // disk as it needs it, off the main thread.
            let library = self.meetings.meetings

            do {
                let answer = try await service.ask(
                    question: trimmed,
                    history: history,
                    meetings: library,
                    focus: self.scope,
                    onDelta: { [weak self] partial in
                        Task { @MainActor in self?.updateStreaming(partial, owner: owner) }
                    })
                self.finish(text: answer.text, groundedIn: answer.groundedIn, isError: false, owner: owner)
            } catch {
                Log.error("Chat failed: \(error.localizedDescription)")
                self.finish(text: error.localizedDescription, groundedIn: [], isError: true, owner: owner)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        // Disown the request: an answer already in flight must be dropped rather
        // than delivered into whatever is last by then.
        inFlightMessageID = nil
        guard isResponding else { return }
        isResponding = false
        // Keep whatever streamed in; discard an entirely empty reply.
        if let last = messages.last, last.role == .assistant,
           last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.removeLast()
        }
        archive.save(messages)
    }

    func clear() {
        cancel()
        messages.removeAll()
        archive.save(messages)
    }

    /// Streaming rewrites the trailing assistant message. Not saved per token —
    /// that would be a disk write per delta.
    private func updateStreaming(_ text: String, owner: UUID) {
        guard inFlightMessageID == owner,
              let index = messages.lastIndex(where: { $0.id == owner }) else { return }
        messages[index].text = text
    }

    private func finish(text: String, groundedIn: [UUID], isError: Bool, owner: UUID) {
        guard inFlightMessageID == owner else { return }   // cancelled or superseded
        inFlightMessageID = nil
        if let index = messages.lastIndex(where: { $0.id == owner }) {
            messages[index].text = text
            messages[index].groundedIn = groundedIn
            messages[index].isError = isError
        }
        isResponding = false
        task = nil
        archive.save(messages)
    }

    /// Titles for the meetings an answer drew on, for the "based on" line.
    func groundingTitles(for message: ChatMessage) -> [String] {
        message.groundedIn.compactMap { id in
            meetings.meeting(id: id).map(\.displayTitle)
        }
    }
}

/// Reads and writes the conversation. Deliberately not observable: the
/// controller is the single publisher, which keeps SwiftUI updates simple.
private struct ChatArchive {
    let file: URL

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func load() -> [ChatMessage] {
        AppPaths.ensureDirectories()
        guard let data = try? Data(contentsOf: file) else { return [] }
        do {
            return try decoder.decode([ChatMessage].self, from: data)
        } catch {
            // Set the unreadable file aside: returning an empty history meant the
            // next question overwrote it, and the conversation was gone for good.
            let aside = file.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            Log.warn("Could not read chat history (kept as \(aside.lastPathComponent)): \(error.localizedDescription)")
            return []
        }
    }

    func save(_ messages: [ChatMessage]) {
        // A meeting deleted mid-conversation must not get its folder back.
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        do {
            try encoder.encode(messages).write(to: file, options: .atomic)
        } catch {
            Log.error("Could not save chat history: \(error.localizedDescription)")
        }
    }
}

/// One conversation per meeting, created on first use and kept for the session,
/// so leaving a meeting mid-answer neither abandons the request nor loses it.
@MainActor
final class MeetingChats: ObservableObject {
    private let meetings: MeetingStore
    private var controllers: [UUID: ChatController] = [:]

    init(meetings: MeetingStore) {
        self.meetings = meetings
    }

    func controller(for meetingID: UUID) -> ChatController {
        if let existing = controllers[meetingID] { return existing }
        let created = ChatController(meetings: meetings, scope: meetingID)
        controllers[meetingID] = created
        return created
    }
}
