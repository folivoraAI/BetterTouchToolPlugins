import Foundation
import SQLite3
import UniformTypeIdentifiers

// PRODUCTION_ENGINE

// MARK: - Protobuf fixture helpers

func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var bytes: [UInt8] = []
    repeat {
        var byte = UInt8(value & 0x7f)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        bytes.append(byte)
    } while value != 0
    return bytes
}

func field(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
    varint(UInt64(number << 3 | 2)) + varint(UInt64(payload.count)) + payload
}

func field(_ number: Int, int value: Int) -> [UInt8] {
    varint(UInt64(number << 3)) + varint(UInt64(bitPattern: Int64(value)))
}

func field(_ number: Int, string: String) -> [UInt8] {
    field(number, Array(string.utf8))
}

struct RunSpec {
    var text: String
    var style: Int? = nil
    var checked: Bool? = nil
    var indent: Int? = nil
    var weight: Int? = nil
    var link: String? = nil
    var attachment: (String, String)? = nil
}

func noteProto(_ runs: [RunSpec]) -> [UInt8] {
    var note = field(2, string: runs.map(\.text).joined())
    for run in runs {
        var body = field(1, int: run.text.utf16.count)
        if let style = run.style {
            var paragraph = field(1, int: style)
            if let indent = run.indent { paragraph += field(4, int: indent) }
            if let checked = run.checked {
                paragraph += field(5, field(1, Array(repeating: 7, count: 16)) + field(2, int: checked ? 1 : 0))
            }
            body += field(2, paragraph)
        }
        if let weight = run.weight { body += field(5, int: weight) }
        if let link = run.link { body += field(9, string: link) }
        if let (identifier, uti) = run.attachment {
            body += field(12, field(1, string: identifier) + field(2, string: uti))
        }
        note += field(5, body)
    }
    let document = field(2, int: 0) + field(3, note)
    return field(1, int: 0) + field(2, document)
}

