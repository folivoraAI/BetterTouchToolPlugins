import Foundation
import SQLite3
import UniformTypeIdentifiers

// PRODUCTION_ENGINE

/// Reads the local Notes library read-only and prints aggregate statistics.
/// Never prints note titles or contents.
@main
struct AppleNotesLiveProbe {
    static func main() {
        let path = CommandLine.arguments.dropFirst().first ?? NotesLibraryLoader.defaultDatabasePath
        let snapshot: NotesLibrarySnapshot
        do {
            snapshot = try NotesLibraryLoader.loadSnapshot(databasePath: path)
        } catch {
            print("Could not load the library: \(error)")
            exit(1)
        }

        let notes = snapshot.notes
        let unlocked = notes.filter { !$0.isLocked }
        print(String(format: "Index: %d notes (%d locked, %d in Recently Deleted), %d folders, %d tags, loaded in %.0f ms",
                     notes.count, notes.count - unlocked.count, notes.filter(\.isInTrash).count,
                     snapshot.folders.count, snapshot.tagCounts.count, snapshot.loadDuration * 1000))
        print("Bodies indexed: \(unlocked.filter { !$0.foldedBody.isEmpty }.count) of \(unlocked.count) unlocked notes, "
              + "\(unlocked.reduce(0) { $0 + $1.foldedBody.count } / 1024) KiB folded text")
        print("Resolved columns: \(snapshot.schema.resolvedColumns.count) of \(NotesSchema.columnCandidates.count)")

        for text in ["e", "the", "note", "a b", "zzzzqq", "has:checklist", "is:pinned", "has:table sort:title"] {
            let query = NotesSearchQuery.parse(text)
            let started = Date()
            var hits: [NotesSearchHit] = []
            for _ in 0..<20 { hits = NotesSearchEngine.search(query, in: snapshot, limit: 500) }
            let elapsed = Date().timeIntervalSince(started) / 20 * 1000
            print(String(format: "Search %-22@ %4d hits  %.2f ms", "\"\(text)\"" as NSString, hits.count, elapsed))
        }

        var failedDetails = 0
        var unreadable = 0
        var tables = 0
        var decodedTables = 0
        var images = 0
        var resolvedImages = 0
        var drawings = 0
        var resolvedDrawings = 0
        var unresolvedAttachmentRuns = 0
        var leftoverObjectCharacters = 0
        var markdownBytes = 0
        let started = Date()
        for note in unlocked {
            guard let detail = try? NotesLibraryLoader.loadDetail(for: note, snapshot: snapshot) else {
                failedDetails += 1
                continue
            }
            guard detail.isContentAvailable else {
                unreadable += 1
                continue
            }
            for attachment in detail.attachments.values {
                switch attachment.kind {
                case .table:
                    tables += 1
                    if attachment.tableRows != nil { decodedTables += 1 }
                case .image:
                    images += 1
                    if attachment.fileURL != nil { resolvedImages += 1 }
                case .drawing:
                    drawings += 1
                    if attachment.previewImageURL != nil { resolvedDrawings += 1 }
                default:
                    break
                }
            }
            for paragraph in detail.paragraphs {
                for segment in paragraph.segments {
                    if let identifier = segment.run.attachmentIdentifier, detail.attachments[identifier] == nil {
                        unresolvedAttachmentRuns += 1
                    }
                }
            }
            let markdown = detail.markdown
            _ = detail.plainText
            markdownBytes += markdown.utf8.count
            leftoverObjectCharacters += markdown.filter { $0 == NotesDocumentLayout.attachmentCharacter }.count
        }
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "Rendered %d notes to Markdown in %.0f ms (%d KiB); detail failures %d, unreadable %d",
                     unlocked.count - failedDetails - unreadable, elapsed * 1000, markdownBytes / 1024, failedDetails, unreadable))
        print("Tables decoded \(decodedTables)/\(tables), images with files \(resolvedImages)/\(images), drawings with previews \(resolvedDrawings)/\(drawings)")
        print("Attachment runs without a database row: \(unresolvedAttachmentRuns); U+FFFC left in Markdown: \(leftoverObjectCharacters)")
    }
}
