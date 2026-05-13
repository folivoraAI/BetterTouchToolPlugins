// BTT-Plugin-Name: Compress Finder Selection
// BTT-Plugin-Identifier: com.folivora.btt.action.compressfinderselection
// BTT-Plugin-Type: Action
// BTT-Plugin-Icon: archivebox.fill
// BTT-AI-Managed: true

import Cocoa

final class CompressFinderSelection: NSObject, BTTActionPluginInterface {
    weak var delegate: (any BTTActionPluginDelegate)?

    static func configurationFormItems() -> BTTPluginFormItem? {
        nil
    }

    func executeAction(
        withConfiguration config: [AnyHashable: Any]?,
        completionBlock: ((@Sendable (Any?) -> Void)?)
    ) {
        do {
            // Read Finder's current selection up front before the background work starts.
            let selectedItems = try selectedFinderURLs()
            let destinationURL = try archiveDestination(for: selectedItems)

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.createArchive(for: selectedItems, at: destinationURL)
                    DispatchQueue.main.async {
                        completionBlock?(destinationURL.path)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.presentError(error)
                        completionBlock?(error.localizedDescription)
                    }
                }
            }
        } catch {
            presentError(error)
            completionBlock?(error.localizedDescription)
        }
    }

    private func selectedFinderURLs() throws -> [URL] {
        let script = """
        tell application \"Finder\"
            set selectedItems to selection
            if (count of selectedItems) is 0 then
                return \"\"
            end if

            set selectedPaths to {}
            repeat with currentItem in selectedItems
                set end of selectedPaths to POSIX path of (currentItem as alias)
            end repeat

            set previousDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            set joinedPaths to selectedPaths as text
            set AppleScript's text item delimiters to previousDelimiters
            return joinedPaths
        end tell
        """

        var errorInfo: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw CompressFinderSelectionError.appleScriptFailure("Finder selection script could not be created.")
        }

        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw CompressFinderSelectionError.appleScriptFailure(String(describing: errorInfo))
        }

        let output = result.stringValue ?? ""
        let urls = output
            .split(whereSeparator: { $0.isNewline })
            .map { URL(fileURLWithPath: String($0)) }

        guard !urls.isEmpty else {
            throw CompressFinderSelectionError.noSelection
        }

        return urls
    }

    private func archiveDestination(for selectedItems: [URL]) throws -> URL {
        let parentPaths = Set(selectedItems.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let destinationDirectory: URL

        if parentPaths.count == 1, let parentPath = parentPaths.first {
            destinationDirectory = URL(fileURLWithPath: parentPath, isDirectory: true)
        } else {
            destinationDirectory = try FileManager.default.url(
                for: .desktopDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }

        let baseName = selectedItems.count == 1 ? selectedItems[0].lastPathComponent : "Archive"
        return nextAvailableArchiveURL(baseName: baseName, in: destinationDirectory)
    }

    private func nextAvailableArchiveURL(baseName: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension("zip")
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        var index = 2
        while true {
            candidate = directory
                .appendingPathComponent("\(baseName) \(index)")
                .appendingPathExtension("zip")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func createArchive(for selectedItems: [URL], at destinationURL: URL) throws {
        if selectedItems.count == 1, let item = selectedItems.first {
            try runProcess(
                executablePath: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", item.path, destinationURL.path]
            )
            return
        }

        let fileManager = FileManager.default
        let stagingDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "CompressFinderSelection-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }

        for item in selectedItems {
            let stagedURL = uniqueStagingURL(for: item.lastPathComponent, in: stagingDirectory)
            try runProcess(executablePath: "/usr/bin/ditto", arguments: [item.path, stagedURL.path])
        }

        try runProcess(
            executablePath: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--sequesterRsrc", stagingDirectory.path, destinationURL.path]
        )
    }

    private func uniqueStagingURL(for originalName: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        let safeName = originalName.isEmpty ? "Item" : originalName
        var candidate = directory.appendingPathComponent(safeName)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let name = safeName as NSString
        let stem = name.deletingPathExtension
        let ext = name.pathExtension
        var index = 2

        while true {
            let numberedStem = "\(stem) \(index)"
            let numberedName = ext.isEmpty ? numberedStem : "\(numberedStem).\(ext)"
            candidate = directory.appendingPathComponent(numberedName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    @discardableResult
    private func runProcess(executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CompressFinderSelectionError.commandFailure(
                message.isEmpty ? "Compression failed with status \(process.terminationStatus)." : message
            )
        }

        return output
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Compress Finder Selection"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

private enum CompressFinderSelectionError: LocalizedError {
    case noSelection
    case appleScriptFailure(String)
    case commandFailure(String)

    var errorDescription: String? {
        switch self {
        case .noSelection:
            return "Select one or more items in Finder, then run the action again."
        case .appleScriptFailure(let message):
            return "Could not read Finder's current selection. \(message)"
        case .commandFailure(let message):
            return message
        }
    }
}
