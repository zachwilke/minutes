import Foundation

/// A summary style. `instructions` becomes the shape of the requested output, so
/// adding a template is a matter of describing the sections you want.
struct SummaryTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let blurb: String
    let instructions: String

    /// Built from shared/prompts/summary.json via the generated table, so the
    /// Windows port offers the same styles with the same wording.
    static let builtIn: [SummaryTemplate] = SharedPrompts.Summary.templates.map {
        SummaryTemplate(id: $0.id, name: $0.name, blurb: $0.blurb, instructions: $0.instructions)
    }

    /// Built-in styles, then the user's own.
    static var all: [SummaryTemplate] {
        builtIn + CustomTemplates.Snapshot.entries.map {
            SummaryTemplate(id: $0.id, name: $0.name, blurb: $0.blurb, instructions: $0.instructions)
        }
    }

    var isCustom: Bool { id.hasPrefix("custom-") }

    /// A deleted custom style falls back to General rather than failing.
    static func named(_ id: String) -> SummaryTemplate {
        all.first { $0.id == id } ?? builtIn.first { $0.id == "general" } ?? builtIn[0]
    }

    /// Convenience handles for the styles the code refers to by name.
    static var general: SummaryTemplate { named("general") }
    static var clientCall: SummaryTemplate { named("client-call") }
    static var discovery: SummaryTemplate { named("discovery") }
    static var troubleshooting: SummaryTemplate { named("troubleshooting") }
    static var oneOnOne: SummaryTemplate { named("one-on-one") }
    static var standup: SummaryTemplate { named("standup") }
}
