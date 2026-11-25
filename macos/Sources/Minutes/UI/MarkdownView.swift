import SwiftUI
import AppKit

/// Written notes and Ask answers, rendered from Markdown.
///
/// One text view, not a stack of them. SwiftUI's text selection stops at the
/// edge of each Text, so with a Text per heading, paragraph and bullet you
/// could highlight inside one bullet but never drag across a section to copy
/// it. Here the whole document is one attributed string in a read-only
/// NSTextView: select any stretch — a line, a section, all of it — and ⌘C
/// copies it as rich text (headings, bullets and tables survive a paste into
/// Outlook or Teams) and as plain text. Links stay clickable.
struct MarkdownView: NSViewRepresentable, Equatable {
    let markdown: String

    /// With `.equatable()` at the call site, SwiftUI skips the update — and the
    /// whole parse — whenever the text has not changed.
    static func == (lhs: MarkdownView, rhs: MarkdownView) -> Bool {
        lhs.markdown == rhs.markdown
    }

    final class Coordinator {
        var shown: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NotesTextView {
        let view = NotesTextView()
        show(in: view, context: context)
        return view
    }

    func updateNSView(_ view: NotesTextView, context: Context) {
        show(in: view, context: context)
    }

    private func show(in view: NotesTextView, context: Context) {
        guard context.coordinator.shown != markdown else { return }
        context.coordinator.shown = markdown
        view.textStorage?.setAttributedString(MarkdownText.attributed(markdown))
        view.invalidateIntrinsicContentSize()
    }

    /// As tall as the text is at the width offered, so it sits in a scrolling
    /// page like any other view instead of scrolling inside itself.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NotesTextView, context: Context) -> CGSize? {
        let offered = proposal.width ?? 600
        let width = offered.isFinite && offered > 0 ? offered : 600
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

/// A read-only, selectable text view that draws nothing behind its text.
final class NotesTextView: NSTextView {
    init() {
        // TextKit 1, for the layout manager `sizeThatFits` measures with, and
        // for NSTextTable, which draws the action-item tables.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.foregroundColor: Palette.NS.ink,
                              .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .cursor: NSCursor.pointingHand]
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }
}

/// Markdown blocks into one attributed string, styled like the page around it:
/// 15 pt body with 6 pt leading, headings set apart by size and space rather
/// than colour, bullets with a hanging indent, tables as real tables.
enum MarkdownText {
    static let bodySize: CGFloat = 15
    static let lineSpacing: CGFloat = 6
    static let indentStep: CGFloat = 18

    static func attributed(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let blocks = MarkdownBlock.parse(markdown)
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            let next = isLast ? nil : blocks[index + 1]
            append(block, next: next, to: out)
        }
        // No trailing paragraph break, or the view would end in an empty line.
        while out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private static func isListItem(_ block: MarkdownBlock?) -> Bool {
        switch block {
        case .bullet, .numbered: return true
        default: return false
        }
    }