func gzip(_ bytes: [UInt8]) -> Data {
    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    process.standardInput = input
    process.standardOutput = output
    try! process.run()
    input.fileHandleForWriting.write(Data(bytes))
    input.fileHandleForWriting.closeFile()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if !condition() {
        print("FAILED (line \(line)): \(message)")
        exit(1)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: UInt = #line) {
    if actual != expected {
        print("FAILED (line \(line)): \(message)\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)")
        exit(1)
    }
}

// MARK: - Fixture records

func makeNote(
    _ pk: Int64, _ title: String, body: String = "", folder: Int64 = 1, folderPath: String = "Notes",
    pinned: Bool = false, tags: [String] = [], trash: Bool = false, modified: TimeInterval = 0,
    checklist: Bool = false, openChecklist: Bool = false, kinds: [NotesAttachmentKind: Int] = [:]
) -> NotesNoteRecord {
    var note = NotesNoteRecord(
        pk: pk, identifier: "N\(pk)", title: title, snippet: "", folderPK: folder, accountPK: 1,
        created: Date(timeIntervalSinceReferenceDate: modified - 100),
        modified: Date(timeIntervalSinceReferenceDate: modified),
        isPinned: pinned, isLocked: false, isShared: false, hasChecklist: checklist,
        hasOpenChecklist: openChecklist, noteDataPK: pk
    )
    note.isInTrash = trash
    note.folderName = folderPath.components(separatedBy: " / ").last ?? folderPath
    note.folderPath = folderPath
    note.foldedFolderPath = NotesTextFolding.fold(folderPath)
    note.tags = tags
    note.foldedTags = tags.map(NotesTextFolding.fold)
    note.attachmentKinds = kinds
    note.foldedTitle = NotesTextFolding.fold(title)
    note.foldedBody = NotesTextFolding.foldedBytes(body)
    return note
}

func makeSnapshot(_ notes: [NotesNoteRecord]) -> NotesLibrarySnapshot {
    let folders: [Int64: NotesFolderRecord] = [
        1: NotesFolderRecord(pk: 1, identifier: "F1", name: "Notes", parentPK: nil, accountPK: 1, isTrash: false, isSmartFolder: false, path: "Notes", depth: 0),
        2: NotesFolderRecord(pk: 2, identifier: "F2", name: "Work", parentPK: nil, accountPK: 1, isTrash: false, isSmartFolder: false, path: "Work", depth: 0),
        3: NotesFolderRecord(pk: 3, identifier: "F3", name: "Projects", parentPK: 2, accountPK: 1, isTrash: false, isSmartFolder: false, path: "Work / Projects", depth: 1),
        9: NotesFolderRecord(pk: 9, identifier: "F9", name: "Recently Deleted", parentPK: nil, accountPK: 1, isTrash: true, isSmartFolder: false, path: "Recently Deleted", depth: 0),
    ]
    return NotesLibrarySnapshot(
        databasePath: "/tmp/NoteStore.sqlite",
        schema: NotesSchema(entities: [:], storeUUID: "STORE", resolvedColumns: [:], hasNoteDataTable: true),
        accounts: [1: NotesAccountRecord(pk: 1, identifier: "ACCOUNT", name: "iCloud")],
        folders: folders,
        notes: notes,
        tagCounts: [],
        folderNoteCounts: [:],
        loadedAt: Date(),
        loadDuration: 0
    )
}

@main
struct AppleNotesEngineTests {
    static func main() {
        testDocumentDecodingAndMarkdown()
        testPlainText()
        testCompressionVariants()
        testQueryParsing()
        testSearchRanking()
        testSearchFilters()
        testHTMLComposer()
        testSnippet()
        print("Apple Notes engine tests passed")
    }

    static func testDocumentDecodingAndMarkdown() {
        let proto = noteProto([
            RunSpec(text: "Shopping 🛒\n", style: 0),
            RunSpec(text: "Milk", style: 100, weight: 1),
            RunSpec(text: " and bread\n", style: 100),
            RunSpec(text: "Nested\n", style: 100, indent: 1),
            RunSpec(text: "Done item\n", style: 103, checked: true),
            RunSpec(text: "Open item\n", style: 103, checked: false),
            RunSpec(text: "First\n", style: 102),
            RunSpec(text: "Second\n", style: 102),
            RunSpec(text: "See "),
            RunSpec(text: "site", link: "https://example.com"),
            RunSpec(text: "\n"),
            RunSpec(text: "let x = 1\n", style: 4),
            RunSpec(text: "\u{FFFC}", attachment: ("T1", "com.apple.notes.table")),
            RunSpec(text: "\n"),
            RunSpec(text: "\u{FFFC}", attachment: ("H1", "com.apple.notes.inlinetextattachment.hashtag")),
            RunSpec(text: " end"),
        ])
        guard let document = NotesDocumentDecoder.document(fromCompressed: gzip(proto)) else {
            expect(false, "gzipped document decodes")
            return
        }
        expect(document.text.hasPrefix("Shopping 🛒\nMilk"), "note text survives decoding")
        expectEqual(document.runs.count, 16, "attribute runs decode")

        let paragraphs = NotesDocumentLayout.paragraphs(of: document)
        expectEqual(paragraphs.count, 11, "paragraph split")
        expectEqual(paragraphs[0].text, "Shopping 🛒", "UTF-16 run lengths with emoji")
        expectEqual(paragraphs[0].style.styleType, NotesParagraphStyle.title, "title style")
        expectEqual(paragraphs[2].style.indent, 1, "indent")
        expect(paragraphs[3].style.isChecked, "checked checklist item")

        let attachments: [String: NotesAttachment] = [
            "T1": NotesAttachment(identifier: "T1", uti: "com.apple.notes.table", kind: .table,
                                  tableRows: [["Name", "Qty | unit"], ["Milk", "2"]]),
            "H1": NotesAttachment(identifier: "H1", uti: "com.apple.notes.inlinetextattachment.hashtag",
                                  kind: .hashtag, altText: "#groceries"),
        ]
        let markdown = NotesMarkdownRenderer.markdown(of: paragraphs, attachments: attachments)
        let expected = """
            # Shopping 🛒

            - **Milk** and bread
                - Nested
            - [x] Done item
            - [ ] Open item
            1. First
            2. Second

            See [site](https://example.com)

            ```
            let x = 1
            ```

            | Name | Qty \\| unit |
            | --- | --- |
            | Milk | 2 |

            #groceries end

            """
        expectEqual(markdown, expected, "Markdown rendering")
    }

    static func testPlainText() {
        let proto = noteProto([
            RunSpec(text: "Title\n", style: 0),
            RunSpec(text: "One\n", style: 102),
            RunSpec(text: "Two\n", style: 102),
            RunSpec(text: "Todo\n", style: 103, checked: false),
            RunSpec(text: "Body"),
        ])
        let document = NotesDocumentDecoder.document(fromCompressed: gzip(proto))!
        let text = NotesMarkdownRenderer.plainText(of: NotesDocumentLayout.paragraphs(of: document), attachments: [:])
        expectEqual(text, "Title\n1. One\n2. Two\n☐ Todo\nBody\n", "plain text rendering")
        expectEqual(NotesDocumentDecoder.plainText(fromCompressed: gzip(proto)), "Title\nOne\nTwo\nTodo\nBody", "fast plain text path")
    }

    static func testCompressionVariants() {
        let payload = Array("hello notes".utf8)
        let zipped = gzip(payload)
        expectEqual(NotesCompression.inflate(zipped), payload, "gzip inflate")
        expect(NotesCompression.inflate(Data([0x1f, 0x8b, 0x08])) == nil, "truncated gzip is rejected")
        expect(NotesProtoMessage([0x0a, 0x05, 0x01]).fields() == nil, "truncated length-delimited field is rejected")
        expect(NotesProtoMessage([0x08, 0x80]).fields() == nil, "truncated varint is rejected")
    }

    static func testQueryParsing() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let query = NotesSearchQuery.parse(
            #"Milk "Exact Phrase" -bread #Grocéries in:"My Folder" is:pinned has:todo modified:7d sort:title url:x"#,
            now: now, calendar: calendar
        )
        expectEqual(query.terms, ["milk", "url:x"], "terms; unknown keys stay terms")
        expectEqual(query.phrases, ["exact phrase"], "quoted phrase")
        expectEqual(query.excluded, ["bread"], "excluded term")
        expectEqual(query.tags, ["groceries"], "folded tag")
        expectEqual(query.folders, ["my folder"], "quoted folder value")
        expectEqual(query.pinned, true, "is:pinned")
        expect(query.filters == [.todo], "has:todo")
        expectEqual(query.modifiedAfter, now.addingTimeInterval(-7 * 86_400), "relative date")
        expectEqual(query.sort, .title, "sort")

        let day = NotesSearchQuery.parse("created:2026-03-02", now: now, calendar: calendar)
        let formatter = ISO8601DateFormatter()
        expectEqual(day.createdAfter.map(formatter.string), "2026-03-02T00:00:00Z", "absolute day start")
        expectEqual(day.createdBefore.map(formatter.string), "2026-03-03T00:00:00Z", "absolute day end")
        expect(NotesSearchQuery.parse("in:").isEmpty, "incomplete filter while typing is ignored")
        expect(NotesSearchQuery.parse("is:deleted").onlyTrash, "is:deleted")
        expect(!NotesSearchQuery.parse("milk").hasStructuredCriteria, "plain words are not structured")
    }

    static func testSearchRanking() {
        let snapshot = makeSnapshot([
            makeNote(1, "Weekly checklist", modified: 10),
            makeNote(2, "List of books", modified: 20),
            makeNote(3, "Shopping list", modified: 30),
            makeNote(4, "List", modified: 5),
            makeNote(5, "Recipes", body: "a long list of ingredients", modified: 40),
            makeNote(6, "Unrelated", body: "nothing here", modified: 50),
            makeNote(7, "Old list", trash: true, modified: 60),
        ])
        let hits = NotesSearchEngine.search(NotesSearchQuery.parse("list"), in: snapshot, limit: 10)
        expectEqual(hits.map(\.note.pk), [4, 2, 3, 1, 5], "exact > prefix > word prefix > substring > body; trash hidden")
        expectEqual(hits.map(\.score), [100, 85, 72, 58, 30], "scores")
        expect(!hits[4].matchedTitle, "body match is flagged")

        var titleOnly = NotesSearchQuery.parse("ingredients")
        titleOnly.titleOnly = true
        expect(NotesSearchEngine.search(titleOnly, in: snapshot, limit: 10).isEmpty, "title-only search skips bodies")

        let phrase = NotesSearchEngine.search(NotesSearchQuery.parse("shopping lis"), in: snapshot, limit: 10)
        expectEqual(phrase.first?.note.pk, 3, "multi-word title prefix")
        expectEqual(phrase.first?.score, 85, "multi-word prefix score")

        let excluded = NotesSearchEngine.search(NotesSearchQuery.parse("list -books"), in: snapshot, limit: 10)
        expect(!excluded.contains { $0.note.pk == 2 }, "excluded term removes note")

        var withTrash = NotesSearchQuery.parse("list")
        withTrash.includeTrash = true
        expect(NotesSearchEngine.search(withTrash, in: snapshot, limit: 10).contains { $0.note.pk == 7 }, "includeTrash")
        expectEqual(NotesSearchEngine.search(NotesSearchQuery.parse("is:deleted"), in: snapshot, limit: 10).map(\.note.pk), [7], "only trash")
        expectEqual(NotesSearchEngine.search(NotesSearchQuery.parse("list"), in: snapshot, limit: 2).count, 2, "limit")
    }

    static func testSearchFilters() {
        let snapshot = makeSnapshot([
            makeNote(1, "Plan", folder: 3, folderPath: "Work / Projects", tags: ["Roadmap"], modified: 10),
            makeNote(2, "Errands", pinned: true, modified: 5, checklist: true, openChecklist: true),
            makeNote(3, "Budget", folder: 2, folderPath: "Work", modified: 30, kinds: [.table: 1]),
            makeNote(4, "Trip", modified: 40, kinds: [.image: 2, .hashtag: 1]),
        ])
        func pks(_ text: String) -> [Int64] {
            NotesSearchEngine.search(NotesSearchQuery.parse(text), in: snapshot, limit: 10).map(\.note.pk)
        }
        expectEqual(pks(""), [2, 4, 3, 1], "browse: pinned first, then newest")
        expectEqual(pks("#road"), [1], "tag prefix")
        expectEqual(pks("roadmap"), [1], "plain words also match tags")
        expectEqual(pks("in:projects"), [1], "folder path filter")
        expectEqual(pks("in:work"), [3, 1], "parent folder path matches subfolders")
        expectEqual(pks("has:todo"), [2], "open checklist")
        expectEqual(pks("has:table"), [3], "table attachment")
        expectEqual(pks("has:attachment"), [4, 3], "inline tags are not attachments")
        expectEqual(pks("is:pinned"), [2], "pinned")
        expectEqual(pks("sort:title"), [3, 2, 1, 4], "explicit sort")

        var scoped = NotesSearchQuery()
        scoped.folderPKs = snapshot.folderAndDescendants(2)
        expectEqual(NotesSearchEngine.search(scoped, in: snapshot, limit: 10).map(\.note.pk), [3, 1], "folder scope includes subfolders")

        expectEqual(NotesSearchEngine.titleScore(term: "list", foldedTitle: "shopping list"), 72, "word prefix")
        expectEqual(NotesSearchEngine.titleScore(term: "list", foldedTitle: "checklist"), 58, "substring")
        expectEqual(NotesSearchEngine.titleScore(term: "zzz", foldedTitle: "checklist"), nil, "no match")
        expectEqual(snapshot.appleScriptID(for: snapshot.notes[0]), "x-coredata://STORE/ICNote/p1", "AppleScript note id")
    }

    static func testHTMLComposer() {
        let html = NotesHTMLComposer.html(fromMarkdown: """
            # Heading
            - [ ] todo
            - [x] done
            - item
            1. first
            > quoted
            **bold** and *it* `code` [link](https://x.test/?a=1&b=2) <script>

            ```
            raw *text*
            ```
            """)
        let expected = "<h1>Heading</h1><ul><li>☐ todo</li><li>☑ done</li><li>item</li></ul><ol><li>first</li></ol>"
            + "<blockquote>quoted</blockquote>"
            + "<div><b>bold</b> and <i>it</i> <tt>code</tt> <a href=\"https://x.test/?a=1&amp;b=2\">link</a> &lt;script&gt;</div>"
            + "<div><br></div><div><tt>raw *text*</tt></div>"
        expectEqual(html, expected, "Markdown to Notes HTML")
    }

    static func testSnippet() {
        let text = "Menu ideas\n" + String(repeating: "filler ", count: 30) + "the Café menu\nsecond line"
        let snippet = NotesSnippet.excerpt(from: text, terms: ["menu"]) ?? ""
        expect(snippet.hasPrefix("…filler "), "skips the title line and starts on a word boundary: \(snippet)")
        expect(snippet.contains("Café menu second line"), "newlines flattened")
        expectEqual(NotesSnippet.excerpt(from: "Title\nthe Café menu", terms: ["cafe"]), "the Café menu", "diacritic-insensitive match")
        expectEqual(NotesSnippet.excerpt(from: "Only title", terms: ["title"]), "Only title", "falls back to the title line")
        let long = "Title\nstart " + String(repeating: "word ", count: 40)
        expect(!(NotesSnippet.excerpt(from: long, terms: ["start"]) ?? "").contains("wor…"), "ends on a word boundary")
        expect(NotesSnippet.excerpt(from: "abc", terms: ["zzz"]) == nil, "no match")
    }
}
