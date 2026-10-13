// BTT-Plugin-Name: Apple Notes
// BTT-Plugin-Identifier: com.folivora.btt.launcher.applenotes
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: note.text
// BTT-Principal-Class: AppleNotesLauncherPlugin

import AppKit
import Foundation
import SQLite3
import SwiftUI
import UniformTypeIdentifiers

// Apple Notes for the BetterTouchTool launcher.
//
// Search, preview and Markdown export read Notes' local database
// (~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite) strictly
// read-only and decode the note format directly, so results are instant and
// include tables, checklists and tags. This requires Full Disk Access for
// BetterTouchTool. The plugin never writes to that database: creating,
// appending, moving and deleting notes goes through Notes' AppleScript
// interface, so Notes itself performs every change and syncs it.

// MARK: - Apple Notes Engine
// Foundation + SQLite only. Tests/run-tests.py compiles this section standalone.

struct NotesProtoField {
    let number: Int
    let wireType: Int
    let value: UInt64
    let bytes: ArraySlice<UInt8>

    var int: Int { Int(truncatingIfNeeded: Int64(bitPattern: value)) }
    var bool: Bool { value != 0 }
    var string: String { String(decoding: bytes, as: UTF8.self) }
    var message: NotesProtoMessage { NotesProtoMessage(bytes) }
}

/// Minimal protobuf wire-format reader. Notes stores note bodies and table
/// contents as gzipped protobuf messages.
struct NotesProtoMessage {
    let bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }
    init(_ bytes: [UInt8]) { self.bytes = bytes[...] }

    /// Visits fields in order until `body` returns false.
    /// Returns false when the buffer is malformed.
    @discardableResult
    func forEachField(_ body: (NotesProtoField) -> Bool) -> Bool {
        var index = bytes.startIndex
        let end = bytes.endIndex
        let empty = bytes[end..<end]
        while index < end {
            guard let key = Self.readVarint(bytes, &index) else { return false }
            let number = Int(truncatingIfNeeded: key >> 3)
            let wireType = Int(key & 7)
            let field: NotesProtoField
            switch wireType {
            case 0:
                guard let value = Self.readVarint(bytes, &index) else { return false }
                field = NotesProtoField(number: number, wireType: 0, value: value, bytes: empty)
            case 1, 5:
                let width = wireType == 1 ? 8 : 4
                guard end - index >= width else { return false }
                var value: UInt64 = 0
                for offset in 0..<width {
                    value |= UInt64(bytes[index + offset]) << UInt64(8 * offset)
                }
                index += width
                field = NotesProtoField(number: number, wireType: wireType, value: value, bytes: empty)
            case 2:
                guard let length = Self.readVarint(bytes, &index), length <= UInt64(end - index) else { return false }
                let payloadEnd = index + Int(length)
                field = NotesProtoField(number: number, wireType: 2, value: length, bytes: bytes[index..<payloadEnd])
                index = payloadEnd
            default:
                return false
            }
            if !body(field) { return true }
        }
        return true
    }

    /// All fields, or nil when the buffer is malformed.
    func fields() -> [NotesProtoField]? {
        var result: [NotesProtoField] = []
        let valid = forEachField { field in
            result.append(field)
            return true
        }
        return valid ? result : nil
    }

    func first(_ number: Int) -> NotesProtoField? {
        var match: NotesProtoField?
        forEachField { field in
            guard field.number == number else { return true }
            match = field
            return false
        }
        return match
    }

    func all(_ number: Int) -> [NotesProtoField] {
        var matches: [NotesProtoField] = []
        forEachField { field in
            if field.number == number { matches.append(field) }
            return true
        }
        return matches
    }

    private static func readVarint(_ bytes: ArraySlice<UInt8>, _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            if shift < 64 { value |= UInt64(byte & 0x7f) << shift }
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift >= 70 { return nil }
        }
        return nil
    }
}

enum NotesCompression {
    /// Inflates gzip, zlib or raw deflate data.
    static func inflate(_ data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count > 2 else { return nil }
        var start = 0
        var end = bytes.count
        if bytes[0] == 0x1f, bytes[1] == 0x8b {
            guard bytes.count > 18, bytes[2] == 8 else { return nil }
            let flags = bytes[3]
            start = 10
            if flags & 0x04 != 0 {
                guard start + 2 <= bytes.count else { return nil }
                start += 2 + (Int(bytes[start]) | Int(bytes[start + 1]) << 8)
            }
            if flags & 0x08 != 0 { start = skipZeroTerminated(bytes, from: start) }
            if flags & 0x10 != 0 { start = skipZeroTerminated(bytes, from: start) }
            if flags & 0x02 != 0 { start += 2 }
            end = bytes.count - 8
        } else if bytes[0] & 0x0f == 8, (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 {
            start = 2
            end = bytes.count - 4
        }
        guard start < end,
              let inflated = try? (Data(bytes[start..<end]) as NSData).decompressed(using: .zlib) else {
            return nil
        }
        return [UInt8](inflated as Data)
    }

    private static func skipZeroTerminated(_ bytes: [UInt8], from index: Int) -> Int {
        var cursor = index
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        return cursor + 1
    }
}

struct NotesParagraphStyle: Equatable {
    static let body = -1
    static let title = 0
    static let heading = 1
    static let subheading = 2
    static let monospaced = 4
    static let bulleted = 100
    static let dashed = 101
    static let numbered = 102
    static let checklist = 103

    var styleType = NotesParagraphStyle.body
    var indent = 0
    var isChecked = false
    var isBlockQuote = false
    var listStartNumber: Int?

    var isList: Bool { styleType >= NotesParagraphStyle.bulleted && styleType <= NotesParagraphStyle.checklist }
    var isHeading: Bool {
        styleType == NotesParagraphStyle.title || styleType == NotesParagraphStyle.heading || styleType == NotesParagraphStyle.subheading
    }
}

struct NotesTextRun: Equatable {
    var length = 0
    var paragraphStyle: NotesParagraphStyle?
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var isStrikethrough = false
    var link: String?
    var highlight: Int?
    var attachmentIdentifier: String?
    var attachmentUTI: String?

    func hasSameInlineStyle(as other: NotesTextRun) -> Bool {
        attachmentIdentifier == nil && other.attachmentIdentifier == nil
            && isBold == other.isBold && isItalic == other.isItalic
            && isUnderlined == other.isUnderlined && isStrikethrough == other.isStrikethrough
            && link == other.link && highlight == other.highlight
    }
}

/// Note text plus attribute runs. Run lengths count UTF-16 code units.
struct NotesDocument {
    var text: String
    var runs: [NotesTextRun]
}

enum NotesDocumentDecoder {
    static func plainText(fromCompressed data: Data) -> String? {
        guard let bytes = NotesCompression.inflate(data), let note = noteMessage(in: bytes) else { return nil }
        guard let text = note.first(2), text.wireType == 2 else { return nil }
        return text.string
    }

    static func document(fromCompressed data: Data) -> NotesDocument? {
        guard let bytes = NotesCompression.inflate(data), let note = noteMessage(in: bytes) else { return nil }
        return document(from: note)
    }

    /// NoteStoreProto.document (2) -> Document.note (3).
    static func noteMessage(in bytes: [UInt8]) -> NotesProtoMessage? {
        guard let document = NotesProtoMessage(bytes).first(2), document.wireType == 2,
              let note = document.message.first(3), note.wireType == 2 else { return nil }
        return note.message
    }

    static func document(from note: NotesProtoMessage) -> NotesDocument? {
        var text: String?
        var runs: [NotesTextRun] = []
        let valid = note.forEachField { field in
            switch (field.number, field.wireType) {
            case (2, 2): text = field.string
            case (5, 2): runs.append(run(from: field.message))
            default: break
            }
            return true
        }
        guard valid, let text else { return nil }
        return NotesDocument(text: text, runs: runs)
    }

    static func run(from message: NotesProtoMessage) -> NotesTextRun {
        var run = NotesTextRun()
        message.forEachField { field in
            switch (field.number, field.wireType) {
            case (1, 0):
                run.length = max(0, field.int)
            case (2, 2):
                run.paragraphStyle = paragraphStyle(from: field.message)
            case (5, 0):
                run.isBold = field.value == 1 || field.value == 3
                run.isItalic = field.value == 2 || field.value == 3
            case (6, 0):
                run.isUnderlined = field.value != 0
            case (7, 0):
                run.isStrikethrough = field.value != 0
            case (9, 2):
                run.link = field.string
            case (12, 2):
                run.attachmentIdentifier = field.message.first(1)?.string
                run.attachmentUTI = field.message.first(2)?.string
            case (14, 0):
                run.highlight = field.int
            default:
                break
            }
            return true
        }
        return run
    }

    static func paragraphStyle(from message: NotesProtoMessage) -> NotesParagraphStyle {
        var style = NotesParagraphStyle()
        message.forEachField { field in
            switch (field.number, field.wireType) {
            case (1, 0): style.styleType = field.int
            case (4, 0): style.indent = min(max(field.int, 0), 12)
            case (5, 2): style.isChecked = field.message.first(2)?.bool ?? false
            case (7, 0): style.listStartNumber = field.int
            case (8, 0): style.isBlockQuote = field.value != 0
            default: break
            }
            return true
        }
        return style
    }
}

struct NotesInlineSegment {
    var text: String
    var run: NotesTextRun
}

struct NotesParagraph {
    var style: NotesParagraphStyle
    var segments: [NotesInlineSegment]

    var text: String { segments.map(\.text).joined() }
}

enum NotesDocumentLayout {
    static let attachmentCharacter: Character = "\u{FFFC}"

    /// Splits a document into paragraphs. The paragraph style is carried by
    /// the run that contains the paragraph's newline.
    static func paragraphs(of document: NotesDocument) -> [NotesParagraph] {
        let units = Array(document.text.utf16)
        var runs = document.runs
        let covered = runs.reduce(0) { $0 + $1.length }
        if covered < units.count {
            runs.append(NotesTextRun(length: units.count - covered))
        }

        var paragraphs: [NotesParagraph] = []
        var segments: [NotesInlineSegment] = []
        var pendingStyle: NotesParagraphStyle?
        var cursor = 0

        func appendSegment(_ start: Int, _ end: Int, _ run: NotesTextRun) {
            guard start < end else { return }
            var text = String(decoding: units[start..<end], as: UTF16.self)
            // Object characters without attachment info are leftovers of removed attachments.
            if run.attachmentIdentifier == nil, text.contains(attachmentCharacter) {
                text.removeAll { $0 == attachmentCharacter }
            }
            if pendingStyle == nil { pendingStyle = run.paragraphStyle }
            guard !text.isEmpty else { return }
            segments.append(NotesInlineSegment(text: text, run: run))
        }

        for run in runs where cursor < units.count {
            let runEnd = min(units.count, cursor + run.length)
            var pieceStart = cursor
            var index = cursor
            while index < runEnd {
                if units[index] == 0x0A {
                    appendSegment(pieceStart, index, run)
                    let style = run.paragraphStyle ?? pendingStyle ?? NotesParagraphStyle()
                    paragraphs.append(NotesParagraph(style: style, segments: segments))
                    segments = []
                    pendingStyle = nil
                    pieceStart = index + 1
                }
                index += 1
            }
            appendSegment(pieceStart, runEnd, run)
            cursor = runEnd
        }
        if !segments.isEmpty {
            paragraphs.append(NotesParagraph(style: pendingStyle ?? NotesParagraphStyle(), segments: segments))
        }
        return paragraphs
    }
}

enum NotesAttachmentKind: String {
    case image, table, link, drawing, audio, scan, file, hashtag, mention, inline

    private static var cache: [String: NotesAttachmentKind] = [:]
    private static let cacheLock = NSLock()

    static func classify(uti: String) -> NotesAttachmentKind {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[uti] { return cached }
        let kind = uncachedKind(uti: uti)
        cache[uti] = kind
        return kind
    }

    private static func uncachedKind(uti: String) -> NotesAttachmentKind {
        switch uti {
        case "com.apple.notes.table": return .table
        case "public.url": return .link
        case "com.apple.drawing", "com.apple.drawing.2", "com.apple.paper", "com.apple.notes.sketch": return .drawing
        case "com.apple.notes.gallery", "com.apple.paper.doc.scan": return .scan
        case "com.apple.notes.inlinetextattachment.hashtag": return .hashtag
        case "com.apple.notes.inlinetextattachment.mention": return .mention
        default: break
        }
        if uti.hasPrefix("com.apple.notes.inlinetextattachment") { return .inline }
        if let type = UTType(uti) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
        }
        return .file
    }

    var isInline: Bool { self == .hashtag || self == .mention || self == .inline }

    var displayName: String {
        switch self {
        case .image: return "Image"
        case .table: return "Table"
        case .link: return "Link"
        case .drawing: return "Drawing"
        case .audio: return "Audio Recording"
        case .scan: return "Scanned Document"
        case .file: return "File"
        case .hashtag: return "Tag"
        case .mention: return "Mention"
        case .inline: return "Inline Item"
        }
    }
}

struct NotesAttachment {
    var identifier: String
    var uti: String
    var kind: NotesAttachmentKind
    var title: String?
    var urlString: String?
    var fileURL: URL?
    var previewImageURL: URL?
    var altText: String?
    var tableRows: [[String]]?

    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let fileURL { return fileURL.lastPathComponent }
        return kind.displayName
    }
}

