// BTT-Plugin-Name: Xcode Recent Projects
// BTT-Plugin-Identifier: com.bttuserplugin.xcode-recent-projects
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: hammer.fill
// BTT-AI-Managed: true

import AppKit

class XcodeRecentProjectsPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let searchRecent   = "xcode-search-recent"
        static let recentChildren = "xcode-recent-children"
        static let openProject    = "xcode-open-project"
        static let reveal         = "xcode-reveal"
    }

    // MARK: - Metadata

    static func launcherPluginName()        -> String { "Xcode" }
    static func launcherPluginDescription() -> String { "Search recently opened Xcode projects and workspaces." }
    static func launcherPluginIcon()        -> String { "hammer.fill" }

    // MARK: - Top-level entry

    /// One launcher entry — "Search Recent Projects" — matching the Code /
    /// Cursor launcher style. Children are produced lazily via
    /// `loadLauncherChildren` below.
    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier            = IDs.searchRecent
        r.title                     = "Search Recent Projects"
        r.subtitle                  = "Xcode — Browse recently opened projects"
        r.iconImage                 = xcodeIcon()
        r.trailingHint              = "Browse"
        r.dynamicChildrenIdentifier = IDs.recentChildren
        r.opensChildrenByDefault    = true
        r.keywords                  = ["xcode", "project", "workspace", "recent"]
        return [r]
    }

    // MARK: - Children (recent projects)

    func loadLauncherChildren(
        forItemIdentifier itemIdentifier: String,
        childrenIdentifier: String?,
        context: BTTLauncherPluginContext,
        completion: @escaping ([BTTLauncherPluginResult]?) -> Void
    ) {
        guard itemIdentifier == IDs.searchRecent else { completion(nil); return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { completion(nil); return }
            let projects = self.loadXcodeRecentProjects()

            let results: [BTTLauncherPluginResult] = projects.enumerated().map { (index, url) in
                let name = url.deletingPathExtension().lastPathComponent
                let path = url.path
                let ext  = url.pathExtension.lowercased()

                // Friendly subtitle: shorten home dir to ~
                let parent   = url.deletingLastPathComponent().path
                let subtitle = parent.hasPrefix(NSHomeDirectory())
                    ? "~" + parent.dropFirst(NSHomeDirectory().count)
                    : parent

                let r                       = BTTLauncherPluginResult()
                r.itemIdentifier            = "\(IDs.openProject):\(path)"
                r.title                     = name
                r.subtitle                  = subtitle
                r.sortOrder                 = NSNumber(value: index)
                r.primaryActionIdentifier   = IDs.openProject
                r.trailingHint              = ext == "xcworkspace" ? "Workspace" : "Project"
                r.keywords                  = [path, ext]

                if FileManager.default.fileExists(atPath: path) {
                    let img       = NSWorkspace.shared.icon(forFile: path)
                    img.size      = NSSize(width: 32, height: 32)
                    r.iconImage   = img
                } else {
                    r.systemImageName = ext == "xcworkspace" ? "shippingbox.fill" : "hammer.fill"
                }

                // Cmd-R → Reveal in Finder
                let revealCmd                       = BTTLauncherPluginCommand()
                revealCmd.commandIdentifier         = IDs.reveal
                revealCmd.title                     = "Reveal in Finder"
                revealCmd.systemImageName           = "folder"
                revealCmd.closesLauncherOnSuccess   = true
                let sc                              = BTTLauncherPluginShortcut()
                sc.character                        = "r"
                sc.modifierFlags                    = [.command]
                sc.displayKeys                      = ["⌘", "R"]
                revealCmd.shortcut                  = sc
                r.commands                          = [revealCmd]

                return r
            }
            completion(results)
        }
    }

    // MARK: - Actions

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {

        let openPrefix = "\(IDs.openProject):"
        guard itemIdentifier.hasPrefix(openPrefix) else { return nil }
        let path = String(itemIdentifier.dropFirst(openPrefix.count))
        let url  = URL(fileURLWithPath: path)

        let out           = BTTLauncherPluginActionResult()
        out.closeLauncher = true

        if actionIdentifier == IDs.reveal {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            out.success = true
        } else {
            // Default: open in Xcode
            out.success = NSWorkspace.shared.open(url)
        }
        return out
    }

    // MARK: - Recent project sources
    //
    // Apple's SharedFileList (com.apple.dt.xcode.sfl3) is TCC-protected and
    // unreadable from BTT without Full Disk Access, and Xcode's own
    // `IDERecentWorkspaceDocuments` pref is usually empty / stores only
    // source files. So we ask Spotlight for `.xcodeproj` / `.xcworkspace`
    // files sorted by last-used date — no special permission required.

    private func loadXcodeRecentProjects() -> [URL] {
        let q                          = NSMetadataQuery()
        q.searchScopes                 = [NSMetadataQueryUserHomeScope]
        q.predicate                    = NSPredicate(
            format: "kMDItemContentType == 'com.apple.xcode.project' || kMDItemContentType == 'com.apple.dt.document.workspace'"
        )
        q.sortDescriptors              = [
            NSSortDescriptor(key: NSMetadataItemLastUsedDateKey, ascending: false)
        ]
        q.valueListAttributes          = [NSMetadataItemPathKey, NSMetadataItemLastUsedDateKey]

        // Run the query synchronously on a dedicated runloop with a short timeout.
        let sem = DispatchSemaphore(value: 0)
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: q,
            queue: .main
        ) { _ in
            q.disableUpdates()
            sem.signal()
        }
        DispatchQueue.main.async { q.start() }
        _ = sem.wait(timeout: .now() + 4.0)
        if let token { NotificationCenter.default.removeObserver(token) }
        DispatchQueue.main.async { q.stop() }

        var out: [URL] = []
        var seen       = Set<String>()
        let max        = 200

        for i in 0..<q.resultCount {
            guard
                let item = q.result(at: i) as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }

            // Skip projects that have never been opened (no last-used date).
            guard item.value(forAttribute: NSMetadataItemLastUsedDateKey) is Date else { continue }

            let url = URL(fileURLWithPath: path)
            guard accept(url), seen.insert(url.path).inserted else { continue }
            out.append(url)
            if out.count >= max { break }
        }
        return out
    }

    private func accept(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "xcodeproj" || ext == "xcworkspace" else { return false }
        // Skip embedded workspace packages (e.g. Foo.xcodeproj/project.xcworkspace)
        guard !url.path.contains(".xcodeproj/") else { return false }
        // Skip DerivedData entries
        guard !url.path.contains("/DerivedData/") else { return false }
        return true
    }

    // MARK: - Icon

    /// Loads Xcode's real app icon for the launcher row. Falls back to a
    /// painted SF symbol if Xcode isn't installed.
    private func xcodeIcon() -> NSImage {
        if let url = findXcodeApp() {
            if let bundle = Bundle(url: url),
               let iconFile = bundle.infoDictionary?["CFBundleIconFile"] as? String {
                let icnsName = iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns"
                let icnsPath = (bundle.resourcePath ?? "") + "/" + icnsName
                if let img = NSImage(contentsOfFile: icnsPath) { return img }
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: nil)
            ?? NSImage()
    }

    private func findXcodeApp() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            return url
        }
        for p in ["/Applications/Xcode.app",
                  NSHomeDirectory() + "/Applications/Xcode.app"] {
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
}