    private static func append(_ block: MarkdownBlock, next: MarkdownBlock?, to out: NSMutableAttributedString) {
        // Items of one list sit closer together than paragraphs do.
        let after: CGFloat = isListItem(next) && isListItem(block) ? 6 : 12

        switch block {
        case .heading(let level, let text):
            let size: CGFloat = level <= 1 ? 21 : (level == 2 ? 17 : 15)
            let style = paragraph(spacing: 6, before: level <= 2 ? 14 : 6)
            out.append(inline(text, font: .systemFont(ofSize: size, weight: .semibold), style: style))
            out.append(newline(style))

        case .paragraph(let text):
            let style = paragraph(spacing: after)
            out.append(inline(text, font: body, style: style))
            out.append(newline(style))

        case .bullet(let indent, let text):
            appendListItem(marker: indent > 0 ? "◦" : "•", indent: indent, text: text, after: after, to: out)

        case .numbered(let indent, let marker, let text):
            appendListItem(marker: marker, indent: indent, text: text, after: after, to: out)

        case .table(let headers, let rows):
            appendTable(headers: headers, rows: rows, to: out)

        case .code(let lines):
            let block = NSTextBlock()
            block.backgroundColor = Palette.NS.fill
            block.setWidth(10, type: .absoluteValueType, for: .padding)
            let style = paragraph(spacing: 12)
            style.textBlocks = [block]
            style.lineSpacing = 2
            out.append(NSAttributedString(string: lines.joined(separator: "\u{2028}") + "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: Palette.NS.ink,
                .paragraphStyle: style
            ]))

        case .rule:
            let block = NSTextBlock()
            block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .maxY)
            block.setBorderColor(Palette.NS.hairline, for: .maxY)
            let style = paragraph(spacing: 12)
            style.textBlocks = [block]
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4),
                                                                     .paragraphStyle: style]))
        }
    }

    private static func appendListItem(marker: String, indent: Int, text: String, after: CGFloat,
                                       to out: NSMutableAttributedString) {
        let lead = CGFloat(indent) * indentStep
        let style = paragraph(spacing: after)
        style.firstLineHeadIndent = lead
        style.headIndent = lead + indentStep + 4
        style.tabStops = [NSTextTab(textAlignment: .left, location: lead + indentStep + 4)]
        let item = NSMutableAttributedString(string: marker + "\t", attributes: [
            .font: body, .foregroundColor: Palette.NS.inkTertiary, .paragraphStyle: style
        ])
        item.append(inline(text, font: body, style: style))
        item.append(newline(style))
        out.append(item)
    }

    /// A real table: copies into a document or an email as one.
    private static func appendTable(headers: [String], rows: [[String]], to out: NSMutableAttributedString) {
        let table = NSTextTable()
        table.numberOfColumns = max(1, headers.count)
        table.collapsesBorders = true
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        for (rowIndex, cells) in ([headers] + rows).enumerated() {
            for (column, cell) in cells.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(Palette.NS.hairline)
                block.setWidth(8, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 { block.backgroundColor = Palette.NS.fill }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let font: NSFont = rowIndex == 0 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 13)
                let color = rowIndex == 0 ? Palette.NS.inkSecondary : Palette.NS.ink
                let text = NSMutableAttributedString(attributedString: inline(cell, font: font, style: style))
                text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.length))
                out.append(text)
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: font]))
            }
        }
        // Space after the table, outside it.
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 6),
                                                                 .paragraphStyle: paragraph(spacing: 0)]))
    }

    private static var body: NSFont { .systemFont(ofSize: bodySize) }

    private static func paragraph(spacing: CGFloat, before: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = before
        return style
    }

    private static func newline(_ style: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: style])
    }

    /// Bold, italic, inline code and links inside one block.
    static func inline(_ text: String, font: NSFont, style: NSParagraphStyle) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: text,
                                            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                runFont = .monospacedSystemFont(ofSize: font.pointSize - 1.5, weight: .regular)
            } else {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    runFont = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont, .foregroundColor: Palette.NS.ink, .paragraphStyle: style
            ]
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }
}

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, text: String)
    case numbered(indent: Int, marker: String, text: String)
    case table(headers: [String], rows: [[String]])
    case code([String])
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        let lines = markdown.components(separatedBy: .newlines)
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            // Fenced code
            if line.hasPrefix("```") {
                flushParagraph()
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(body))
                continue
            }

            // Table: a pipe row followed by a |---|---| separator
            if line.hasPrefix("|"), index + 1 < lines.count,
               isSeparatorRow(lines[index + 1]) {
                flushParagraph()
                let headers = cells(from: line)
                var rows: [[String]] = []
                index += 2
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(from: lines[index]))
                    index += 1
                }
                // Pad short rows so columns stay aligned.
                let width = max(headers.count, rows.map(\.count).max() ?? 0)
                blocks.append(.table(headers: pad(headers, to: width),
                                     rows: rows.map { pad($0, to: width) }))
                continue
            }

            if line.hasPrefix("#") {
                flushParagraph()
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(level, 4), text: text))
                index += 1
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            let indent = indentLevel(of: raw)

            if let marker = line.first, marker == "-" || marker == "*" || marker == "+",
               line.count > 1, line[line.index(line.startIndex, offsetBy: 1)] == " " {
                flushParagraph()
                blocks.append(.bullet(indent: indent,
                                      text: String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            if let match = numberedPrefix(line) {
                flushParagraph()
                blocks.append(.numbered(indent: indent, marker: match.marker, text: match.text))
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func pad(_ row: [String], to width: Int) -> [String] {
        row.count >= width ? row : row + Array(repeating: "", count: width - row.count)
    }

    private static func indentLevel(of line: String) -> Int {
        let spaces = line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return min(spaces / 2, 3)
    }

    private static func isSeparatorRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) } && trimmed.contains("-")
    }

    private static func cells(from line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func numberedPrefix(_ line: String) -> (marker: String, text: String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (marker: "\(digits).", text: String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }
}