/// Decodes the CRDT document Notes uses for table attachments into rows.
enum NotesTableDecoder {
    static func rows(fromCompressed data: Data) -> [[String]]? {
        guard let bytes = NotesCompression.inflate(data),
              let object = NotesProtoMessage(bytes).first(2)?.message,
              let objectData = object.first(3)?.message else { return nil }

        var entries: [NotesProtoMessage] = []
        var keys: [String] = []
        var types: [String] = []
        var uuidIndex: [[UInt8]: Int] = [:]
        var uuidCount = 0
        let valid = objectData.forEachField { field in
            switch (field.number, field.wireType) {
            case (3, 2): entries.append(field.message)
            case (4, 2): keys.append(field.string)
            case (5, 2): types.append(field.string)
            case (6, 2):
                let uuid = Array(field.bytes)
                if uuidIndex[uuid] == nil { uuidIndex[uuid] = uuidCount }
                uuidCount += 1
            default: break
            }
            return true
        }
        guard valid else { return nil }

        func entry(_ reference: NotesProtoField?) -> NotesProtoMessage? {
            guard let reference, let index = reference.message.first(6)?.int, entries.indices.contains(index) else { return nil }
            return entries[index]
        }
        func uuidPosition(of entry: NotesProtoMessage?) -> Int? {
            entry?.first(13)?.message.first(3)?.message.first(2)?.message.first(2)?.int
        }

        guard let tableMap = entries.lazy.compactMap({ candidate -> NotesProtoMessage? in
            guard let map = candidate.first(13)?.message, let type = map.first(1)?.int,
                  types.indices.contains(type), types[type] == "com.apple.notes.ICTable" else { return nil }
            return map
        }).first else { return nil }

        var references: [String: NotesProtoField] = [:]
        for mapEntry in tableMap.all(3) {
            let message = mapEntry.message
            guard let key = message.first(1)?.int, keys.indices.contains(key), let value = message.first(2) else { continue }
            references[keys[key]] = value
        }

        func ordering(_ key: String) -> (positions: [Int: Int], count: Int)? {
            guard let set = entry(references[key])?.first(16)?.message,
                  let ordering = set.first(1)?.message else { return nil }
            var positions: [Int: Int] = [:]
            var count = 0
            if let array = ordering.first(1)?.message {
                for attachment in array.all(2) {
                    if let uuid = attachment.message.first(2)?.bytes, let index = uuidIndex[Array(uuid)] {
                        positions[index] = count
                    }
                    count += 1
                }
            }
            if let contents = ordering.first(2)?.message {
                for element in contents.all(1) {
                    let message = element.message
                    if let key = uuidPosition(of: entry(message.first(1))),
                       let value = uuidPosition(of: entry(message.first(2))),
                       let position = positions[key] {
                        positions[value] = position
                    }
                }
            }
            return (positions, count)
        }

        guard let rows = ordering("crRows"), let columns = ordering("crColumns"),
              rows.count > 0, columns.count > 0, rows.count * columns.count <= 200_000 else { return nil }

        var grid = Array(repeating: Array(repeating: "", count: columns.count), count: rows.count)
        guard let cellColumns = entry(references["cellColumns"])?.first(6)?.message else { return grid }
        for column in cellColumns.all(1) {
            let columnMessage = column.message
            guard let columnUUID = uuidPosition(of: entry(columnMessage.first(1))),
                  let columnPosition = columns.positions[columnUUID],
                  let rowsDictionary = entry(columnMessage.first(2))?.first(6)?.message else { continue }
            for row in rowsDictionary.all(1) {
                let rowMessage = row.message
                guard let rowUUID = uuidPosition(of: entry(rowMessage.first(1))),
                      let rowPosition = rows.positions[rowUUID],
                      let cell = entry(rowMessage.first(2)) else { continue }
                let text = cell.first(10)?.message.first(2)?.string ?? ""
                grid[rowPosition][columnPosition] = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return grid
    }
}

enum NotesMarkdownRenderer {
    static func markdown(of paragraphs: [NotesParagraph], attachments: [String: NotesAttachment]) -> String {
        var lines: [(text: String, verbatim: Bool)] = []
        var codeBlockOpen = false
        var numberCounters: [Int: Int] = [:]
        var previousWasList = false

        func blankLine() {
            if let last = lines.last, !last.text.isEmpty { lines.append(("", false)) }
        }

        for paragraph in paragraphs {
            let style = paragraph.style
            if style.styleType == NotesParagraphStyle.monospaced {
                if !codeBlockOpen {
                    blankLine()
                    lines.append(("```", true))
                    codeBlockOpen = true
                }
                lines.append((plainInlineText(paragraph.segments, attachments: attachments), true))
                previousWasList = false
                continue
            }
            if codeBlockOpen {
                lines.append(("```", true))
                lines.append(("", false))
                codeBlockOpen = false
            }
            if let rows = soleTableRows(in: paragraph, attachments: attachments) {
                blankLine()
                lines.append(contentsOf: tableLines(rows).map { ($0, true) })
                lines.append(("", false))
                numberCounters.removeAll()
                previousWasList = false
                continue
            }

            let content = inlineMarkdown(paragraph.segments, attachments: attachments)
            let indent = String(repeating: "    ", count: style.indent)
            var line: String
            switch style.styleType {
            case NotesParagraphStyle.title:
                line = content.isEmpty ? "" : "# " + content
            case NotesParagraphStyle.heading:
                line = content.isEmpty ? "" : "## " + content
            case NotesParagraphStyle.subheading:
                line = content.isEmpty ? "" : "### " + content
            case NotesParagraphStyle.bulleted, NotesParagraphStyle.dashed:
                line = indent + "- " + content
            case NotesParagraphStyle.numbered:
                let number = (numberCounters[style.indent] ?? ((style.listStartNumber ?? 1) - 1)) + 1
                numberCounters[style.indent] = number
                line = indent + "\(number). " + content
            case NotesParagraphStyle.checklist:
                line = indent + (style.isChecked ? "- [x] " : "- [ ] ") + content
            default:
                line = content
            }
            if style.styleType == NotesParagraphStyle.numbered {
                numberCounters = numberCounters.filter { $0.key <= style.indent }
            } else {
                // Outer numbered lists continue across nested items; anything else restarts them.
                numberCounters = numberCounters.filter { style.isList && $0.key < style.indent }
            }
            if style.isBlockQuote { line = "> " + line }

            if style.isHeading, !line.isEmpty {
                blankLine()
            } else if previousWasList, !style.isList, !line.isEmpty {
                blankLine()
            }
            lines.append((line, false))
            if style.isHeading, !line.isEmpty { lines.append(("", false)) }
            previousWasList = style.isList
        }
        if codeBlockOpen { lines.append(("```", true)) }

        var output: [String] = []
        for (text, verbatim) in lines {
            if verbatim {
                output.append(text)
                continue
            }
            let trimmed = text.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)
            if trimmed.isEmpty, output.last?.isEmpty ?? true { continue }
            output.append(trimmed)
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }

    static func plainText(of paragraphs: [NotesParagraph], attachments: [String: NotesAttachment]) -> String {
        var numberCounters: [Int: Int] = [:]
        let lines = paragraphs.map { paragraph -> String in
            let style = paragraph.style
            let text = plainInlineText(paragraph.segments, attachments: attachments)
            let indent = String(repeating: "\t", count: style.indent)
            if style.styleType != NotesParagraphStyle.numbered {
                numberCounters = numberCounters.filter { style.isList && $0.key < style.indent }
            }
            switch style.styleType {
            case NotesParagraphStyle.bulleted:
                return indent + "• " + text
            case NotesParagraphStyle.dashed:
                return indent + "– " + text
            case NotesParagraphStyle.numbered:
                let number = (numberCounters[style.indent] ?? ((style.listStartNumber ?? 1) - 1)) + 1
                numberCounters[style.indent] = number
                numberCounters = numberCounters.filter { $0.key <= style.indent }
                return indent + "\(number). " + text
            case NotesParagraphStyle.checklist:
                return indent + (style.isChecked ? "☑ " : "☐ ") + text
            default:
                return text
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func inlineMarkdown(_ segments: [NotesInlineSegment], attachments: [String: NotesAttachment]) -> String {
        var output = ""
        for segment in merged(segments) {
            if let identifier = segment.run.attachmentIdentifier {
                for character in segment.text {
                    if character == NotesDocumentLayout.attachmentCharacter {
                        output += attachmentMarkdown(attachments[identifier])
                    } else {
                        output.append(character)
                    }
                }
                continue
            }
            output += decorated(segment.text, run: segment.run)
        }
        return output
    }

    static func plainInlineText(_ segments: [NotesInlineSegment], attachments: [String: NotesAttachment]) -> String {
        var output = ""
        for segment in segments {
            guard let identifier = segment.run.attachmentIdentifier else {
                output += segment.text
                continue
            }
            for character in segment.text {
                if character == NotesDocumentLayout.attachmentCharacter {
                    output += attachmentPlainText(attachments[identifier])
                } else {
                    output.append(character)
                }
            }
        }
        return output
    }

    static func merged(_ segments: [NotesInlineSegment]) -> [NotesInlineSegment] {
        var result: [NotesInlineSegment] = []
        for segment in segments {
            if let last = result.last, last.run.hasSameInlineStyle(as: segment.run) {
                result[result.count - 1].text += segment.text
            } else {
                result.append(segment)
            }
        }
        return result
    }

    static func decorated(_ text: String, run: NotesTextRun) -> String {
        let isSpace: (Character) -> Bool = { character in
            character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
        }
        let leading = String(text.prefix(while: isSpace))
        guard leading.count < text.count else { return text }
        let trailing = String(String(text.reversed().prefix(while: isSpace)).reversed())
        var value = String(text.dropFirst(leading.count).dropLast(trailing.count))
        if run.isStrikethrough { value = "~~\(value)~~" }
        if run.highlight != nil { value = "==\(value)==" }
        if run.isBold, run.isItalic {
            value = "***\(value)***"
        } else if run.isBold {
            value = "**\(value)**"
        } else if run.isItalic {
            value = "*\(value)*"
        }
        if run.isUnderlined, run.link == nil { value = "<u>\(value)</u>" }
        if let link = run.link, !link.isEmpty { value = "[\(value)](\(link))" }
        return leading + value + trailing
    }

    static func soleTableRows(in paragraph: NotesParagraph, attachments: [String: NotesAttachment]) -> [[String]]? {
        var rows: [[String]]?
        for segment in paragraph.segments {
            let trimmed = segment.text.trimmingCharacters(in: .whitespaces)
            if rows == nil, let identifier = segment.run.attachmentIdentifier,
               let attachment = attachments[identifier], attachment.kind == .table,
               let tableRows = attachment.tableRows, trimmed == String(NotesDocumentLayout.attachmentCharacter) {
                rows = tableRows
            } else if !trimmed.isEmpty {
                return nil
            }
        }
        return rows
    }

    static func tableLines(_ rows: [[String]]) -> [String] {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0, let header = rows.first else { return [] }
        func cell(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
                .trimmingCharacters(in: .whitespaces)
        }
        func line(_ row: [String]) -> String {
            "| " + (0..<width).map { $0 < row.count ? cell(row[$0]) : "" }.joined(separator: " | ") + " |"
        }
        return [line(header), "|" + String(repeating: " --- |", count: width)] + rows.dropFirst().map(line)
    }

    static func attachmentMarkdown(_ attachment: NotesAttachment?) -> String {
        guard let attachment else { return "" }
        switch attachment.kind {
        case .hashtag, .mention, .inline:
            return attachment.altText ?? ""
        case .link:
            guard let url = attachment.urlString, !url.isEmpty else { return attachment.title ?? "" }
            let title = attachment.title.flatMap { $0.isEmpty ? nil : $0 } ?? url
            return "[\(escapedLinkText(title))](\(url))"
        case .image:
            guard let url = attachment.fileURL else { return "[Image: \(attachment.displayName)]" }
            return "![\(escapedLinkText(attachment.displayName))](\(url.absoluteString))"
        case .drawing:
            guard let url = attachment.previewImageURL else { return "[Drawing]" }
            return "![Drawing](\(url.absoluteString))"
        case .table:
            guard let rows = attachment.tableRows else { return "[Table]" }
            return "\n\n" + tableLines(rows).joined(separator: "\n") + "\n\n"
        case .audio, .scan, .file:
            guard let url = attachment.fileURL else { return "[\(attachment.kind.displayName): \(attachment.displayName)]" }
            return "[\(escapedLinkText(attachment.displayName))](\(url.absoluteString))"
        }
    }

    static func attachmentPlainText(_ attachment: NotesAttachment?) -> String {
        guard let attachment else { return "" }
        switch attachment.kind {
        case .hashtag, .mention, .inline:
            return attachment.altText ?? ""
        case .link:
            return attachment.urlString ?? attachment.title ?? ""
        case .table:
            guard let rows = attachment.tableRows else { return "[Table]" }
            return "\n" + rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
        default:
            return "[\(attachment.kind.displayName): \(attachment.displayName)]"
        }
    }

    private static func escapedLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}

/// Converts the small Markdown subset users type into the HTML Notes accepts
/// through AppleScript. Notes has no HTML form for checklists, so checklist
/// items become bullet items with a checkbox glyph.
enum NotesHTMLComposer {
    static func html(fromMarkdown markdown: String) -> String {
        var html = ""
        var openList: String?
        var inCodeBlock = false

        func closeList() {
            if let list = openList {
                html += "</\(list)>"
                openList = nil
            }
        }
        func openListIfNeeded(_ list: String) {
            guard openList != list else { return }
            closeList()
            html += "<\(list)>"
            openList = list
        }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                closeList()
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                html += "<div><tt>\(line.isEmpty ? "<br>" : escape(line))</tt></div>"
                continue
            }
            if trimmed.isEmpty {
                closeList()
                html += "<div><br></div>"
                continue
            }
            if let match = captures(#"^(#{1,6})\s+(.*)$"#, trimmed) {
                closeList()
                let level = min(match[1].count, 3)
                html += "<h\(level)>\(inline(match[2]))</h\(level)>"
            } else if let match = captures(#"^[-*+]\s+\[([ xX])\]\s*(.*)$"#, trimmed) {
                openListIfNeeded("ul")
                html += "<li>\(match[1] == " " ? "☐" : "☑") \(inline(match[2]))</li>"
            } else if let match = captures(#"^[-*+]\s+(.*)$"#, trimmed) {
                openListIfNeeded("ul")
                html += "<li>\(inline(match[1]))</li>"
            } else if let match = captures(#"^\d+[.)]\s+(.*)$"#, trimmed) {
                openListIfNeeded("ol")
                html += "<li>\(inline(match[1]))</li>"
            } else if let match = captures(#"^>\s?(.*)$"#, trimmed) {
                closeList()
                html += "<blockquote>\(inline(match[1]))</blockquote>"
            } else {
                closeList()
                html += "<div>\(inline(trimmed))</div>"
            }
        }
        closeList()
        return html
    }

    static func inline(_ text: String) -> String {
        var value = escape(text)
        let replacements: [(String, String)] = [
            (#"`([^`]+)`"#, "<tt>$1</tt>"),
            (#"\*\*\*(.+?)\*\*\*"#, "<b><i>$1</i></b>"),
            (#"\*\*(.+?)\*\*"#, "<b>$1</b>"),
            (#"__(.+?)__"#, "<b>$1</b>"),
            (#"~~(.+?)~~"#, "<strike>$1</strike>"),
            (#"(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])"#, "<i>$1</i>"),
            (#"(?<![_\w])_(?!\s)(.+?)(?<!\s)_(?![_\w])"#, "<i>$1</i>"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in replacements {
            value = value.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return value
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}

enum NotesTextFolding {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func foldedBytes(_ text: String) -> [UInt8] {
        Array(fold(text).utf8)
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pattern in
                memmem(hay.baseAddress, hay.count, pattern.baseAddress, pattern.count) != nil
            }
        }
    }
}

/// Query syntax shared by the launcher rows and the Notes browser:
/// words (all must match), "exact phrases", -excluded, #tag, in:folder,
/// is:pinned|shared|locked|deleted, has:checklist|todo|attachment|image|table|
/// drawing|link|file|audio|tag, modified:7d, created:2026-03, after:/before:
/// dates and sort:modified|created|title|relevance.
struct NotesSearchQuery: Equatable {
    enum Filter: String {
        case checklist, todo, attachment, image, table, drawing, link, tag, file, audio
    }

    enum Sort: String {
        case relevance, modified, created, title
    }

    var terms: [String] = []
    var phrases: [String] = []
    var excluded: [String] = []
    var tags: [String] = []
    var folders: [String] = []
    var folderPKs: Set<Int64>?
    var pinned: Bool?
    var shared: Bool?
    var locked: Bool?
    var filters: Set<Filter> = []
    var modifiedAfter: Date?
    var modifiedBefore: Date?
    var createdAfter: Date?
    var createdBefore: Date?
    var sort: Sort?
    var onlyTrash = false
    var includeTrash = false
    var titleOnly = false

    var hasTextCriteria: Bool { !terms.isEmpty || !phrases.isEmpty }
    var hasStructuredCriteria: Bool {
        !tags.isEmpty || !folders.isEmpty || folderPKs != nil || pinned != nil || shared != nil || locked != nil
            || !filters.isEmpty || modifiedAfter != nil || modifiedBefore != nil || createdAfter != nil
            || createdBefore != nil || onlyTrash || sort != nil
    }
    var isEmpty: Bool { !hasTextCriteria && excluded.isEmpty && !hasStructuredCriteria }
    var highlightTerms: [String] { phrases + terms }

    static func parse(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> NotesSearchQuery {
        var query = NotesSearchQuery()
        for token in tokenize(raw) {
            let text = token.text
            if token.isQuoted {
                let phrase = NotesTextFolding.fold(text).trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { query.phrases.append(phrase) }
                continue
            }
            if text.count > 1, text.hasPrefix("#") {
                query.tags.append(NotesTextFolding.fold(String(text.dropFirst())))
                continue
            }
            if let colon = text.firstIndex(of: ":"), colon != text.startIndex {
                let key = text[..<colon].lowercased()
                let value = String(text[text.index(after: colon)...])
                if query.apply(key: key, value: value, now: now, calendar: calendar) { continue }
            }
            if text.count > 1, text.hasPrefix("-") {
                query.excluded.append(NotesTextFolding.fold(String(text.dropFirst())))
                continue
            }
            let term = NotesTextFolding.fold(text)
            if !term.isEmpty { query.terms.append(term) }
        }
        return query
    }

    struct Token: Equatable {
        var text: String
        var isQuoted: Bool
    }

    static func tokenize(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        var quotedWhole = false
        var sawQuote = false
        for character in raw {
            if character == "\"" || character == "\u{201C}" || character == "\u{201D}" {
                if !inQuotes, current.isEmpty { quotedWhole = true }
                inQuotes.toggle()
                sawQuote = true
                continue
            }
            if character.isWhitespace, !inQuotes {
                if !current.isEmpty || sawQuote { tokens.append(Token(text: current, isQuoted: quotedWhole)) }
                current = ""
                quotedWhole = false
                sawQuote = false
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(Token(text: current, isQuoted: quotedWhole)) }
        return tokens.filter { !$0.text.isEmpty }
    }

    /// Returns false for unknown keys so `word:with:colons` stays a search term.
    mutating func apply(key: String, value: String, now: Date, calendar: Calendar) -> Bool {
        let lowered = value.lowercased()
        switch key {
        case "in", "folder":
            if !value.isEmpty { folders.append(NotesTextFolding.fold(value)) }
            return true
        case "tag":
            let tag = value.hasPrefix("#") ? String(value.dropFirst()) : value
            if !tag.isEmpty { tags.append(NotesTextFolding.fold(tag)) }
            return true
        case "is":
            switch lowered {
            case "pinned": pinned = true
            case "unpinned": pinned = false
            case "shared": shared = true
            case "locked": locked = true
            case "unlocked": locked = false
            case "deleted", "trash", "trashed": onlyTrash = true
            case "": break
            default: return false
            }
            return true
        case "has":
            let aliases: [String: Filter] = [
                "checklist": .checklist, "checklists": .checklist,
                "todo": .todo, "todos": .todo, "open": .todo,
                "attachment": .attachment, "attachments": .attachment,
                "image": .image, "images": .image, "photo": .image, "photos": .image,
                "table": .table, "tables": .table,
                "drawing": .drawing, "drawings": .drawing, "sketch": .drawing,
                "link": .link, "links": .link, "url": .link,
                "tag": .tag, "tags": .tag,
                "file": .file, "files": .file, "pdf": .file,
                "audio": .audio, "recording": .audio, "recordings": .audio,
            ]
            if lowered.isEmpty { return true }
            guard let filter = aliases[lowered] else { return false }
            filters.insert(filter)
            return true
        case "after", "since":
            if lowered.isEmpty { return true }
            guard let range = Self.dateRange(lowered, now: now, calendar: calendar) else { return false }
            modifiedAfter = range.start
            return true
        case "before", "until":
            if lowered.isEmpty { return true }
            guard let range = Self.dateRange(lowered, now: now, calendar: calendar) else { return false }
            modifiedBefore = range.start
            return true
        case "modified", "edited", "updated":
            if lowered.isEmpty { return true }
            guard let range = Self.dateRange(lowered, now: now, calendar: calendar) else { return false }
            modifiedAfter = range.start
            modifiedBefore = range.end
            return true
        case "created":
            if lowered.isEmpty { return true }
            guard let range = Self.dateRange(lowered, now: now, calendar: calendar) else { return false }
            createdAfter = range.start
            createdBefore = range.end
            return true
        case "sort":
            switch lowered {
            case "": return true
            case "relevance", "best": sort = .relevance
            case "modified", "edited", "date", "recent": sort = .modified
            case "created", "new", "newest": sort = .created
            case "title", "name", "alpha": sort = .title
            default: return false
            }
            return true
        default:
            return false
        }
    }

    /// Relative values ("7d", "24h", "2w", "3m", "1y") mean "from then until
    /// now". Calendar values cover the whole day, month or year.
    static func dateRange(_ value: String, now: Date, calendar: Calendar) -> (start: Date, end: Date?)? {
        if let unit = value.last, let amount = Double(value.dropLast()), amount >= 0 {
            let seconds: Double?
            switch unit {
            case "h": seconds = amount * 3600
            case "d": seconds = amount * 86_400
            case "w": seconds = amount * 7 * 86_400
            case "m": seconds = amount * 30 * 86_400
            case "y": seconds = amount * 365 * 86_400
            default: seconds = nil
            }
            if let seconds { return (now.addingTimeInterval(-seconds), nil) }
        }
        switch value {
        case "today":
            let start = calendar.startOfDay(for: now)
            return (start, calendar.date(byAdding: .day, value: 1, to: start))
        case "yesterday":
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
            return (start, today)
        default:
            break
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formats: [(String, Calendar.Component)] = [("yyyy-MM-dd", .day), ("yyyy-MM", .month), ("yyyy", .year)]
        for (format, component) in formats {
            formatter.dateFormat = format
            guard let start = formatter.date(from: value) else { continue }
            return (start, calendar.date(byAdding: component, value: 1, to: start))
        }
        return nil
    }
}

struct NotesAccountRecord {
    let pk: Int64
    let identifier: String
    let name: String
}

struct NotesFolderRecord {
    let pk: Int64
    let identifier: String
    let name: String
    let parentPK: Int64?
    let accountPK: Int64?
    let isTrash: Bool
    let isSmartFolder: Bool
    var path: String
    var depth: Int
}

struct NotesNoteRecord {
    let pk: Int64
    let identifier: String
    let title: String
    let snippet: String
    let folderPK: Int64?
    let accountPK: Int64?
    let created: Date?
    let modified: Date?
    let isPinned: Bool
    let isLocked: Bool
    let isShared: Bool
    let hasChecklist: Bool
    let hasOpenChecklist: Bool
    let noteDataPK: Int64?
    var isInTrash = false
    var folderName = ""
    var folderPath = ""
    var foldedFolderPath = ""
    var tags: [String] = []
    var foldedTags: [String] = []
    var attachmentKinds: [NotesAttachmentKind: Int] = [:]
    var foldedTitle = ""
    var foldedBody: [UInt8] = []

    var attachmentCount: Int {
        attachmentKinds.filter { !$0.key.isInline }.values.reduce(0, +)
    }

    func count(of kind: NotesAttachmentKind) -> Int {
        attachmentKinds[kind] ?? 0
    }

    /// AppleScript rewrites the whole body, which would drop content that has
    /// no HTML form.
    var canAppendThroughAppleScript: Bool {
        !isLocked && !hasChecklist && attachmentCount == 0 && count(of: .hashtag) == 0 && count(of: .mention) == 0
    }
}

struct NotesTagCount: Hashable {
    let name: String
    let count: Int
}

struct NotesSchema {
    let entities: [String: Int]
    let storeUUID: String
    let resolvedColumns: [String: String]
    let hasNoteDataTable: Bool

    /// Physical column for a logical key, or NULL when this Notes version
    /// does not have it.
    func column(_ key: String, alias: String? = nil) -> String {
        guard let name = resolvedColumns[key] else { return "NULL" }
        return alias.map { "\($0).\(name)" } ?? name
    }

    func entity(_ name: String) -> Int64 {
        Int64(entities[name] ?? -1)
    }

    /// Core Data numbers duplicate attribute names (ZTITLE1, ZTITLE2, ...)
    /// differently across Notes versions, so each key lists candidates and the
    /// one actually populated for the entity wins.
    static let columnCandidates: [(key: String, entity: String, candidates: [String])] = [
        ("note.title", "ICNote", ["ZTITLE1", "ZTITLE", "ZTITLE2"]),
        ("note.snippet", "ICNote", ["ZSNIPPET"]),
        ("note.created", "ICNote", ["ZCREATIONDATE3", "ZCREATIONDATE1", "ZCREATIONDATE2", "ZCREATIONDATE"]),
        ("note.modified", "ICNote", ["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"]),
        ("note.folder", "ICNote", ["ZFOLDER"]),
        ("note.account", "ICNote", ["ZACCOUNT7", "ZACCOUNT8", "ZACCOUNT6", "ZACCOUNT5", "ZACCOUNT4", "ZACCOUNT3", "ZACCOUNT2", "ZACCOUNT1", "ZACCOUNT"]),
        ("note.pinned", "ICNote", ["ZISPINNED"]),
        ("note.locked", "ICNote", ["ZISPASSWORDPROTECTED"]),
        ("note.deleted", "ICNote", ["ZMARKEDFORDELETION"]),
        ("note.data", "ICNote", ["ZNOTEDATA"]),
        ("note.checklist", "ICNote", ["ZHASCHECKLIST"]),
        ("note.checklistOpen", "ICNote", ["ZHASCHECKLISTINPROGRESS"]),
        ("note.share", "ICNote", ["ZSERVERSHAREDATA"]),
        ("folder.title", "ICFolder", ["ZTITLE2", "ZTITLE", "ZTITLE1"]),
        ("folder.parent", "ICFolder", ["ZPARENT"]),
        ("folder.type", "ICFolder", ["ZFOLDERTYPE"]),
        ("folder.account", "ICFolder", ["ZOWNER", "ZACCOUNT8", "ZACCOUNT7", "ZACCOUNT6", "ZACCOUNT5", "ZACCOUNT4", "ZACCOUNT3", "ZACCOUNT2", "ZACCOUNT1", "ZACCOUNT"]),
        ("folder.deleted", "ICFolder", ["ZMARKEDFORDELETION"]),
        ("folder.smart", "ICFolder", ["ZSMARTFOLDERQUERYJSON"]),
        ("account.name", "ICAccount", ["ZNAME", "ZACCOUNTNAMEFORACCOUNTLISTSORTING"]),
        ("attachment.note", "ICAttachment", ["ZNOTE", "ZNOTE1"]),
        ("attachment.uti", "ICAttachment", ["ZTYPEUTI", "ZTYPEUTI1"]),
        ("attachment.title", "ICAttachment", ["ZTITLE", "ZUSERTITLE", "ZTITLE1"]),
        ("attachment.url", "ICAttachment", ["ZURLSTRING"]),
        ("attachment.media", "ICAttachment", ["ZMEDIA"]),
        ("attachment.mergeable", "ICAttachment", ["ZMERGEABLEDATA1", "ZMERGEABLEDATA", "ZMERGEABLEDATA2"]),
        ("attachment.fallbackGeneration", "ICAttachment", ["ZFALLBACKIMAGEGENERATION"]),
        ("attachment.deleted", "ICAttachment", ["ZMARKEDFORDELETION"]),
        ("inline.note", "ICInlineAttachment", ["ZNOTE1", "ZNOTE"]),
        ("inline.uti", "ICInlineAttachment", ["ZTYPEUTI1", "ZTYPEUTI"]),
        ("inline.alt", "ICInlineAttachment", ["ZALTTEXT"]),
        ("inline.deleted", "ICInlineAttachment", ["ZMARKEDFORDELETION"]),
        ("media.filename", "ICMedia", ["ZFILENAME"]),
        ("media.generation", "ICMedia", ["ZGENERATION1", "ZGENERATION"]),
        ("media.account", "ICMedia", ["ZACCOUNT6", "ZACCOUNT5", "ZACCOUNT4", "ZACCOUNT3", "ZACCOUNT2", "ZACCOUNT1", "ZACCOUNT7", "ZACCOUNT8", "ZACCOUNT"]),
    ]
}

extension NotesSchema {
    init(database: NotesDatabase) throws {
        var entities: [String: Int] = [:]
        try database.query("SELECT Z_ENT, Z_NAME FROM Z_PRIMARYKEY") { row in
            if let entity = row.int64(0), let name = row.string(1) { entities[name] = Int(entity) }
        }
        guard entities["ICNote"] != nil, entities["ICFolder"] != nil else {
            throw NotesLibraryError.unsupportedSchema
        }
        var storeUUID = ""
        try database.query("SELECT Z_UUID FROM Z_METADATA LIMIT 1") { row in
            storeUUID = row.string(0) ?? ""
        }
        var columns = Set<String>()
        try database.query("PRAGMA table_info(ZICCLOUDSYNCINGOBJECT)") { row in
            if let name = row.string(1) { columns.insert(name) }
        }
        var tables = Set<String>()
        try database.query("SELECT name FROM sqlite_master WHERE type = 'table'") { row in
            if let name = row.string(0) { tables.insert(name) }
        }

        var resolved: [String: String] = [:]
        for specification in Self.columnCandidates {
            let present = specification.candidates.filter { columns.contains($0) }
            guard let first = present.first else { continue }
            guard present.count > 1, let entity = entities[specification.entity] else {
                resolved[specification.key] = first
                continue
            }
            var best = first
            var bestCount: Int64 = -1
            for column in present {
                var count: Int64 = 0
                try database.query("SELECT COUNT(\(column)) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ?", [Int64(entity)]) { row in
                    count = row.int64(0) ?? 0
                }
                if count > bestCount {
                    best = column
                    bestCount = count
                }
            }
            resolved[specification.key] = best
        }
        self.init(entities: entities, storeUUID: storeUUID, resolvedColumns: resolved, hasNoteDataTable: tables.contains("ZICNOTEDATA"))
    }
}

struct NotesLibrarySnapshot {
    let databasePath: String
    let schema: NotesSchema
    let accounts: [Int64: NotesAccountRecord]
    let folders: [Int64: NotesFolderRecord]
    let notes: [NotesNoteRecord]
    let tagCounts: [NotesTagCount]
    let folderNoteCounts: [Int64: Int]
    let loadedAt: Date
    let loadDuration: TimeInterval

    var containerPath: String { (databasePath as NSString).deletingLastPathComponent }
    var visibleNoteCount: Int { notes.lazy.filter { !$0.isInTrash }.count }

    func note(identifier: String) -> NotesNoteRecord? {
        notes.first { $0.identifier == identifier }
    }

    func appleScriptID(for note: NotesNoteRecord) -> String {
        "x-coredata://\(schema.storeUUID)/ICNote/p\(note.pk)"
    }

    func appleScriptID(forFolder folder: NotesFolderRecord) -> String {
        "x-coredata://\(schema.storeUUID)/ICFolder/p\(folder.pk)"
    }

    /// Regular folders in sidebar order: grouped by account, then by path.
    var regularFolders: [NotesFolderRecord] {
        folders.values
            .filter { !$0.isTrash && !$0.isSmartFolder }
            .sorted { lhs, rhs in
                let lhsAccount = lhs.accountPK.flatMap { accounts[$0]?.name } ?? ""
                let rhsAccount = rhs.accountPK.flatMap { accounts[$0]?.name } ?? ""
                if lhsAccount != rhsAccount { return lhsAccount.localizedStandardCompare(rhsAccount) == .orderedAscending }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
    }

    func folderAndDescendants(_ pk: Int64) -> Set<Int64> {
        var result: Set<Int64> = [pk]
        var changed = true
        while changed {
            changed = false
            for folder in folders.values where !result.contains(folder.pk) {
                if let parent = folder.parentPK, result.contains(parent) {
                    result.insert(folder.pk)
                    changed = true
                }
            }
        }
        return result
    }
}

struct NotesSearchHit {
    let note: NotesNoteRecord
    /// 100 exact title, 85 title prefix, 72 title word prefix, 58 title
    /// substring, 40 tag, 30 body only, 50 for filter-only queries.
    let score: Int
    let matchedTitle: Bool
}

enum NotesSearchEngine {
    static func search(_ query: NotesSearchQuery, in snapshot: NotesLibrarySnapshot, limit: Int) -> [NotesSearchHit] {
        let termBytes = query.terms.map { Array($0.utf8) }
        let phraseBytes = query.phrases.map { Array($0.utf8) }
        let excludedBytes = query.excluded.map { Array($0.utf8) }
        let joinedTerms = query.terms.joined(separator: " ")
        var hits: [NotesSearchHit] = []

        for note in snapshot.notes {
            if query.onlyTrash {
                guard note.isInTrash else { continue }
            } else if note.isInTrash, !query.includeTrash {
                continue
            }
            guard matchesFilters(note, query) else { continue }

            var score = query.hasTextCriteria ? 100 : 50
            var matchedTitle = true
            var rejected = false
            for (index, term) in query.terms.enumerated() {
                if let titleScore = titleScore(term: term, foldedTitle: note.foldedTitle) {
                    score = min(score, titleScore)
                } else if note.foldedTags.contains(where: { $0.hasPrefix(term) }) {
                    score = min(score, 40)
                } else if !query.titleOnly, NotesTextFolding.contains(note.foldedBody, termBytes[index]) {
                    score = min(score, 30)
                    matchedTitle = false
                } else {
                    rejected = true
                    break
                }
            }
            if rejected { continue }
            for (index, phrase) in query.phrases.enumerated() {
                if note.foldedTitle.contains(phrase) {
                    score = min(score, 58)
                } else if !query.titleOnly, NotesTextFolding.contains(note.foldedBody, phraseBytes[index]) {
                    score = min(score, 30)
                    matchedTitle = false
                } else {
                    rejected = true
                    break
                }
            }
            if rejected { continue }
            if excludedBytes.contains(where: { excluded in
                note.foldedTitle.contains(String(decoding: excluded, as: UTF8.self))
                    || NotesTextFolding.contains(note.foldedBody, excluded)
            }) {
                continue
            }
            if query.terms.count > 1, query.phrases.isEmpty {
                if note.foldedTitle == joinedTerms {
                    score = 100
                    matchedTitle = true
                } else if note.foldedTitle.hasPrefix(joinedTerms) {
                    score = max(score, 85)
                    matchedTitle = true
                }
            }
            hits.append(NotesSearchHit(note: note, score: score, matchedTitle: matchedTitle))
        }

        let sort = query.sort ?? (query.hasTextCriteria ? .relevance : .modified)
        let pinnedFirst = query.sort == nil && !query.hasTextCriteria
        hits.sort { lhs, rhs in
            if pinnedFirst, lhs.note.isPinned != rhs.note.isPinned { return lhs.note.isPinned }
            switch sort {
            case .relevance:
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.note.isPinned != rhs.note.isPinned { return lhs.note.isPinned }
                return (lhs.note.modified ?? .distantPast) > (rhs.note.modified ?? .distantPast)
            case .modified:
                return (lhs.note.modified ?? .distantPast) > (rhs.note.modified ?? .distantPast)
            case .created:
                return (lhs.note.created ?? .distantPast) > (rhs.note.created ?? .distantPast)
            case .title:
                return lhs.note.title.localizedStandardCompare(rhs.note.title) == .orderedAscending
            }
        }
        return Array(hits.prefix(max(0, limit)))
    }

    static func titleScore(term: String, foldedTitle: String) -> Int? {
        if foldedTitle == term { return 100 }
        if foldedTitle.hasPrefix(term) { return 85 }
        var searchStart = foldedTitle.startIndex
        var found = false
        while let range = foldedTitle.range(of: term, range: searchStart..<foldedTitle.endIndex) {
            found = true
            let previous = foldedTitle[foldedTitle.index(before: range.lowerBound)]
            if !previous.isLetter, !previous.isNumber { return 72 }
            guard range.lowerBound < foldedTitle.endIndex else { break }
            searchStart = foldedTitle.index(after: range.lowerBound)
        }
        return found ? 58 : nil
    }

    static func matchesFilters(_ note: NotesNoteRecord, _ query: NotesSearchQuery) -> Bool {
        if let pinned = query.pinned, note.isPinned != pinned { return false }
        if let shared = query.shared, note.isShared != shared { return false }
        if let locked = query.locked, note.isLocked != locked { return false }
        if let folderPKs = query.folderPKs {
            guard let folder = note.folderPK, folderPKs.contains(folder) else { return false }
        }
        for folder in query.folders where !note.foldedFolderPath.contains(folder) { return false }
        for tag in query.tags where !note.foldedTags.contains(where: { $0.hasPrefix(tag) }) { return false }
        if let date = query.modifiedAfter, (note.modified ?? .distantPast) < date { return false }
        if let date = query.modifiedBefore, (note.modified ?? .distantFuture) >= date { return false }
        if let date = query.createdAfter, (note.created ?? .distantPast) < date { return false }
        if let date = query.createdBefore, (note.created ?? .distantFuture) >= date { return false }
        for filter in query.filters {
            let matches: Bool
            switch filter {
            case .checklist: matches = note.hasChecklist
            case .todo: matches = note.hasOpenChecklist
            case .attachment: matches = note.attachmentCount > 0
            case .image: matches = note.count(of: .image) + note.count(of: .scan) > 0
            case .table: matches = note.count(of: .table) > 0
            case .drawing: matches = note.count(of: .drawing) > 0
            case .link: matches = note.count(of: .link) > 0
            case .tag: matches = !note.tags.isEmpty
            case .file: matches = note.count(of: .file) > 0
            case .audio: matches = note.count(of: .audio) > 0
            }
            if !matches { return false }
        }
        return true
    }
}

enum NotesSnippet {
    /// A short excerpt around the first matching term, on one line. The first
    /// line is the note title, which results already show, so it is only
    /// searched when nothing else matches.
    static func excerpt(from text: String, terms: [String], before: Int = 30, after: Int = 90) -> String? {
        if let newline = text.firstIndex(of: "\n"),
           let excerpt = excerpt(inFlattened: flattened(text[text.index(after: newline)...]), terms: terms, before: before, after: after) {
            return excerpt
        }
        return excerpt(inFlattened: flattened(text[...]), terms: terms, before: before, after: after)
    }

    private static func flattened(_ text: Substring) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func excerpt(inFlattened text: String, terms: [String], before: Int, after: Int) -> String? {
        for term in terms where !term.isEmpty {
            guard let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) else { continue }
            var lower = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
            var upper = text.index(range.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
            // Start and end on word boundaries.
            if lower > text.startIndex, let space = text[lower..<range.lowerBound].firstIndex(of: " ") {
                lower = text.index(after: space)
            }
            if upper < text.endIndex, let space = text[range.upperBound..<upper].lastIndex(of: " ") {
                upper = space
            }
            var excerpt = String(text[lower..<upper])
            if lower > text.startIndex { excerpt = "…" + excerpt }
            if upper < text.endIndex { excerpt += "…" }
            return excerpt
        }
        return nil
    }
}

enum NotesLibraryError: Error, Equatable {
    case databaseMissing
    case needsFullDiskAccess
    case unsupportedSchema
    case unreadable(String)

    var title: String {
        switch self {
        case .databaseMissing: return "Apple Notes Not Set Up"
        case .needsFullDiskAccess: return "Full Disk Access Required"
        case .unsupportedSchema: return "Unsupported Notes Version"
        case .unreadable: return "Apple Notes Unavailable"
        }
    }

    var message: String {
        switch self {
        case .databaseMissing:
            return "No local Notes library was found. Open Notes once so it can create its library, then try again."
        case .needsFullDiskAccess:
            return "macOS protects the Notes library. Allow BetterTouchTool in System Settings › Privacy & Security › Full Disk Access to search and preview notes. The plugin only reads the library; changes always go through Notes."
        case .unsupportedSchema:
            return "This version of Notes stores its library in a format the plugin does not recognize."
        case .unreadable(let detail):
            return "The Notes library could not be read: \(detail)"
        }
    }
}

final class NotesDatabase {
    private let handle: OpaquePointer

    init(path: String) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(status)"
            if let database { sqlite3_close_v2(database) }
            throw NotesLibraryError.unreadable(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 2000)
        try query("PRAGMA query_only = 1") { _ in }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func query(_ sql: String, _ bindings: [Int64] = [], row: (NotesSQLRow) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NotesLibraryError.unreadable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            sqlite3_bind_int64(statement, Int32(offset + 1), value)
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                try row(NotesSQLRow(statement: statement))
            } else if step == SQLITE_DONE {
                return
            } else {
                throw NotesLibraryError.unreadable(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}

struct NotesSQLRow {
    let statement: OpaquePointer

    func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
    func int64(_ index: Int32) -> Int64? { isNull(index) ? nil : sqlite3_column_int64(statement, index) }
    func double(_ index: Int32) -> Double? { isNull(index) ? nil : sqlite3_column_double(statement, index) }
    func bool(_ index: Int32) -> Bool { (int64(index) ?? 0) != 0 }

    func string(_ index: Int32) -> String? {
        guard !isNull(index), let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    func data(_ index: Int32) -> Data? {
        guard !isNull(index), let blob = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

struct NotesNoteDetail {
    let note: NotesNoteRecord
    let paragraphs: [NotesParagraph]
    let attachments: [String: NotesAttachment]
    let isContentAvailable: Bool

    var markdown: String { NotesMarkdownRenderer.markdown(of: paragraphs, attachments: attachments) }
    var plainText: String { NotesMarkdownRenderer.plainText(of: paragraphs, attachments: attachments) }
}

enum NotesLibraryLoader {
    static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite").path
    }

    /// TCC denials surface as EPERM on open(2); SQLite would only report a
    /// generic "unable to open" error.
    static func checkAccess(_ path: String) throws {
        let descriptor = Darwin.open(path, O_RDONLY)
        if descriptor >= 0 {
            Darwin.close(descriptor)
            return
        }
        let code = errno
        switch code {
        case ENOENT: throw NotesLibraryError.databaseMissing
        case EPERM, EACCES: throw NotesLibraryError.needsFullDiskAccess
        default: throw NotesLibraryError.unreadable(String(cString: strerror(code)))
        }
    }

    static func loadSnapshot(databasePath: String) throws -> NotesLibrarySnapshot {
        let started = Date()
        try checkAccess(databasePath)
        let database = try NotesDatabase(path: databasePath)
        let schema = try NotesSchema(database: database)
        let c = schema

        var accounts: [Int64: NotesAccountRecord] = [:]
        try database.query(
            "SELECT Z_PK, ZIDENTIFIER, \(c.column("account.name")) FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ?",
            [c.entity("ICAccount")]
        ) { row in
            guard let pk = row.int64(0) else { return }
            accounts[pk] = NotesAccountRecord(pk: pk, identifier: row.string(1) ?? "", name: row.string(2) ?? "Notes")
        }

        var folders: [Int64: NotesFolderRecord] = [:]
        try database.query("""
            SELECT Z_PK, ZIDENTIFIER, \(c.column("folder.title")), \(c.column("folder.parent")), \(c.column("folder.account")),
                   \(c.column("folder.type")), \(c.column("folder.smart")), \(c.column("folder.deleted"))
            FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ?
            """, [c.entity("ICFolder")]) { row in
            guard let pk = row.int64(0), !row.bool(7) else { return }
            folders[pk] = NotesFolderRecord(
                pk: pk,
                identifier: row.string(1) ?? "",
                name: row.string(2) ?? "Folder",
                parentPK: row.int64(3),
                accountPK: row.int64(4),
                isTrash: row.int64(5) == 1,
                isSmartFolder: row.string(6)?.isEmpty == false,
                path: "",
                depth: 0
            )
        }
        for pk in Array(folders.keys) {
            var names: [String] = []
            var cursor: Int64? = pk
            while let current = cursor, let folder = folders[current], names.count < 32 {
                names.insert(folder.name, at: 0)
                cursor = folder.parentPK
            }
            folders[pk]?.path = names.joined(separator: " / ")
            folders[pk]?.depth = max(0, names.count - 1)
        }

        var notes: [NotesNoteRecord] = []
        try database.query("""
            SELECT Z_PK, ZIDENTIFIER, \(c.column("note.title")), \(c.column("note.snippet")), \(c.column("note.folder")),
                   \(c.column("note.account")), \(c.column("note.created")), \(c.column("note.modified")),
                   \(c.column("note.pinned")), \(c.column("note.locked")), \(c.column("note.deleted")),
                   \(c.column("note.data")), \(c.column("note.checklist")), \(c.column("note.checklistOpen")),
                   \(c.column("note.share")) IS NOT NULL
            FROM ZICCLOUDSYNCINGOBJECT WHERE Z_ENT = ?
            """, [c.entity("ICNote")]) { row in
            guard let pk = row.int64(0), let identifier = row.string(1), !row.bool(10),
                  let folderPK = row.int64(4), let folder = folders[folderPK] else { return }
            let rawTitle = (row.string(2) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var note = NotesNoteRecord(
                pk: pk,
                identifier: identifier,
                title: rawTitle.isEmpty ? "New Note" : rawTitle,
                snippet: (row.string(3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                folderPK: folderPK,
                accountPK: row.int64(5) ?? folder.accountPK,
                created: row.double(6).map { Date(timeIntervalSinceReferenceDate: $0) },
                modified: row.double(7).map { Date(timeIntervalSinceReferenceDate: $0) },
                isPinned: row.bool(8),
                isLocked: row.bool(9),
                isShared: row.bool(14),
                hasChecklist: row.bool(12),
                hasOpenChecklist: row.bool(13),
                noteDataPK: row.int64(11)
            )
            note.isInTrash = folder.isTrash
            note.folderName = folder.name
            note.folderPath = folder.path
            note.foldedFolderPath = NotesTextFolding.fold(folder.path)
            note.foldedTitle = NotesTextFolding.fold(note.title)
            notes.append(note)
        }

        var tagsByNote: [Int64: [String]] = [:]
        try database.query("""
            SELECT \(c.column("inline.note")), \(c.column("inline.alt")) FROM ZICCLOUDSYNCINGOBJECT
            WHERE Z_ENT = ? AND \(c.column("inline.uti")) = 'com.apple.notes.inlinetextattachment.hashtag'
              AND IFNULL(\(c.column("inline.deleted")), 0) = 0
            """, [c.entity("ICInlineAttachment")]) { row in
            guard let notePK = row.int64(0), var tag = row.string(1)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            if tag.hasPrefix("#") { tag.removeFirst() }
            guard !tag.isEmpty else { return }
            var tags = tagsByNote[notePK] ?? []
            if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
            tagsByNote[notePK] = tags
        }

        var kindsByNote: [Int64: [NotesAttachmentKind: Int]] = [:]
        try database.query("""
            SELECT \(c.column("attachment.note")), \(c.column("attachment.uti")) FROM ZICCLOUDSYNCINGOBJECT
            WHERE Z_ENT = ? AND IFNULL(\(c.column("attachment.deleted")), 0) = 0
            """, [c.entity("ICAttachment")]) { row in
            guard let notePK = row.int64(0), let uti = row.string(1) else { return }
            kindsByNote[notePK, default: [:]][NotesAttachmentKind.classify(uti: uti), default: 0] += 1
        }

        var indexByNoteData: [Int64: Int] = [:]
        for (index, note) in notes.enumerated() {
            if let tags = tagsByNote[note.pk] {
                notes[index].tags = tags
                notes[index].foldedTags = tags.map(NotesTextFolding.fold)
            }
            if let kinds = kindsByNote[note.pk] { notes[index].attachmentKinds = kinds }
            if !note.isLocked, let dataPK = note.noteDataPK { indexByNoteData[dataPK] = index }
        }
        if schema.hasNoteDataTable {
            try database.query("SELECT Z_PK, ZDATA FROM ZICNOTEDATA WHERE ZDATA IS NOT NULL") { row in
                guard let dataPK = row.int64(0), let index = indexByNoteData[dataPK], let data = row.data(1),
                      let text = NotesDocumentDecoder.plainText(fromCompressed: data) else { return }
                notes[index].foldedBody = NotesTextFolding.foldedBytes(text)
            }
        }

        notes.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }

        var tagTotals: [String: (name: String, count: Int)] = [:]
        var folderNoteCounts: [Int64: Int] = [:]
        for note in notes where !note.isInTrash {
            for tag in note.tags {
                let key = NotesTextFolding.fold(tag)
                tagTotals[key] = (tagTotals[key]?.name ?? tag, (tagTotals[key]?.count ?? 0) + 1)
            }
            if let folder = note.folderPK { folderNoteCounts[folder, default: 0] += 1 }
        }
        let tagCounts = tagTotals.values
            .map { NotesTagCount(name: $0.name, count: $0.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        return NotesLibrarySnapshot(
            databasePath: databasePath,
            schema: schema,
            accounts: accounts,
            folders: folders,
            notes: notes,
            tagCounts: tagCounts,
            folderNoteCounts: folderNoteCounts,
            loadedAt: Date(),
            loadDuration: Date().timeIntervalSince(started)
        )
    }

    static func loadDetail(for note: NotesNoteRecord, snapshot: NotesLibrarySnapshot) throws -> NotesNoteDetail {
        let database = try NotesDatabase(path: snapshot.databasePath)
        let c = snapshot.schema

        var document: NotesDocument?
        if !note.isLocked, let dataPK = note.noteDataPK, c.hasNoteDataTable {
            try database.query("SELECT ZDATA FROM ZICNOTEDATA WHERE Z_PK = ?", [dataPK]) { row in
                if let data = row.data(0) { document = NotesDocumentDecoder.document(fromCompressed: data) }
            }
        }
        guard let document else {
            return NotesNoteDetail(note: note, paragraphs: [], attachments: [:], isContentAvailable: false)
        }

        let noteAccount = note.accountPK.flatMap { snapshot.accounts[$0]?.identifier }
        var attachments: [String: NotesAttachment] = [:]
        try database.query("""
            SELECT a.ZIDENTIFIER, \(c.column("attachment.uti", alias: "a")), \(c.column("attachment.title", alias: "a")),
                   \(c.column("attachment.url", alias: "a")), \(c.column("attachment.mergeable", alias: "a")),
                   \(c.column("attachment.fallbackGeneration", alias: "a")), m.ZIDENTIFIER,
                   \(c.column("media.filename", alias: "m")), \(c.column("media.generation", alias: "m")),
                   \(c.column("media.account", alias: "m"))
            FROM ZICCLOUDSYNCINGOBJECT a
            LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = \(c.column("attachment.media", alias: "a"))
            WHERE a.Z_ENT = ? AND \(c.column("attachment.note", alias: "a")) = ?
            """, [c.entity("ICAttachment"), note.pk]) { row in
            guard let identifier = row.string(0) else { return }
            let uti = row.string(1) ?? ""
            let kind = NotesAttachmentKind.classify(uti: uti)
            let mediaAccount = row.int64(9).flatMap { snapshot.accounts[$0]?.identifier } ?? noteAccount
            var attachment = NotesAttachment(identifier: identifier, uti: uti, kind: kind)
            attachment.title = row.string(2)
            attachment.urlString = row.string(3)
            attachment.fileURL = mediaURL(
                container: snapshot.containerPath,
                account: mediaAccount,
                media: row.string(6),
                generation: row.string(8),
                filename: row.string(7)
            )
            if kind == .drawing {
                attachment.previewImageURL = fallbackImageURL(
                    container: snapshot.containerPath,
                    account: noteAccount,
                    attachment: identifier,
                    generation: row.string(5)
                )
            }
            if kind == .table, let data = row.data(4) {
                attachment.tableRows = NotesTableDecoder.rows(fromCompressed: data)
            }
            attachments[identifier] = attachment
        }
        try database.query("""
            SELECT ZIDENTIFIER, \(c.column("inline.uti")), \(c.column("inline.alt")) FROM ZICCLOUDSYNCINGOBJECT
            WHERE Z_ENT = ? AND \(c.column("inline.note")) = ?
            """, [c.entity("ICInlineAttachment"), note.pk]) { row in
            guard let identifier = row.string(0) else { return }
            let uti = row.string(1) ?? ""
            var attachment = NotesAttachment(identifier: identifier, uti: uti, kind: NotesAttachmentKind.classify(uti: uti))
            attachment.altText = row.string(2)
            attachments[identifier] = attachment
        }

        return NotesNoteDetail(
            note: note,
            paragraphs: NotesDocumentLayout.paragraphs(of: document),
            attachments: attachments,
            isContentAvailable: true
        )
    }

    static func mediaURL(container: String, account: String?, media: String?, generation: String?, filename: String?) -> URL? {
        guard let account, let media, let filename, !filename.isEmpty else { return nil }
        let base = URL(fileURLWithPath: container)
            .appendingPathComponent("Accounts").appendingPathComponent(account)
            .appendingPathComponent("Media").appendingPathComponent(media)
        var candidates: [URL] = []
        if let generation, !generation.isEmpty {
            candidates.append(base.appendingPathComponent(generation).appendingPathComponent(filename))
        }
        candidates.append(base.appendingPathComponent(filename))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func fallbackImageURL(container: String, account: String?, attachment: String, generation: String?) -> URL? {
        guard let account else { return nil }
        let base = URL(fileURLWithPath: container)
            .appendingPathComponent("Accounts").appendingPathComponent(account)
            .appendingPathComponent("FallbackImages")
        var candidates: [URL] = []
        if let generation, !generation.isEmpty {
            let folder = base.appendingPathComponent(attachment).appendingPathComponent(generation)
            candidates.append(folder.appendingPathComponent("FallbackImage.png"))
            candidates.append(folder.appendingPathComponent("FallbackImage.jpg"))
        }
        candidates.append(base.appendingPathComponent(attachment + ".png"))
        candidates.append(base.appendingPathComponent(attachment + ".jpg"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Owns the in-memory index. Every database read runs on `queue`; the index
/// reloads when NoteStore.sqlite or its WAL changes.
final class NotesLibraryStore {
    static let shared = NotesLibraryStore(databasePath: NotesLibraryLoader.defaultDatabasePath)

    let databasePath: String
    let queue = DispatchQueue(label: "com.folivora.btt.launcher.applenotes.library", qos: .userInitiated)

    private let lock = NSLock()
    private var snapshotStorage: NotesLibrarySnapshot?
    private var errorStorage: NotesLibraryError?
    // Accessed on `queue` only.
    private var signature: String?
    private var lastSignatureCheck = Date.distantPast
    private var plainTextCache: [String: String] = [:]
    private var plainTextOrder: [String] = []
    private var detailCache: [String: NotesNoteDetail] = [:]
    private var detailOrder: [String] = []

    init(databasePath: String) {
        self.databasePath = databasePath
    }

    var latestSnapshot: NotesLibrarySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshotStorage
    }

    var latestError: NotesLibraryError? {
        lock.lock()
        defer { lock.unlock() }
        return errorStorage
    }

    func withSnapshot(forceReload: Bool = false, _ body: @escaping (Result<NotesLibrarySnapshot, NotesLibraryError>) -> Void) {
        queue.async { body(self.currentSnapshot(forceReload: forceReload)) }
    }

    /// Call on `queue` only.
    func currentSnapshot(forceReload: Bool = false) -> Result<NotesLibrarySnapshot, NotesLibraryError> {
        let now = Date()
        if !forceReload, let snapshot = latestSnapshot, now.timeIntervalSince(lastSignatureCheck) < 1.5 {
            return .success(snapshot)
        }
        lastSignatureCheck = now
        let currentSignature = Self.fileSignature(databasePath)
        if !forceReload, let snapshot = latestSnapshot, currentSignature == signature {
            return .success(snapshot)
        }
        do {
            let snapshot = try NotesLibraryLoader.loadSnapshot(databasePath: databasePath)
            lock.lock()
            snapshotStorage = snapshot
            errorStorage = nil
            lock.unlock()
            signature = currentSignature
            return .success(snapshot)
        } catch {
            let libraryError = error as? NotesLibraryError ?? .unreadable(error.localizedDescription)
            // A transient failure (for example a busy database) keeps the last index.
            if libraryError != .needsFullDiskAccess, libraryError != .databaseMissing, let snapshot = latestSnapshot {
                return .success(snapshot)
            }
            lock.lock()
            snapshotStorage = nil
            errorStorage = libraryError
            lock.unlock()
            return .failure(libraryError)
        }
    }

    func invalidate() {
        queue.async {
            self.signature = nil
            self.lastSignatureCheck = .distantPast
            self.detailCache.removeAll()
            self.detailOrder.removeAll()
        }
    }

    /// Plain text for snippets. Call on `queue` only.
    func plainTexts(for notes: [NotesNoteRecord], snapshot: NotesLibrarySnapshot) -> [Int64: String] {
        var result: [Int64: String] = [:]
        var missing: [Int64: NotesNoteRecord] = [:]
        for note in notes where !note.isLocked {
            guard let dataPK = note.noteDataPK else { continue }
            if let cached = plainTextCache[Self.cacheKey(note)] {
                result[note.pk] = cached
            } else {
                missing[dataPK] = note
            }
        }
        guard !missing.isEmpty, snapshot.schema.hasNoteDataTable,
              let database = try? NotesDatabase(path: snapshot.databasePath) else { return result }
        let placeholders = Array(repeating: "?", count: missing.count).joined(separator: ",")
        try? database.query("SELECT Z_PK, ZDATA FROM ZICNOTEDATA WHERE Z_PK IN (\(placeholders))", Array(missing.keys)) { row in
            guard let dataPK = row.int64(0), let note = missing[dataPK], let data = row.data(1),
                  let text = NotesDocumentDecoder.plainText(fromCompressed: data) else { return }
            result[note.pk] = text
            remember(text, key: Self.cacheKey(note), in: &plainTextCache, order: &plainTextOrder, limit: 200)
        }
        return result
    }

    /// Call on `queue` only.
    func detail(for note: NotesNoteRecord, snapshot: NotesLibrarySnapshot) -> NotesNoteDetail? {
        let key = Self.cacheKey(note)
        if let cached = detailCache[key] { return cached }
        guard let detail = try? NotesLibraryLoader.loadDetail(for: note, snapshot: snapshot) else { return nil }
        remember(detail, key: key, in: &detailCache, order: &detailOrder, limit: 24)
        return detail
    }

    private func remember<Value>(_ value: Value, key: String, in cache: inout [String: Value], order: inout [String], limit: Int) {
        if cache[key] == nil { order.append(key) }
        cache[key] = value
        while order.count > limit {
            cache[order.removeFirst()] = nil
        }
    }

    private static func cacheKey(_ note: NotesNoteRecord) -> String {
        "\(note.pk)-\(note.modified?.timeIntervalSinceReferenceDate ?? 0)"
    }

    static func fileSignature(_ path: String) -> String {
        [path, path + "-wal"].map { file -> String in
            var info = stat()
            guard stat(file, &info) == 0 else { return "-" }
            return "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        }.joined(separator: "|")
    }
}

// MARK: - End Apple Notes Engine

// MARK: - Notes App Bridge

/// Every change to Notes goes through Notes' AppleScript interface. Scripts
/// run through osascript off the main thread; values are passed as arguments,
/// never interpolated into script source.
enum NotesAppBridge {
    struct ScriptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func showNote(_ noteID: String, completion: ((Result<String, Error>) -> Void)? = nil) {
        run("""
            on run argv
                tell application "Notes"
                    activate
                    show note id (item 1 of argv)
                end tell
            end run
            """, arguments: [noteID], completion: completion)
    }

    static func createNote(folderID: String?, html: String, show: Bool, completion: ((Result<String, Error>) -> Void)? = nil) {
        run("""
            on run argv
                set folderRef to item 1 of argv
                set noteBody to item 2 of argv
                tell application "Notes"
                    if folderRef is "" then
                        set targetFolder to default folder of default account
                    else
                        set targetFolder to folder id folderRef
                    end if
                    set newNote to make new note at targetFolder with properties {body:noteBody}
                    if (item 3 of argv) is "1" then
                        activate
                        show newNote
                    end if
                    return id of newNote
                end tell
            end run
            """, arguments: [folderID ?? "", html, show ? "1" : "0"], completion: completion)
    }

    static func append(html: String, toNote noteID: String, completion: ((Result<String, Error>) -> Void)? = nil) {
        run("""
            on run argv
                tell application "Notes"
                    set targetNote to note id (item 1 of argv)
                    set body of targetNote to (body of targetNote) & (item 2 of argv)
                end tell
            end run
            """, arguments: [noteID, html], completion: completion)
    }

    static func move(noteID: String, toFolder folderID: String, completion: ((Result<String, Error>) -> Void)? = nil) {
        run("""
            on run argv
                tell application "Notes"
                    move note id (item 1 of argv) to folder id (item 2 of argv)
                end tell
            end run
            """, arguments: [noteID, folderID], completion: completion)
    }

    static func delete(noteID: String, completion: ((Result<String, Error>) -> Void)? = nil) {
        run("""
            on run argv
                tell application "Notes"
                    delete note id (item 1 of argv)
                end tell
            end run
            """, arguments: [noteID], completion: completion)
    }

    static func run(_ source: String, arguments: [String], timeout: TimeInterval = 30, completion: ((Result<String, Error>) -> Void)?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runSynchronously(source, arguments: arguments, timeout: timeout)
            guard let completion else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runSynchronously(_ source: String, arguments: [String], timeout: TimeInterval) -> Result<String, Error> {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("btt-applenotes-\(UUID().uuidString).applescript")
        do {
            try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return .failure(error)
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptURL.path] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(error)
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let stdout = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus != 0 else { return .success(stdout) }
        let stderr = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(ScriptError(message: userFacingMessage(stderr)))
    }

    private static func userFacingMessage(_ stderr: String) -> String {
        if stderr.contains("-1743") {
            return "BetterTouchTool is not allowed to control Notes. Enable it in System Settings › Privacy & Security › Automation."
        }
        if stderr.contains("-1728") || stderr.contains("-1719") {
            return "Notes could not find that note or folder. It may have been moved or deleted."
        }
        if stderr.isEmpty { return "Notes did not complete the request." }
        // osascript prefixes errors with "<script path>:<range>: execution error: ".
        if let range = stderr.range(of: "execution error: ") {
            return String(stderr[range.upperBound...])
        }
        return stderr
    }
}

// MARK: - Shared Actions

struct AppleNotesConfiguration: Equatable {
    var keywords = ["notes", "n"]
    var inlineLimit = 5
    var keywordLimit = 30
    var searchContentsInline = true
    var exportFolder = "~/Downloads"
    var includeFrontMatter = true
    var includeRecentlyDeleted = false
    var showCreatedNote = true

    init() {}

    init(values: [AnyHashable: Any]) {
        func value(_ key: String) -> Any? { values["plugin_var_\(key)"] ?? values[key] }
        func string(_ key: String) -> String? { value(key) as? String }
        func bool(_ key: String) -> Bool? {
            if let number = value(key) as? NSNumber { return number.boolValue }
            if let string = value(key) as? String { return ["1", "true", "yes"].contains(string.lowercased()) }
            return nil
        }
        func int(_ key: String) -> Int? {
            if let number = value(key) as? NSNumber { return number.intValue }
            if let string = value(key) as? String { return Int(string) }
            return nil
        }

        if let raw = string("keywords") {
            let parsed = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
            keywords = parsed
        }
        inlineLimit = min(max(int("inlineLimit") ?? inlineLimit, 0), 25)
        keywordLimit = min(max(int("keywordLimit") ?? keywordLimit, 5), 200)
        searchContentsInline = bool("searchContentsInline") ?? searchContentsInline
        if let folder = string("exportFolder")?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            exportFolder = folder
        }
        includeFrontMatter = bool("includeFrontMatter") ?? includeFrontMatter
        includeRecentlyDeleted = bool("includeRecentlyDeleted") ?? includeRecentlyDeleted
        showCreatedNote = bool("showCreatedNote") ?? showCreatedNote
    }

    var exportFolderURL: URL {
        URL(fileURLWithPath: (exportFolder as NSString).expandingTildeInPath, isDirectory: true)
    }
}

struct AppleNotesOutcome {
    let success: Bool
    let message: String
}

enum AppleNotesFormatting {
    static let notesAppIcon: NSImage? = {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes")
            ?? URL(fileURLWithPath: "/System/Applications/Notes.app")
        return NSWorkspace.shared.icon(forFile: url.path)
    }()

    static func shortDate(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            formatter.doesRelativeDateFormatting = true
            formatter.dateStyle = .medium
            return formatter.string(from: date)
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7, days >= 0 {
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: date)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
        return formatter.string(from: date)
    }

    static func longDate(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    static func symbol(for note: NotesNoteRecord) -> String {
        if note.isLocked { return "lock.fill" }
        if note.isPinned { return "pin.fill" }
        if note.hasOpenChecklist { return "checklist" }
        if note.count(of: .table) > 0 { return "tablecells" }
        return "note.text"
    }

    static func abbreviatedPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Actions used by launcher rows and by the Notes browser surface.
final class AppleNotesController {
    var configuration = AppleNotesConfiguration()
    let store: NotesLibraryStore
    var onLibraryChanged: (() -> Void)?

    init(store: NotesLibraryStore = .shared) {
        self.store = store
    }

    /// Main-thread lookup for user-initiated actions.
    func lookup(_ identifier: String) -> (note: NotesNoteRecord, snapshot: NotesLibrarySnapshot)? {
        if let snapshot = store.latestSnapshot, let note = snapshot.note(identifier: identifier) {
            return (note, snapshot)
        }
        return store.queue.sync {
            guard case .success(let snapshot) = store.currentSnapshot(),
                  let note = snapshot.note(identifier: identifier) else { return nil }
            return (note, snapshot)
        }
    }

    func detail(for note: NotesNoteRecord, snapshot: NotesLibrarySnapshot) -> NotesNoteDetail? {
        store.queue.sync { store.detail(for: note, snapshot: snapshot) }
    }

    func markdown(for detail: NotesNoteDetail) -> String {
        guard configuration.includeFrontMatter else { return detail.markdown }
        return frontMatter(for: detail.note) + detail.markdown
    }

    func frontMatter(for note: NotesNoteRecord) -> String {
        func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let dates = ISO8601DateFormatter()
        var lines = ["---", "title: \(quoted(note.title))", "folder: \(quoted(note.folderPath))"]
        if !note.tags.isEmpty { lines.append("tags: [" + note.tags.map(quoted).joined(separator: ", ") + "]") }
        if let created = note.created { lines.append("created: \(dates.string(from: created))") }
        if let modified = note.modified { lines.append("modified: \(dates.string(from: modified))") }
        lines.append("apple_notes_id: \(note.identifier)")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    func open(_ identifier: String) -> AppleNotesOutcome {
        guard let (note, snapshot) = lookup(identifier) else {
            return AppleNotesOutcome(success: false, message: "That note is no longer available.")
        }
        NotesAppBridge.showNote(snapshot.appleScriptID(for: note)) { result in
            if case .failure(let error) = result { AppleNotesAlerts.present(error, title: "Could Not Open Note") }
        }
        return AppleNotesOutcome(success: true, message: "Opening “\(note.title)” in Notes…")
    }

    func copyMarkdown(_ identifier: String) -> AppleNotesOutcome {
        withReadableDetail(identifier) { detail in
            copy(markdown(for: detail))
            return AppleNotesOutcome(success: true, message: "Copied “\(detail.note.title)” as Markdown.")
        }
    }

    func copyPlainText(_ identifier: String) -> AppleNotesOutcome {
        withReadableDetail(identifier) { detail in
            copy(detail.plainText)
            return AppleNotesOutcome(success: true, message: "Copied the text of “\(detail.note.title)”.")
        }
    }

    func exportMarkdown(_ identifier: String) -> AppleNotesOutcome {
        withReadableDetail(identifier) { detail in
            let folder = configuration.exportFolderURL
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = uniqueFileURL(in: folder, baseName: sanitizedFileName(detail.note.title))
                try markdown(for: detail).write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return AppleNotesOutcome(success: true, message: "Exported to \(AppleNotesFormatting.abbreviatedPath(url)).")
            } catch {
                return AppleNotesOutcome(success: false, message: "Export failed: \(error.localizedDescription)")
            }
        }
    }

    func delete(_ identifier: String) -> AppleNotesOutcome {
        guard let (note, snapshot) = lookup(identifier) else {
            return AppleNotesOutcome(success: false, message: "That note is no longer available.")
        }
        NotesAppBridge.delete(noteID: snapshot.appleScriptID(for: note)) { [weak self] result in
            if case .failure(let error) = result { AppleNotesAlerts.present(error, title: "Could Not Delete Note") }
            self?.libraryDidChange()
        }
        return AppleNotesOutcome(success: true, message: "Moving “\(note.title)” to Recently Deleted…")
    }

    func append(_ text: String, to identifier: String) -> AppleNotesOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AppleNotesOutcome(success: false, message: "Nothing to append.") }
        guard let (note, snapshot) = lookup(identifier) else {
            return AppleNotesOutcome(success: false, message: "That note is no longer available.")
        }
        guard note.canAppendThroughAppleScript else {
            return AppleNotesOutcome(
                success: false,
                message: "“\(note.title)” contains checklists, tags or attachments. Appending through AppleScript would rewrite them, so add the text in Notes instead."
            )
        }
        let html = "<div><br></div>" + NotesHTMLComposer.html(fromMarkdown: trimmed)
        NotesAppBridge.append(html: html, toNote: snapshot.appleScriptID(for: note)) { [weak self] result in
            if case .failure(let error) = result { AppleNotesAlerts.present(error, title: "Could Not Append to Note") }
            self?.libraryDidChange()
        }
        return AppleNotesOutcome(success: true, message: "Appending to “\(note.title)”…")
    }

    func move(_ identifier: String, toFolderPK folderValue: String) -> AppleNotesOutcome {
        guard let (note, snapshot) = lookup(identifier) else {
            return AppleNotesOutcome(success: false, message: "That note is no longer available.")
        }
        guard let folderPK = Int64(folderValue), let folder = snapshot.folders[folderPK] else {
            return AppleNotesOutcome(success: false, message: "Choose a folder.")
        }
        guard folderPK != note.folderPK else {
            return AppleNotesOutcome(success: true, message: "“\(note.title)” is already in \(folder.name).")
        }
        NotesAppBridge.move(noteID: snapshot.appleScriptID(for: note), toFolder: snapshot.appleScriptID(forFolder: folder)) { [weak self] result in
            if case .failure(let error) = result { AppleNotesAlerts.present(error, title: "Could Not Move Note") }
            self?.libraryDidChange()
        }
        return AppleNotesOutcome(success: true, message: "Moving “\(note.title)” to \(folder.name)…")
    }

    func create(title: String, body: String, folderValue: String?) -> AppleNotesOutcome {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else {
            return AppleNotesOutcome(success: false, message: "Enter a title or some text.")
        }
        var folderID: String?
        if let folderValue, let folderPK = Int64(folderValue),
           let snapshot = store.latestSnapshot, let folder = snapshot.folders[folderPK] {
            folderID = snapshot.appleScriptID(forFolder: folder)
        }
        var html = ""
        if !trimmedTitle.isEmpty { html += "<h1>\(NotesHTMLComposer.escape(trimmedTitle))</h1>" }
        if !trimmedBody.isEmpty { html += NotesHTMLComposer.html(fromMarkdown: trimmedBody) }
        let displayTitle = trimmedTitle.isEmpty ? "New Note" : trimmedTitle
        NotesAppBridge.createNote(folderID: folderID, html: html, show: configuration.showCreatedNote) { [weak self] result in
            if case .failure(let error) = result { AppleNotesAlerts.present(error, title: "Could Not Create Note") }
            self?.libraryDidChange()
        }
        return AppleNotesOutcome(success: true, message: "Creating “\(displayTitle)” in Notes…")
    }

    /// Folder choices for argument forms: "default" first, then real folders.
    func folderOptions(includeDefault: Bool) -> [[String: String]] {
        var options: [[String: String]] = includeDefault ? [["value": "default", "label": "Default Notes Folder"]] : []
        guard let snapshot = store.latestSnapshot else { return options }
        let multipleAccounts = Set(snapshot.regularFolders.compactMap(\.accountPK)).count > 1
        for folder in snapshot.regularFolders.prefix(99) {
            var label = folder.path
            if multipleAccounts, let account = folder.accountPK.flatMap({ snapshot.accounts[$0]?.name }) {
                label = "\(account) › \(label)"
            }
            options.append(["value": String(folder.pk), "label": label])
        }
        return options
    }

    func libraryDidChange() {
        store.invalidate()
        // Notes writes the change a moment after AppleScript returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.onLibraryChanged?()
        }
    }

    private func withReadableDetail(_ identifier: String, _ body: (NotesNoteDetail) -> AppleNotesOutcome) -> AppleNotesOutcome {
        guard let (note, snapshot) = lookup(identifier) else {
            return AppleNotesOutcome(success: false, message: "That note is no longer available.")
        }
        guard !note.isLocked else {
            return AppleNotesOutcome(success: false, message: "“\(note.title)” is locked. Open it in Notes to read it.")
        }
        guard let detail = detail(for: note, snapshot: snapshot), detail.isContentAvailable else {
            return AppleNotesOutcome(success: false, message: "Could not read “\(note.title)”.")
        }
        return body(detail)
    }

    private func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func sanitizedFileName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(120)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return limited.isEmpty ? "Note" : limited
    }

    private func uniqueFileURL(in folder: URL, baseName: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension("md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter)").appendingPathExtension("md")
            counter += 1
        }
        return candidate
    }
}

enum AppleNotesAlerts {
    static func present(_ error: Error, title: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if #available(macOS 14.0, *) {
                NSApp.activate()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            alert.runModal()
        }
    }
}

// MARK: - Launcher Plugin

private enum AppleNotesIDs {
    static let searchItem = "apple-notes"
    static let createItem = "apple-notes-create"
    static let accessItem = "apple-notes-access"
    static let notePrefix = "note:"
    static let browserSurface = "browser"
}

private enum AppleNotesAction {
    static let open = "open"
    static let create = "create"
    static let copyMarkdown = "copy-markdown"
    static let copyText = "copy-text"
    static let export = "export-markdown"
    static let append = "append"
    static let move = "move"
    static let delete = "delete"
    static let rebuild = "rebuild-index"
    static let openNotesApp = "open-notes-app"
    static let grantAccess = "grant-access"
}

/// How a typed launcher query maps to a notes search.
private struct AppleNotesInlineRequest {
    let query: NotesSearchQuery
    let limit: Int
    /// Keyword or structured searches add the typed query as a search alias so
    /// the launcher ranks every returned note as a confirmed match.
    let aliasQuery: String?
    let isExplicit: Bool

    init?(rawQuery: String, configuration: AppleNotesConfiguration) {
        let lowered = rawQuery.lowercased()
        for keyword in configuration.keywords.sorted(by: { $0.count > $1.count }) {
            // The launcher trims queries, so a bare keyword cannot be told
            // apart from "keyword ". Only longer keywords browse on their own,
            // and only pinned plus a few recent notes.
            if lowered == keyword, keyword.count >= 3 {
                var browse = NotesSearchQuery()
                browse.includeTrash = configuration.includeRecentlyDeleted
                self.query = browse
                self.limit = min(configuration.keywordLimit, 10)
                self.aliasQuery = lowered
                self.isExplicit = true
                return
            }
            guard lowered.hasPrefix(keyword + " ") else { continue }
            let remainder = String(rawQuery.dropFirst(keyword.count + 1))
            var query = NotesSearchQuery.parse(remainder)
            query.includeTrash = configuration.includeRecentlyDeleted
            self.query = query
            self.limit = configuration.keywordLimit
            self.aliasQuery = lowered
            self.isExplicit = true
            return
        }

        var query = NotesSearchQuery.parse(rawQuery)
        query.includeTrash = configuration.includeRecentlyDeleted
        if query.hasStructuredCriteria {
            self.query = query
            self.limit = configuration.keywordLimit
            self.aliasQuery = lowered
            self.isExplicit = true
            return
        }
        guard configuration.inlineLimit > 0, query.hasTextCriteria, rawQuery.count >= 2 else { return nil }
        query.titleOnly = !configuration.searchContentsInline || rawQuery.count < 3
        self.query = query
        self.limit = configuration.inlineLimit
        self.aliasQuery = nil
        self.isExplicit = false
    }
}

final class AppleNotesLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private let controller = AppleNotesController()
    private static let createPhrases = ["new note", "create note", "add note", "new apple note", "create apple note"]

    override init() {
        super.init()
        controller.onLibraryChanged = { [weak self] in
            self?.delegate?.requestLauncherResultsRefresh()
        }
    }

    static func launcherPluginName() -> String { "Apple Notes" }
    static func launcherPluginDescription() -> String {
        "Search, preview, export and create Apple Notes. Full-text search with tags, folders and filters."
    }
    static func launcherPluginIcon() -> String { "note.text" }

    static func configurationFormItems() -> BTTPluginFormItem? {
        let group = BTTPluginFormItem()
        group.formFieldType = BTTFormTypeFormGroup

        let description = BTTPluginFormItem()
        description.formFieldType = BTTFormTypeDescription
        description.formLabel1 = "Searching reads the local Notes library read-only and needs Full Disk Access for BetterTouchTool. Creating, appending, moving and deleting notes uses Notes' AppleScript interface. Type a keyword followed by a space (for example \"notes groceries\") or use #tag, in:folder, is:pinned and has:checklist."

        let keywords = BTTPluginFormItem()
        keywords.formFieldType = BTTFormTypeTextField
        keywords.formLabel1 = "Search Keywords"
        keywords.formFieldID = "keywords"
        keywords.defaultValue = "notes, n"

        let inlineLimit = BTTPluginFormItem()
        inlineLimit.formFieldType = BTTFormTypeSlider
        inlineLimit.formLabel1 = "Notes in Regular Results"
        inlineLimit.formFieldID = "inlineLimit"
        inlineLimit.dataType = BTTFormDataNumber
        inlineLimit.minValue = 0
        inlineLimit.maxValue = 15
        inlineLimit.defaultValue = 5

        let keywordLimit = BTTPluginFormItem()
        keywordLimit.formFieldType = BTTFormTypeSlider
        keywordLimit.formLabel1 = "Notes After a Keyword"
        keywordLimit.formFieldID = "keywordLimit"
        keywordLimit.dataType = BTTFormDataNumber
        keywordLimit.minValue = 5
        keywordLimit.maxValue = 100
        keywordLimit.defaultValue = 30

        let searchContents = BTTPluginFormItem()
        searchContents.formFieldType = BTTFormTypeCheckbox
        searchContents.formLabel1 = "Match note contents in regular results"
        searchContents.formFieldID = "searchContentsInline"
        searchContents.defaultValue = true

        let exportFolder = BTTPluginFormItem()
        exportFolder.formFieldType = BTTFormTypeTextField
        exportFolder.formLabel1 = "Markdown Export Folder"
        exportFolder.formFieldID = "exportFolder"
        exportFolder.defaultValue = "~/Downloads"

        let frontMatter = BTTPluginFormItem()
        frontMatter.formFieldType = BTTFormTypeCheckbox
        frontMatter.formLabel1 = "Add YAML front matter to Markdown"
        frontMatter.formFieldID = "includeFrontMatter"
        frontMatter.defaultValue = true

        let recentlyDeleted = BTTPluginFormItem()
        recentlyDeleted.formFieldType = BTTFormTypeCheckbox
        recentlyDeleted.formLabel1 = "Include Recently Deleted notes in results"
        recentlyDeleted.formFieldID = "includeRecentlyDeleted"
        recentlyDeleted.defaultValue = false

        let showCreated = BTTPluginFormItem()
        showCreated.formFieldType = BTTFormTypeCheckbox
        showCreated.formLabel1 = "Show newly created notes in Notes"
        showCreated.formFieldID = "showCreatedNote"
        showCreated.defaultValue = true

        group.formOptions = [
            description, keywords, inlineLimit, keywordLimit, searchContents,
            exportFolder, frontMatter, recentlyDeleted, showCreated,
        ]
        return group
    }

    func didReceiveNewConfigurationValues(_ configurationValues: [AnyHashable: Any]?) {
        let configuration = AppleNotesConfiguration(values: configurationValues ?? [:])
        if configuration != controller.configuration {
            controller.configuration = configuration
        }
    }

    // MARK: Results

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        rootResults()
    }

    func loadLauncherResults(
        for context: BTTLauncherPluginContext,
        completion: @escaping ([BTTLauncherPluginResult]?) -> Void
    ) {
        let rawQuery = (context.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var results = rootResults()
        // The launcher also asks for empty-query results on every keystroke,
        // so that path never touches the library.
        guard !rawQuery.isEmpty else {
            completion(results)
            return
        }
        if let create = createResult(for: rawQuery) { results.append(create) }
        guard let request = AppleNotesInlineRequest(rawQuery: rawQuery, configuration: controller.configuration) else {
            completion(results)
            return
        }

        let store = controller.store
        store.withSnapshot { outcome in
            var noteResults: [BTTLauncherPluginResult] = []
            switch outcome {
            case .success(let snapshot):
                let hits = NotesSearchEngine.search(request.query, in: snapshot, limit: request.limit)
                let bodyHits = hits.filter { !$0.matchedTitle }.map(\.note)
                let texts = bodyHits.isEmpty ? [:] : store.plainTexts(for: bodyHits, snapshot: snapshot)
                for hit in hits {
                    let snippet = hit.matchedTitle ? nil : texts[hit.note.pk].flatMap {
                        NotesSnippet.excerpt(from: $0, terms: request.query.highlightTerms)
                    }
                    noteResults.append(Self.noteResult(hit, snippet: snippet, request: request))
                }
            case .failure(let error):
                if request.isExplicit { noteResults.append(Self.accessResult(error)) }
            }
            DispatchQueue.main.async { completion(results + noteResults) }
        }
    }

    private func rootResults() -> [BTTLauncherPluginResult] {
        let search = BTTLauncherPluginResult()
        search.itemIdentifier = AppleNotesIDs.searchItem
        search.title = "Search Apple Notes"
        if let error = controller.store.latestError {
            search.subtitle = error == .needsFullDiskAccess
                ? "Needs Full Disk Access for BetterTouchTool. Open to set up."
                : error.title
        } else if let snapshot = controller.store.latestSnapshot {
            search.subtitle = "\(snapshot.visibleNoteCount) notes · #tag, in:folder, is:pinned, has:checklist"
        } else {
            search.subtitle = "Full-text search with #tag, in:folder, is:pinned and has:checklist"
        }
        search.iconImage = AppleNotesFormatting.notesAppIcon
        search.keywords = ["notes", "apple notes", "search notes", "find note", "notes browser"] + controller.configuration.keywords
        search.surfaceIdentifier = AppleNotesIDs.browserSurface
        search.trailingHint = "Open"
        search.commands = [
            Self.command(AppleNotesAction.create, "Create Note…", "Title, Markdown text and folder.", "square.and.pencil",
                         shortcut: Self.shortcut("n", [.command, .shift], ["⌘", "⇧", "N"])),
            Self.command(AppleNotesAction.openNotesApp, "Open Notes", nil, "arrow.up.forward.app", closes: true),
            Self.command(AppleNotesAction.rebuild, "Rebuild Index", "Reads the Notes library again.", "arrow.clockwise"),
        ]
        return [search]
    }

    private func createResult(for rawQuery: String) -> BTTLauncherPluginResult? {
        let lowered = rawQuery.lowercased()
        guard lowered.count >= 3, Self.createPhrases.contains(where: { $0.hasPrefix(lowered) || lowered.hasPrefix($0 + " ") }) else {
            return nil
        }
        let create = BTTLauncherPluginResult()
        create.itemIdentifier = AppleNotesIDs.createItem
        create.title = "Create Apple Note"
        create.subtitle = "Title, Markdown text and folder"
        create.systemImageName = "square.and.pencil"
        create.keywords = Self.createPhrases + [lowered]
        create.primaryActionIdentifier = AppleNotesAction.create
        create.searchMatchPriority = NSNumber(value: 80)
        return create
    }

    private static func noteResult(_ hit: NotesSearchHit, snippet: String?, request: AppleNotesInlineRequest) -> BTTLauncherPluginResult {
        let note = hit.note
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = AppleNotesIDs.notePrefix + note.identifier
        result.title = note.title
        var parts = [note.folderName]
        if let modified = note.modified { parts.append(AppleNotesFormatting.shortDate(modified)) }
        if note.isLocked {
            parts.append("Locked")
        } else if let text = snippet ?? (note.snippet.isEmpty ? nil : note.snippet) {
            parts.append(text)
        }
        result.subtitle = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        result.systemImageName = AppleNotesFormatting.symbol(for: note)
        if let alias = request.aliasQuery { result.keywords = [alias] }
        result.trailingHint = note.isPinned ? "Pinned" : nil
        result.primaryActionIdentifier = AppleNotesAction.open
        result.searchMatchPriority = NSNumber(value: launcherScore(for: hit, request: request))
        result.commands = noteCommands(for: note)
        return result
    }

    /// Maps engine scores onto the launcher's buckets (>= 90 exact, >= 60
    /// prefix, >= 30 substring, below that fuzzy). Body-only matches stay low
    /// in regular results so apps and commands keep their place.
    private static func launcherScore(for hit: NotesSearchHit, request: AppleNotesInlineRequest) -> Int {
        if request.isExplicit { return hit.score >= 85 ? 90 : 75 }
        switch hit.score {
        case 100: return 92
        case 85...: return 78
        case 72...: return 66
        case 40...: return 40
        default: return 20
        }
    }

    private static func noteCommands(for note: NotesNoteRecord) -> [BTTLauncherPluginCommand] {
        let preview = command(nil, "Preview", "Shows the note in the Apple Notes browser.", "eye",
                              shortcut: shortcut("y", [.command], ["⌘", "Y"]))
        preview.surfaceIdentifier = AppleNotesIDs.browserSurface
        var commands = [preview]
        if !note.isLocked {
            commands += [
                command(AppleNotesAction.copyMarkdown, "Copy as Markdown", "Includes tables, checklists and links.", "doc.on.doc",
                        shortcut: shortcut("c", [.command], ["⌘", "C"]), closes: true),
                command(AppleNotesAction.copyText, "Copy Plain Text", nil, "text.alignleft",
                        shortcut: shortcut("c", [.command, .shift], ["⌘", "⇧", "C"]), closes: true),
                command(AppleNotesAction.export, "Export as Markdown File", nil, "square.and.arrow.down",
                        shortcut: shortcut("e", [.command], ["⌘", "E"])),
            ]
        }
        if note.canAppendThroughAppleScript {
            commands.append(command(AppleNotesAction.append, "Append Text…", "Adds text to the end of the note.", "text.append",
                                    shortcut: shortcut("a", [.command, .shift], ["⌘", "⇧", "A"])))
        }
        if !note.isInTrash {
            commands.append(command(AppleNotesAction.move, "Move to Folder…", nil, "folder",
                                    shortcut: shortcut("m", [.command, .shift], ["⌘", "⇧", "M"])))
            let delete = command(AppleNotesAction.delete, "Delete Note", "Moves the note to Recently Deleted.", "trash",
                                 shortcut: keyShortcut(51, [.command], ["⌘", "⌫"]))
            delete.destructive = true
            commands.append(delete)
        }
        return commands
    }

    private static func accessResult(_ error: NotesLibraryError) -> BTTLauncherPluginResult {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = AppleNotesIDs.accessItem
        result.title = error.title
        result.subtitle = error == .needsFullDiskAccess
            ? "Allow BetterTouchTool in Privacy & Security › Full Disk Access to search notes."
            : error.message
        result.systemImageName = error == .needsFullDiskAccess ? "lock.shield" : "exclamationmark.triangle"
        result.primaryActionIdentifier = error == .needsFullDiskAccess ? AppleNotesAction.grantAccess : AppleNotesAction.rebuild
        result.searchMatchPriority = NSNumber(value: 75)
        return result
    }

    // MARK: Actions

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {
        let action = actionIdentifier ?? AppleNotesAction.open
        if itemIdentifier.hasPrefix(AppleNotesIDs.notePrefix) {
            let identifier = String(itemIdentifier.dropFirst(AppleNotesIDs.notePrefix.count))
            switch action {
            case AppleNotesAction.open:
                return Self.actionResult(controller.open(identifier), closeOnSuccess: true)
            case AppleNotesAction.copyMarkdown:
                return Self.actionResult(controller.copyMarkdown(identifier), closeOnSuccess: true)
            case AppleNotesAction.copyText:
                return Self.actionResult(controller.copyPlainText(identifier), closeOnSuccess: true)
            case AppleNotesAction.export:
                return Self.actionResult(controller.exportMarkdown(identifier), closeOnSuccess: false)
            case AppleNotesAction.delete:
                return Self.actionResult(controller.delete(identifier), closeOnSuccess: false)
            default:
                return Self.actionResult(AppleNotesOutcome(success: false, message: "This action needs more input."), closeOnSuccess: false)
            }
        }

        switch action {
        case AppleNotesAction.rebuild:
            controller.store.invalidate()
            controller.store.withSnapshot(forceReload: true) { [weak self] _ in
                DispatchQueue.main.async { self?.delegate?.requestLauncherResultsRefresh() }
            }
            return Self.actionResult(AppleNotesOutcome(success: true, message: "Reading the Notes library again…"), closeOnSuccess: false)
        case AppleNotesAction.openNotesApp:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return Self.actionResult(AppleNotesOutcome(success: true, message: "Opening Notes…"), closeOnSuccess: true)
        case AppleNotesAction.grantAccess:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
            controller.store.invalidate()
            return Self.actionResult(
                AppleNotesOutcome(success: true, message: "Add BetterTouchTool to Full Disk Access, then search again."),
                closeOnSuccess: true
            )
        default:
            return Self.actionResult(AppleNotesOutcome(success: false, message: "This action needs more input."), closeOnSuccess: false)
        }
    }

    func launcherArgumentRequest(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> [String: Any]? {
        switch actionIdentifier {
        case AppleNotesAction.create:
            var fields: [[String: Any]] = [
                ["name": "title", "label": "Title", "kind": "text", "required": false],
                ["name": "body", "label": "Text (Markdown)", "kind": "text", "required": false],
            ]
            let folders = controller.folderOptions(includeDefault: true)
            if folders.count > 1 {
                fields.append(["name": "folder", "label": "Folder", "kind": "choice", "required": true,
                               "defaultValue": "default", "options": folders])
            }
            var payload: [String: Any] = [
                "id": "apple-notes-create",
                "title": "Create Apple Note",
                "fields": fields,
                "contextKeys": ["selectedText"],
                "contextBindings": ["body": "selectedText"],
            ]
            if let seed = createSeed(from: context.query) { payload["seedText"] = seed }
            return payload

        case AppleNotesAction.append:
            guard itemIdentifier.hasPrefix(AppleNotesIDs.notePrefix),
                  let (note, _) = controller.lookup(String(itemIdentifier.dropFirst(AppleNotesIDs.notePrefix.count))) else { return nil }
            return [
                "id": "apple-notes-append",
                "title": "Append to “\(note.title)”",
                "fields": [["name": "text", "label": "Text (Markdown)", "kind": "text", "required": true]],
                "contextKeys": ["selectedText"],
                "contextBindings": ["text": "selectedText"],
            ]

        case AppleNotesAction.move:
            guard itemIdentifier.hasPrefix(AppleNotesIDs.notePrefix),
                  let (note, _) = controller.lookup(String(itemIdentifier.dropFirst(AppleNotesIDs.notePrefix.count))) else { return nil }
            let folders = controller.folderOptions(includeDefault: false)
            guard !folders.isEmpty else { return nil }
            let current = note.folderPK.map(String.init)
            let defaultValue = folders.contains { $0["value"] == current } ? current : folders.first?["value"]
            var field: [String: Any] = ["name": "folder", "label": "Folder", "kind": "choice", "required": true, "options": folders]
            if let defaultValue { field["defaultValue"] = defaultValue }
            return ["id": "apple-notes-move", "title": "Move “\(note.title)”", "fields": [field]]

        default:
            return nil
        }
    }

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext,
        argumentValues: [String: String],
        capturedContext: [String: String]
    ) -> BTTLauncherPluginActionResult? {
        let noteIdentifier = itemIdentifier.hasPrefix(AppleNotesIDs.notePrefix)
            ? String(itemIdentifier.dropFirst(AppleNotesIDs.notePrefix.count))
            : nil
        switch actionIdentifier {
        case AppleNotesAction.create:
            let folder = argumentValues["folder"].flatMap { $0 == "default" ? nil : $0 }
            let outcome = controller.create(title: argumentValues["title"] ?? "", body: argumentValues["body"] ?? "", folderValue: folder)
            return Self.actionResult(outcome, closeOnSuccess: true)
        case AppleNotesAction.append:
            guard let noteIdentifier else { return nil }
            return Self.actionResult(controller.append(argumentValues["text"] ?? "", to: noteIdentifier), closeOnSuccess: true)
        case AppleNotesAction.move:
            guard let noteIdentifier else { return nil }
            return Self.actionResult(controller.move(noteIdentifier, toFolderPK: argumentValues["folder"] ?? ""), closeOnSuccess: false)
        default:
            return nil
        }
    }

    func launcherSurface(
        forItemIdentifier itemIdentifier: String,
        surfaceIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard surfaceIdentifier == AppleNotesIDs.browserSurface else { return nil }
        let focus = itemIdentifier.hasPrefix(AppleNotesIDs.notePrefix)
            ? String(itemIdentifier.dropFirst(AppleNotesIDs.notePrefix.count))
            : nil
        return AppleNotesBrowserSurface(controller: controller, focusIdentifier: focus)
    }

    // MARK: Helpers

    private func createSeed(from query: String?) -> String? {
        let raw = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = raw.lowercased()
        for phrase in Self.createPhrases where lowered.hasPrefix(phrase + " ") {
            let seed = String(raw.dropFirst(phrase.count + 1)).trimmingCharacters(in: .whitespaces)
            return seed.isEmpty ? nil : seed
        }
        return nil
    }

    private static func actionResult(_ outcome: AppleNotesOutcome, closeOnSuccess: Bool) -> BTTLauncherPluginActionResult {
        let result = BTTLauncherPluginActionResult()
        result.success = outcome.success
        result.message = outcome.message
        result.closeLauncher = outcome.success && closeOnSuccess
        return result
    }

    private static func command(
        _ identifier: String?,
        _ title: String,
        _ subtitle: String?,
        _ systemImage: String,
        shortcut: BTTLauncherPluginShortcut? = nil,
        closes: Bool = false
    ) -> BTTLauncherPluginCommand {
        let command = BTTLauncherPluginCommand()
        command.commandIdentifier = identifier ?? title.lowercased()
        command.title = title
        command.subtitle = subtitle
        command.systemImageName = systemImage
        command.shortcut = shortcut
        command.closesLauncherOnSuccess = closes
        return command
    }

    private static func shortcut(_ character: String, _ modifiers: NSEvent.ModifierFlags, _ displayKeys: [String]) -> BTTLauncherPluginShortcut {
        let shortcut = BTTLauncherPluginShortcut()
        shortcut.character = character
        shortcut.modifierFlags = modifiers
        shortcut.displayKeys = displayKeys
        return shortcut
    }

    private static func keyShortcut(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags, _ displayKeys: [String]) -> BTTLauncherPluginShortcut {
        let shortcut = BTTLauncherPluginShortcut()
        shortcut.keyCode = NSNumber(value: keyCode)
        shortcut.modifierFlags = modifiers
        shortcut.displayKeys = displayKeys
        return shortcut
    }
}

// MARK: - Notes Browser Surface

private typealias AppleNotesState<Value> = SwiftUI.State<Value>

enum AppleNotesScope: Hashable {
    case all
    case pinned
    case recentlyDeleted
    case folder(Int64)
    case tag(String)
}

final class AppleNotesBrowserModel: ObservableObject {
    struct SidebarFolder: Identifiable {
        let id: Int64
        let name: String
        let depth: Int
        let count: Int
        let accountHeader: String?
    }

    @Published private(set) var hits: [NotesSearchHit] = []
    @Published private(set) var selectedIndex: Int?
    @Published private(set) var snippets: [Int64: String] = [:]
    @Published private(set) var preview = NSAttributedString()
    @Published private(set) var previewToken = 0
    @Published private(set) var scope: AppleNotesScope = .all
    @Published private(set) var sidebarFolders: [SidebarFolder] = []
    @Published private(set) var sidebarTags: [NotesTagCount] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var pinnedCount = 0
    @Published private(set) var trashCount = 0
    @Published private(set) var error: NotesLibraryError?
    @Published private(set) var isLoading = true
    @Published private(set) var message: String?

    var onPresentationChange: (() -> Void)?

    private let controller: AppleNotesController
    private var queryText = ""
    private var focusIdentifier: String?
    private var snapshot: NotesLibrarySnapshot?
    private var searchGeneration = 0
    private var previewGeneration = 0
    private var pendingSearch: DispatchWorkItem?
    private var messageGeneration = 0
    private static let renderQueue = DispatchQueue(label: "com.folivora.btt.launcher.applenotes.render", qos: .userInitiated)

    init(controller: AppleNotesController, focusIdentifier: String?) {
        self.controller = controller
        self.focusIdentifier = focusIdentifier
    }

    var selectedHit: NotesSearchHit? {
        guard let selectedIndex, hits.indices.contains(selectedIndex) else { return nil }
        return hits[selectedIndex]
    }

    var listTitle: String {
        switch scope {
        case .all: return "All Notes"
        case .pinned: return "Pinned"
        case .recentlyDeleted: return "Recently Deleted"
        case .folder(let pk): return sidebarFolders.first { $0.id == pk }?.name ?? "Folder"
        case .tag(let name): return "#" + name
        }
    }

    var statusText: String? {
        if let message { return message }
        if let error { return error.title }
        if isLoading, snapshot == nil { return "Reading Apple Notes…" }
        return hits.count == 1 ? "1 note" : "\(hits.count) notes"
    }

    func activate() {
        scheduleSearch(delay: 0)
    }

    func deactivate() {
        pendingSearch?.cancel()
    }

    func setQuery(_ text: String) {
        guard text != queryText else { return }
        queryText = text
        scheduleSearch(delay: 0.06)
    }

    func setScope(_ newScope: AppleNotesScope) {
        scope = newScope
        scheduleSearch(delay: 0)
    }

    func reload() {
        error = nil
        isLoading = true
        controller.store.invalidate()
        scheduleSearch(delay: 0)
    }

    func select(index: Int) {
        guard hits.indices.contains(index), selectedIndex != index else { return }
        selectedIndex = index
        loadPreview()
    }

    func moveSelection(by delta: Int) {
        guard !hits.isEmpty else { return }
        let current = selectedIndex ?? (delta > 0 ? -1 : hits.count)
        select(index: min(max(current + delta, 0), hits.count - 1))
    }

    @discardableResult
    func openSelected() -> Bool {
        guard let hit = selectedHit else { return false }
        return finish(controller.open(hit.note.identifier))
    }

    @discardableResult
    func copySelectedMarkdown() -> Bool {
        guard let hit = selectedHit else { return false }
        return finish(controller.copyMarkdown(hit.note.identifier))
    }

    @discardableResult
    func copySelectedPlainText() -> Bool {
        guard let hit = selectedHit else { return false }
        return finish(controller.copyPlainText(hit.note.identifier))
    }

    @discardableResult
    func exportSelected() -> Bool {
        guard let hit = selectedHit else { return false }
        return finish(controller.exportMarkdown(hit.note.identifier))
    }

    func metadataLine(for note: NotesNoteRecord) -> String {
        var parts = [note.folderPath]
        if let modified = note.modified { parts.append("Edited \(AppleNotesFormatting.longDate(modified))") }
        if let created = note.created { parts.append("Created \(AppleNotesFormatting.longDate(created))") }
        if note.attachmentCount > 0 { parts.append(note.attachmentCount == 1 ? "1 attachment" : "\(note.attachmentCount) attachments") }
        if note.isShared { parts.append("Shared") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func finish(_ outcome: AppleNotesOutcome) -> Bool {
        showMessage(outcome.message)
        return outcome.success
    }

    private func showMessage(_ text: String) {
        messageGeneration += 1
        let generation = messageGeneration
        message = text
        onPresentationChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.messageGeneration == generation else { return }
            self.message = nil
            self.onPresentationChange?()
        }
    }

    private func scheduleSearch(delay: TimeInterval) {
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performSearch() }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performSearch() {
        searchGeneration += 1
        let generation = searchGeneration
        let text = queryText
        let scope = self.scope
        let focus = focusIdentifier
        let includeTrash = controller.configuration.includeRecentlyDeleted
        let store = controller.store

        store.withSnapshot { [weak self] outcome in
            switch outcome {
            case .success(let snapshot):
                var query = NotesSearchQuery.parse(text)
                switch scope {
                case .all: query.includeTrash = query.includeTrash || includeTrash
                case .pinned: query.pinned = true
                case .recentlyDeleted: query.onlyTrash = true
                case .folder(let pk): query.folderPKs = snapshot.folderAndDescendants(pk)
                case .tag(let name): query.tags.append(NotesTextFolding.fold(name))
                }
                var hits = NotesSearchEngine.search(query, in: snapshot, limit: 500)
                if let focus, query.isEmpty || scope == .all, !hits.contains(where: { $0.note.identifier == focus }),
                   let note = snapshot.note(identifier: focus) {
                    hits.insert(NotesSearchHit(note: note, score: 100, matchedTitle: true), at: 0)
                }
                let snippetNotes = hits.prefix(80).filter { !$0.matchedTitle }.map(\.note)
                let texts = snippetNotes.isEmpty ? [:] : store.plainTexts(for: snippetNotes, snapshot: snapshot)
                var snippets: [Int64: String] = [:]
                for note in snippetNotes {
                    if let text = texts[note.pk], let excerpt = NotesSnippet.excerpt(from: text, terms: query.highlightTerms) {
                        snippets[note.pk] = excerpt
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.searchGeneration == generation else { return }
                    self.apply(snapshot: snapshot, hits: hits, snippets: snippets, focus: focus)
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    guard let self, self.searchGeneration == generation else { return }
                    self.error = error
                    self.isLoading = false
                    self.hits = []
                    self.selectedIndex = nil
                    self.onPresentationChange?()
                }
            }
        }
    }

    private func apply(snapshot: NotesLibrarySnapshot, hits: [NotesSearchHit], snippets: [Int64: String], focus: String?) {
        if self.snapshot?.loadedAt != snapshot.loadedAt { updateSidebar(from: snapshot) }
        self.snapshot = snapshot
        error = nil
        isLoading = false

        let previousIdentifier = selectedHit?.note.identifier
        self.hits = hits
        self.snippets = snippets
        let target = focus ?? previousIdentifier
        if let target, let index = hits.firstIndex(where: { $0.note.identifier == target }) {
            selectedIndex = index
        } else {
            selectedIndex = hits.isEmpty ? nil : 0
        }
        focusIdentifier = nil
        loadPreview()
        onPresentationChange?()
    }

    private func updateSidebar(from snapshot: NotesLibrarySnapshot) {
        totalCount = snapshot.visibleNoteCount
        pinnedCount = snapshot.notes.lazy.filter { $0.isPinned && !$0.isInTrash }.count
        trashCount = snapshot.notes.lazy.filter { $0.isInTrash }.count
        sidebarTags = snapshot.tagCounts
        let multipleAccounts = Set(snapshot.regularFolders.compactMap(\.accountPK)).count > 1
        var lastAccount: Int64?
        sidebarFolders = snapshot.regularFolders.map { folder in
            var header: String?
            if multipleAccounts, folder.accountPK != lastAccount {
                header = folder.accountPK.flatMap { snapshot.accounts[$0]?.name } ?? "On My Mac"
                lastAccount = folder.accountPK
            }
            return SidebarFolder(id: folder.pk, name: folder.name, depth: folder.depth,
                                 count: snapshot.folderNoteCounts[folder.pk] ?? 0, accountHeader: header)
        }
    }

    private func loadPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        guard let note = selectedHit?.note, let snapshot else {
            preview = NSAttributedString()
            previewToken += 1
            return
        }
        let store = controller.store
        store.queue.async { [weak self] in
            let detail = store.detail(for: note, snapshot: snapshot)
            Self.renderQueue.async {
                let rendered = NotesPreviewRenderer.render(detail: detail, note: note)
                DispatchQueue.main.async {
                    guard let self, self.previewGeneration == generation else { return }
                    self.preview = rendered
                    self.previewToken += 1
                }
            }
        }
    }
}

final class AppleNotesBrowserSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?

    private let model: AppleNotesBrowserModel
    private lazy var hostingView: NSView = NSHostingView(rootView: AppleNotesBrowserView(model: model))

    init(controller: AppleNotesController, focusIdentifier: String?) {
        model = AppleNotesBrowserModel(controller: controller, focusIdentifier: focusIdentifier)
        super.init()
        model.onPresentationChange = { [weak self] in
            self?.delegate?.requestLauncherSurfaceUpdate()
        }
    }

    func makeLauncherSurfaceView() -> NSView { hostingView }
    func launcherSurfaceDidAppear() { model.activate() }
    func launcherSurfaceWillDisappear() { model.deactivate() }
    func launcherSurfaceQueryDidChange(_ query: String?) { model.setQuery(query ?? "") }

    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        let result = BTTLauncherPluginSurfaceCommandResult()
        switch command {
        case .moveUp:
            model.moveSelection(by: -1)
        case .moveDown:
            model.moveSelection(by: 1)
        case .activateSelection:
            guard model.openSelected() else { return nil }
            result.closeLauncher = true
        case .alternateActivateSelection, .copySelection:
            guard model.copySelectedMarkdown() else { return nil }
        default:
            return nil
        }
        result.handled = true
        return result
    }

    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command], key == "e" { return model.exportSelected() }
        if modifiers == [.command, .shift], key == "c" { return model.copySelectedPlainText() }
        return false
    }

    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool { false }
    func launcherSurfacePlaceholderText() -> String? { "Search Apple Notes  ·  #tag  in:folder  is:pinned  has:checklist  -exclude" }
    func launcherSurfaceFooterHint() -> String? { "↑↓ Select · ↩ Open in Notes · ⌘C Markdown · ⇧⌘C Text · ⌘E Export · Esc Back" }
    func launcherSurfaceStatusText() -> String? { model.statusText }
    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 1060, height: 660) }
    func launcherSurfaceMinimumContentSize() -> CGSize { CGSize(width: 780, height: 440) }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }
}

struct AppleNotesBrowserView: View {
    @ObservedObject var model: AppleNotesBrowserModel

    var body: some View {
        Group {
            if let error = model.error {
                AppleNotesErrorView(error: error) { model.reload() }
            } else {
                HStack(spacing: 0) {
                    AppleNotesSidebar(model: model)
                        .frame(width: 200)
                    Divider()
                    AppleNotesResultList(model: model)
                        .frame(width: 310)
                    Divider()
                    AppleNotesPreviewPane(model: model)
                        .frame(minWidth: 260, maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppleNotesSidebar: View {
    @ObservedObject var model: AppleNotesBrowserModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                row(.all, title: "All Notes", icon: "tray.full", count: model.totalCount)
                if model.pinnedCount > 0 {
                    row(.pinned, title: "Pinned", icon: "pin", count: model.pinnedCount)
                }
                if model.trashCount > 0 {
                    row(.recentlyDeleted, title: "Recently Deleted", icon: "trash", count: model.trashCount)
                }
                header("Folders")
                ForEach(model.sidebarFolders) { folder in
                    if let account = folder.accountHeader {
                        Text(account)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                    }
                    row(.folder(folder.id), title: folder.name, icon: "folder", count: folder.count, indent: folder.depth)
                }
                if !model.sidebarTags.isEmpty {
                    header("Tags")
                    ForEach(model.sidebarTags, id: \.self) { tag in
                        row(.tag(tag.name), title: "#" + tag.name, icon: "number", count: tag.count)
                    }
                }
            }
            .padding(8)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func row(_ scope: AppleNotesScope, title: String, icon: String, count: Int, indent: Int = 0) -> some View {
        Button {
            model.setScope(scope)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(indent) * 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(model.scope == scope ? Color.accentColor.opacity(0.2) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct AppleNotesResultList: View {
    @ObservedObject var model: AppleNotesBrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.listTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("\(model.hits.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if model.isLoading, model.hits.isEmpty {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else if model.hits.isEmpty {
                Spacer()
                Text("No matching notes")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.hits.enumerated()), id: \.element.note.pk) { index, hit in
                                AppleNotesResultRow(
                                    note: hit.note,
                                    snippet: model.snippets[hit.note.pk],
                                    isSelected: model.selectedIndex == index
                                )
                                .id(hit.note.pk)
                                .contentShape(Rectangle())
                                .onTapGesture { model.select(index: index) }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    model.select(index: index)
                                    model.openSelected()
                                })
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .onReceive(model.$selectedIndex) { index in
                        guard let index, model.hits.indices.contains(index) else { return }
                        let identifier = model.hits[index].note.pk
                        DispatchQueue.main.async { proxy.scrollTo(identifier) }
                    }
                }
            }
        }
    }
}

struct AppleNotesResultRow: View {
    let note: NotesNoteRecord
    let snippet: String?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if note.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.orange)
                }
                if note.isLocked {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundColor(.secondary)
                }
                Text(note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            Text(metadata)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if let preview = snippet ?? (note.snippet.isEmpty || note.isLocked ? nil : note.snippet) {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        )
    }

    private var metadata: String {
        var parts = [note.folderName]
        if let modified = note.modified { parts.insert(AppleNotesFormatting.shortDate(modified), at: 0) }
        if !note.tags.isEmpty { parts.append(note.tags.prefix(3).map { "#" + $0 }.joined(separator: " ")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct AppleNotesPreviewPane: View {
    @ObservedObject var model: AppleNotesBrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note = model.selectedHit?.note {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.metadataLine(for: note))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        if !note.tags.isEmpty {
                            Text(note.tags.map { "#" + $0 }.joined(separator: "  "))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.accentColor)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Button { model.openSelected() } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Open in Notes (↩)")
                    if !note.isLocked {
                        Button { model.copySelectedMarkdown() } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy as Markdown (⌘C)")
                        Button { model.exportSelected() } label: { Image(systemName: "square.and.arrow.down") }
                            .help("Export as Markdown (⌘E)")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Divider()
                NotesPreviewTextView(text: model.preview, token: model.previewToken)
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Text(model.isLoading ? "Reading Apple Notes…" : "No note selected")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                Spacer()
            }
        }
    }
}

struct AppleNotesErrorView: View {
    let error: NotesLibraryError
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: error == .needsFullDiskAccess ? "lock.shield" : "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(error.title)
                .font(.system(size: 15, weight: .semibold))
            Text(error.message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 10) {
                if error == .needsFullDiskAccess {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Button("Try Again", action: retry)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Read-only TextKit 1 text view (NSTextTable needs TextKit 1).
struct NotesPreviewTextView: NSViewRepresentable {
    let text: NSAttributedString
    let token: Int

    final class Coordinator {
        var token = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.token != token, let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.token = token
        textView.textStorage?.setAttributedString(text)
        textView.scroll(.zero)
    }
}

/// Renders a note for the browser preview.
enum NotesPreviewRenderer {
    private static let imageCache = NSCache<NSURL, NSImage>()
    private static let maxImageWidth: CGFloat = 440
    private static let maxImageHeight: CGFloat = 360

    static func render(detail: NotesNoteDetail?, note: NotesNoteRecord) -> NSAttributedString {
        let output = NSMutableAttributedString()
        guard let detail, detail.isContentAvailable else {
            let message = note.isLocked
                ? "🔒 This note is locked. Open it in Notes to view it."
                : "This note could not be read."
            output.append(NSAttributedString(string: message, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            return output
        }

        var numberCounters: [Int: Int] = [:]
        for paragraph in detail.paragraphs {
            let style = paragraph.style
            if style.styleType != NotesParagraphStyle.numbered {
                numberCounters = numberCounters.filter { style.isList && $0.key < style.indent }
            }
            if let rows = NotesMarkdownRenderer.soleTableRows(in: paragraph, attachments: detail.attachments) {
                output.append(table(rows))
                continue
            }

            let baseFont = font(for: style)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.paragraphSpacing = style.isHeading ? 6 : 3
            paragraphStyle.lineHeightMultiple = 1.08
            let indentWidth: CGFloat = 22
            var prefix = ""
            if style.isList {
                let level = CGFloat(style.indent)
                paragraphStyle.firstLineHeadIndent = level * indentWidth
                paragraphStyle.headIndent = (level + 1) * indentWidth
                paragraphStyle.tabStops = [NSTextTab(textAlignment: .left, location: (level + 1) * indentWidth)]
                switch style.styleType {
                case NotesParagraphStyle.bulleted:
                    prefix = "•\t"
                case NotesParagraphStyle.dashed:
                    prefix = "–\t"
                case NotesParagraphStyle.numbered:
                    let number = (numberCounters[style.indent] ?? ((style.listStartNumber ?? 1) - 1)) + 1
                    numberCounters[style.indent] = number
                    numberCounters = numberCounters.filter { $0.key <= style.indent }
                    prefix = "\(number).\t"
                default:
                    prefix = style.isChecked ? "☑\t" : "☐\t"
                }
            }
            if style.isBlockQuote {
                paragraphStyle.firstLineHeadIndent += 14
                paragraphStyle.headIndent += 14
            }

            let line = NSMutableAttributedString()
            var baseAttributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: style.isBlockQuote || (style.styleType == NotesParagraphStyle.checklist && style.isChecked)
                    ? NSColor.secondaryLabelColor
                    : NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
            if style.styleType == NotesParagraphStyle.monospaced {
                baseAttributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            }
            if !prefix.isEmpty {
                var prefixAttributes = baseAttributes
                if style.styleType == NotesParagraphStyle.checklist {
                    prefixAttributes[.foregroundColor] = style.isChecked ? NSColor.systemOrange : NSColor.secondaryLabelColor
                }
                line.append(NSAttributedString(string: prefix, attributes: prefixAttributes))
            }
            for segment in NotesMarkdownRenderer.merged(paragraph.segments) {
                if let identifier = segment.run.attachmentIdentifier {
                    for character in segment.text {
                        if character == NotesDocumentLayout.attachmentCharacter {
                            line.append(attachment(detail.attachments[identifier], attributes: baseAttributes))
                        } else {
                            line.append(NSAttributedString(string: String(character), attributes: baseAttributes))
                        }
                    }
                    continue
                }
                line.append(NSAttributedString(string: segment.text, attributes: inlineAttributes(segment.run, base: baseAttributes, font: baseFont)))
            }
            line.append(NSAttributedString(string: "\n", attributes: baseAttributes))
            output.append(line)
        }
        return output
    }

    private static func font(for style: NotesParagraphStyle) -> NSFont {
        switch style.styleType {
        case NotesParagraphStyle.title: return NSFont.systemFont(ofSize: 22, weight: .bold)
        case NotesParagraphStyle.heading: return NSFont.systemFont(ofSize: 17, weight: .bold)
        case NotesParagraphStyle.subheading: return NSFont.systemFont(ofSize: 14, weight: .semibold)
        case NotesParagraphStyle.monospaced: return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        default: return NSFont.systemFont(ofSize: 13)
        }
    }

    private static func inlineAttributes(_ run: NotesTextRun, base: [NSAttributedString.Key: Any], font: NSFont) -> [NSAttributedString.Key: Any] {
        var attributes = base
        // Rendering runs off the main thread, so use descriptors rather than NSFontManager.
        var traits = font.fontDescriptor.symbolicTraits
        if run.isBold { traits.insert(.bold) }
        if run.isItalic { traits.insert(.italic) }
        if traits != font.fontDescriptor.symbolicTraits,
           let styledFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) {
            attributes[.font] = styledFont
        }
        if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.isStrikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if run.highlight != nil { attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.35) }
        if let link = run.link, let url = URL(string: link) { attributes[.link] = url }
        return attributes
    }

    private static func attachment(_ attachment: NotesAttachment?, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        guard let attachment else { return NSAttributedString() }
        var attributes = attributes
        switch attachment.kind {
        case .hashtag, .mention, .inline:
            attributes[.foregroundColor] = NSColor.controlAccentColor
            return NSAttributedString(string: attachment.altText ?? "", attributes: attributes)
        case .link:
            let title = attachment.title.flatMap { $0.isEmpty ? nil : $0 } ?? attachment.urlString ?? "Link"
            if let urlString = attachment.urlString, let url = URL(string: urlString) { attributes[.link] = url }
            return NSAttributedString(string: "🔗 " + title, attributes: attributes)
        case .image, .drawing:
            if let url = attachment.kind == .image ? attachment.fileURL : attachment.previewImageURL, let image = image(at: url) {
                let textAttachment = NSTextAttachment()
                textAttachment.image = image
                textAttachment.bounds = CGRect(origin: .zero, size: image.size)
                let result = NSMutableAttributedString(attachment: textAttachment)
                result.addAttributes(attributes.filter { $0.key == .paragraphStyle }, range: NSRange(location: 0, length: result.length))
                return result
            }
            fallthrough
        default:
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            return NSAttributedString(string: "📎 \(attachment.kind.displayName): \(attachment.displayName)", attributes: attributes)
        }
    }

    private static func image(at url: URL) -> NSImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(1, maxImageWidth / image.size.width, maxImageHeight / image.size.height)
        let size = NSSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let scaled = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        imageCache.setObject(scaled, forKey: url as NSURL)
        return scaled
    }

    private static func table(_ rows: [[String]]) -> NSAttributedString {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return NSAttributedString() }
        let table = NSTextTable()
        table.numberOfColumns = width
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let result = NSMutableAttributedString()
        let regular = NSFont.systemFont(ofSize: 12)
        let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<width {
                let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 { block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06) }
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.textBlocks = [block]
                let text = column < row.count ? row[column] : ""
                result.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: rowIndex == 0 ? bold : regular,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle,
                ]))
            }
        }
        let spacer = NSMutableParagraphStyle()
        spacer.paragraphSpacing = 4
        result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: spacer]))
        return result
    }
}
