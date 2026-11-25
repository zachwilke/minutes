import Foundation

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var date: Date = Date()
    /// Meetings whose content was put in front of Claude for this answer, so the
    /// UI can show what the reply was actually based on.
    var groundedIn: [UUID] = []
    /// Set when the request failed, so a failure reads differently from an answer.
    var isError: Bool = false
}

extension ChatMessage.Role {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatMessage.Role(rawValue: raw) ?? .assistant
    }
}

extension ChatMessage {
    /// Missing keys fall back to defaults — the synthesized decoder failed on
    /// them, and a failed decode used to wipe the whole history on next send.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .assistant
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        groundedIn = try c.decodeIfPresent([UUID].self, forKey: .groundedIn) ?? []
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
    }
}
