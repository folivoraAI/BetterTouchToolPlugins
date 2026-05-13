// BTT-Plugin-Name: Code Launcher
// BTT-Plugin-Identifier: com.bttuserplugin.vscode.launcher
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: chevron.left.forwardslash.chevron.right
// BTT-AI-Managed: true

import AppKit

// MARK: - Data model

struct VSCodeRecentProject {
    let name: String
    let path: String
    let isWorkspace: Bool

    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Plugin

class VSCodeLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let searchRecent   = "vscode-search-recent"
        static let openWithCode   = "vscode-open-with-code"
        static let openNewWindow  = "vscode-open-new-window"
        static let recentChildren = "vscode-recent-children"
        static let openProject    = "vscode-open-project"
    }

    // MARK: Metadata

    static func launcherPluginName()        -> String { "Code" }
    static func launcherPluginDescription() -> String { "Search recent projects, open with Code, new window." }
    static func launcherPluginIcon()        -> String { "chevron.left.forwardslash.chevron.right" }

    // MARK: Top-level results

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        var items: [BTTLauncherPluginResult] = []

        // 1 — Search Recent Projects (Code)
        let recent = BTTLauncherPluginResult()
        recent.itemIdentifier            = IDs.searchRecent
        recent.title                     = "Search Recent Projects"
        recent.subtitle                  = "Code — Browse recently opened projects"
        recent.iconImage                 = vsCodeIcon()
        recent.trailingHint              = "Browse"
        recent.dynamicChildrenIdentifier = IDs.recentChildren
        recent.opensChildrenByDefault    = true
        recent.sortOrder                 = 0
        items.append(recent)

        // 2 — Open with Code
        let openWith = BTTLauncherPluginResult()
        openWith.itemIdentifier          = IDs.openWithCode
        openWith.title                   = "Open with Code"
        openWith.subtitle = {
            if context.finderSelection == true, let url = context.finderURLs?.first {
                return "Code — \(url.lastPathComponent)"
            }
            return "Code — Open selected Finder folder"
        }()
        openWith.iconImage               = vsCodeIcon()
        openWith.trailingHint            = "Open"
        openWith.primaryActionIdentifier = IDs.openWithCode
        openWith.sortOrder               = 1
        items.append(openWith)

        // 3 — Open New Window (Code)
        let newWin = BTTLauncherPluginResult()
        newWin.itemIdentifier            = IDs.openNewWindow
        newWin.title                     = "Open New Window"
        newWin.subtitle                  = "Code — Launch a fresh editor window"
        newWin.iconImage                 = vsCodeIcon()
        newWin.trailingHint              = "Open"
        newWin.primaryActionIdentifier   = IDs.openNewWindow
        newWin.sortOrder                 = 2
        items.append(newWin)

        guard let q = context.query, !q.isEmpty else { return items }
        let lq = q.lowercased()
        return items.filter {
            ($0.title?.lowercased().contains(lq) ?? false) ||
            ($0.subtitle?.lowercased().contains(lq) ?? false)
        }
    }

    // MARK: Children – recent projects

    func loadLauncherChildren(
        forItemIdentifier itemIdentifier: String,
        childrenIdentifier: String?,
        context: BTTLauncherPluginContext,
        completion: @escaping ([BTTLauncherPluginResult]?) -> Void
    ) {
        guard itemIdentifier == IDs.searchRecent else { completion(nil); return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { completion(nil); return }
            let projects = self.fetchRecentProjects()
            guard !projects.isEmpty else { completion([]); return }

            var branches = [String](repeating: "", count: projects.count)
            branches.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: projects.count) { i in
                    buf[i] = self.gitBranch(for: projects[i].path)
                }
            }

            let results: [BTTLauncherPluginResult] = projects.enumerated().map { idx, p in
                let r = BTTLauncherPluginResult()
                r.itemIdentifier          = "\(IDs.openProject):\(p.path)"
                r.title                   = p.name
                r.subtitle                = p.displayPath
                r.primaryActionIdentifier = IDs.openProject
                let branch                = branches[idx]
                r.trailingHint            = branch.isEmpty ? nil : "⎇  \(branch)"
                r.sortOrder               = NSNumber(value: idx)
                r.keywords                = branch.isEmpty ? [p.path] : [p.path, branch]
                r.iconImage               = NSWorkspace.shared.icon(forFile: p.path)
                return r
            }
            completion(results)
        }
    }

    // MARK: Actions

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {
        let out = BTTLauncherPluginActionResult()

        let projectPrefix = "\(IDs.openProject):"
        if itemIdentifier.hasPrefix(projectPrefix) {
            let path = String(itemIdentifier.dropFirst(projectPrefix.count))
            openPathWithCode(path)
            out.success = true; out.closeLauncher = true
            return out
        }

        switch actionIdentifier ?? itemIdentifier {

        case IDs.openWithCode:
            guard let urls = context.finderURLs, !urls.isEmpty else {
                out.success = false; out.message = "No item selected in Finder"
                out.closeLauncher = false; return out
            }
            openURLsWithCode(urls)
            out.success = true; out.closeLauncher = true

        case IDs.openNewWindow:
            openNewCodeWindow()
            out.success = true; out.closeLauncher = true

        default:
            out.success = false
        }
        return out
    }

    // MARK: VSCode launch (direct Process / NSWorkspace — no shell scripts)

    private func openPathWithCode(_ path: String) {
        if tryLaunchCLI(arguments: ["--new-window", path]) { return }
        let url = URL(fileURLWithPath: path)
        if let app = findVSCodeApp() {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = ["--new-window"]
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, _ in }
        }
    }

    private func openURLsWithCode(_ urls: [URL]) {
        if tryLaunchCLI(arguments: urls.map { $0.path }) { return }
        if let app = findVSCodeApp() {
            NSWorkspace.shared.open(urls, withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    private func openNewCodeWindow() {
        if tryLaunchCLI(arguments: ["--new-window"]) { return }
        if let app = findVSCodeApp() {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = ["--new-window"]
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in }
        }
    }

    /// Try each CLI candidate in order; return true on the first hit.
    private func tryLaunchCLI(arguments: [String]) -> Bool {
        let home = NSHomeDirectory()
        let candidates = [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            home + "/.vscode/bin/code",
            "/usr/bin/code",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
        ]
        for cli in candidates {
            guard FileManager.default.isExecutableFile(atPath: cli) else { continue }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: cli)
            task.arguments     = arguments
            try? task.run()
            return true
        }
        return false
    }

    private func findVSCodeApp() -> URL? {
        // 1. Known bundle IDs
        for bid in ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) { return url }
        }
        // 2. Standard install locations
        for p in ["/Applications/Visual Studio Code.app",
                  NSHomeDirectory() + "/Applications/Visual Studio Code.app"] {
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// Loads VSCode icon directly from the app bundle (avoids macOS shadow/framing at small sizes).
    private func vsCodeIcon() -> NSImage {
        if let url = findVSCodeApp() {
            if let bundle = Bundle(url: url),
               let iconFile = bundle.infoDictionary?["CFBundleIconFile"] as? String {
                let icnsName = iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns"
                let icnsPath = (bundle.resourcePath ?? "") + "/" + icnsName
                if let img = NSImage(contentsOfFile: icnsPath) { return img }
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        // Fallback: painted SF-symbol in VSCode blue
        return makeIcon("chevron.left.forwardslash.chevron.right",
                        color: NSColor(calibratedRed: 0.01, green: 0.49, blue: 0.78, alpha: 1))
    }

    // MARK: Icon rendering

    private func makeIcon(_ systemName: String, color: NSColor) -> NSImage {
        let size: CGFloat = 40
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let bg = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            color.setFill()
            bg.fill()

            let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let sym = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let o = NSPoint(x: (size - sym.size.width)  / 2,
                                y: (size - sym.size.height) / 2)
                sym.draw(at: o, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }

    // MARK: Recent projects

    private func fetchRecentProjects() -> [VSCodeRecentProject] {
        // Primary: macOS SharedFileList (File → Open Recent) — works with all VS Code versions
        if let projects = fetchFromSharedFileList(), !projects.isEmpty { return projects }

        // Fallback: SQLite state.vscdb (VS Code < 1.119, Cursor, older forks)
        let home = NSHomeDirectory()
        var dbPaths: [String] = [
            home + "/Library/Application Support/Code/User/globalStorage/state.vscdb"
        ]
        let profilesDir = home + "/Library/Application Support/Code/User/profiles"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
            for entry in entries {
                let p = "\(profilesDir)/\(entry)/globalStorage/state.vscdb"
                if FileManager.default.fileExists(atPath: p) { dbPaths.append(p) }
            }
        }
        for dbPath in dbPaths {
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            if let data = runSQLite(db: dbPath,
                    sql: "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key='history.recentlyOpenedPathsList'"),
               let parsed = parseEntries(from: data), !parsed.isEmpty { return parsed }
            if let data = runSQLite(db: dbPath,
                    sql: "SELECT CAST(value AS TEXT) FROM ItemTable WHERE key LIKE '%recentlyOpened%' ORDER BY key LIMIT 1"),
               let parsed = parseEntries(from: data), !parsed.isEmpty { return parsed }
        }

        // Legacy: storage.json (pre-SQLite VS Code)
        let jsonURL = URL(fileURLWithPath: home + "/Library/Application Support/Code/storage.json")
        if let data = try? Data(contentsOf: jsonURL),
           let root  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let val   = root["history.recentlyOpenedPathsList"] {
            if let sub = try? JSONSerialization.data(withJSONObject: val),
               let p   = parseEntries(from: sub), !p.isEmpty { return p }
            if let str = val as? String, let sub = str.data(using: .utf8),
               let p   = parseEntries(from: sub), !p.isEmpty { return p }
        }
        return []
    }

    /// Read VS Code recent projects from macOS SharedFileList (File → Open Recent).
    /// Works with VS Code 1.119+ and any version that integrates with macOS recent documents.
    /// Each SFL entry contains an NSURLBookmark blob we resolve to a file URL.
    private func fetchFromSharedFileList() -> [VSCodeRecentProject]? {
        let home = NSHomeDirectory()
        let sflDir = "\(home)/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"

        for bundleId in ["com.microsoft.vscode", "com.microsoft.VSCode"] {
            for ext in ["sfl4", "sfl3", "sfl2"] {
                let sflPath = "\(sflDir)/\(bundleId).\(ext)"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: sflPath)),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                      let objects = plist["$objects"] as? [Any] else { continue }

                var projects: [VSCodeRecentProject] = []
                var seen = Set<String>()

                for obj in objects {
                    // Bookmark blobs are raw Data entries in the $objects array; skip tiny entries
                    guard let bookmarkData = obj as? Data, bookmarkData.count > 64 else { continue }
                    var stale = false
                    guard let url = try? URL(resolvingBookmarkData: bookmarkData,
                                             options: [.withoutUI, .withoutMounting],
                                             relativeTo: nil,
                                             bookmarkDataIsStale: &stale),
                          url.isFileURL else { continue }
                    let path = url.path
                    guard !seen.contains(path) else { continue }
                    seen.insert(path)
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                    let isWorkspace = path.hasSuffix(".code-workspace")
                    // Only include directories and workspace files (skip individual files)
                    guard isDir.boolValue || isWorkspace else { continue }
                    let name = isWorkspace
                        ? url.deletingPathExtension().lastPathComponent
                        : url.lastPathComponent
                    projects.append(VSCodeRecentProject(name: name, path: path, isWorkspace: isWorkspace))
                }

                if !projects.isEmpty { return projects }
            }
        }
        return nil
    }

    /// Execute a SQLite query and return trimmed stdout as Data, or nil on failure / empty output.
    private func runSQLite(db: String, sql: String) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments     = [db, sql]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw.data(using: .utf8)
    }

    private func parseEntries(from data: Data) -> [VSCodeRecentProject]? {
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return nil }
        return entries.compactMap { e -> VSCodeRecentProject? in
            if let uri = e["folderUri"] as? String, let url = URL(string: uri), url.isFileURL {
                return VSCodeRecentProject(name: url.lastPathComponent, path: url.path, isWorkspace: false)
            }
            if let ws  = e["workspace"] as? [String: Any],
               let cfg = ws["configPath"] as? String,
               let url = URL(string: cfg), url.isFileURL {
                return VSCodeRecentProject(name: url.deletingPathExtension().lastPathComponent,
                                          path: url.path, isWorkspace: true)
            }
            return nil
        }
    }

    // MARK: Git branch (direct Process — no shell startup overhead)

    private func gitBranch(for path: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments     = ["-C", path, "branch", "--show-current"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        guard (try? task.run()) != nil else { return "" }
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
