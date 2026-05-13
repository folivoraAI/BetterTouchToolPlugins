// BTT-Plugin-Name: Cursor Launcher
// BTT-Plugin-Identifier: com.bttuserplugin.cursor.launcher
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: cursorarrow.rays
// BTT-AI-Managed: true

import AppKit

// MARK: - Data model

struct CursorRecentProject {
    let name: String
    let path: String
    let isWorkspace: Bool

    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Plugin

class CursorLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let searchRecent   = "cursor-search-recent"
        static let openWithCursor = "cursor-open-with-cursor"
        static let openNewWindow  = "cursor-open-new-window"
        static let recentChildren = "cursor-recent-children"
        static let openProject    = "cursor-open-project"
    }

    // MARK: Metadata

    static func launcherPluginName()        -> String { "Cursor" }
    static func launcherPluginDescription() -> String { "Search recent projects, open with Cursor, new window." }
    static func launcherPluginIcon()        -> String { "cursorarrow.rays" }

    // MARK: Top-level results

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        var items: [BTTLauncherPluginResult] = []

        // 1 — Search Recent Projects (Cursor)
        let recent = BTTLauncherPluginResult()
        recent.itemIdentifier            = IDs.searchRecent
        recent.title                     = "Search Recent Projects"
        recent.subtitle                  = "Cursor — Browse recently opened projects"
        recent.iconImage                 = cursorIcon()
        recent.trailingHint              = "Browse"
        recent.dynamicChildrenIdentifier = IDs.recentChildren
        recent.opensChildrenByDefault    = true
        recent.sortOrder                 = 0
        items.append(recent)

        // 2 — Open with Cursor
        let openWith = BTTLauncherPluginResult()
        openWith.itemIdentifier          = IDs.openWithCursor
        openWith.title                   = "Open with Cursor"
        openWith.subtitle = {
            if context.finderSelection == true, let url = context.finderURLs?.first {
                return "Cursor — \(url.lastPathComponent)"
            }
            return "Cursor — Open selected Finder folder"
        }()
        openWith.iconImage               = cursorIcon()
        openWith.trailingHint            = "Open"
        openWith.primaryActionIdentifier = IDs.openWithCursor
        openWith.sortOrder               = 1
        items.append(openWith)

        // 3 — Open New Window (Cursor)
        let newWin = BTTLauncherPluginResult()
        newWin.itemIdentifier            = IDs.openNewWindow
        newWin.title                     = "Open New Window"
        newWin.subtitle                  = "Cursor — Launch a fresh editor window"
        newWin.iconImage                 = cursorIcon()
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

            // Fetch all git branches in parallel – each iteration hits a different index,
            // so unsafeMutableBufferPointer + concurrentPerform is safe here.
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

        // Project children encode path in itemIdentifier – match by prefix first
        // so opening works regardless of whether BTT passes actionIdentifier or not.
        let projectPrefix = "\(IDs.openProject):"
        if itemIdentifier.hasPrefix(projectPrefix) {
            let path = String(itemIdentifier.dropFirst(projectPrefix.count))
            openPathWithCursor(path)
            out.success = true; out.closeLauncher = true
            return out
        }

        switch actionIdentifier ?? itemIdentifier {

        case IDs.openWithCursor:
            guard let urls = context.finderURLs, !urls.isEmpty else {
                out.success = false; out.message = "No item selected in Finder"
                out.closeLauncher = false; return out
            }
            openURLsWithCursor(urls)
            out.success = true; out.closeLauncher = true

        case IDs.openNewWindow:
            openNewCursorWindow()
            out.success = true; out.closeLauncher = true

        default:
            out.success = false
        }
        return out
    }

    // MARK: Cursor launch (no shell scripts – direct Process / NSWorkspace)

    private func openPathWithCursor(_ path: String) {
        if tryLaunchCLI(arguments: ["--new-window", path]) { return }
        let url = URL(fileURLWithPath: path)
        if let app = findCursorApp() {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = ["--new-window"]
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, _ in }
        }
    }

    private func openURLsWithCursor(_ urls: [URL]) {
        if tryLaunchCLI(arguments: urls.map { $0.path }) { return }
        if let app = findCursorApp() {
            NSWorkspace.shared.open(urls, withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    private func openNewCursorWindow() {
        if tryLaunchCLI(arguments: ["--new-window"]) { return }
        if let app = findCursorApp() {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.arguments = ["--new-window"]
            NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in }
        }
    }

    /// Try each CLI candidate in order; return true on the first hit.
    private func tryLaunchCLI(arguments: [String]) -> Bool {
        let home = NSHomeDirectory()
        let candidates = [
            "/usr/local/bin/cursor",
            "/opt/homebrew/bin/cursor",
            home + "/.cursor/bin/cursor",
            "/usr/bin/cursor",
        ]
        for cli in candidates {
            guard FileManager.default.isExecutableFile(atPath: cli) else { continue }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: cli)
            task.arguments     = arguments
            try? task.run()      // non-blocking; Cursor takes over
            return true
        }
        return false
    }

    private func findCursorApp() -> URL? {
        // 1. Known bundle IDs
        for bid in ["com.todesktop.230313mzl4w4u92", "com.cursor.app"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) { return url }
        }
        // 2. Standard install locations
        for p in ["/Applications/Cursor.app",
                  NSHomeDirectory() + "/Applications/Cursor.app"] {
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// Returns the real Cursor.app icon loaded directly from the bundle
    /// (bypasses NSWorkspace framing that can add a white border at small sizes).
    private func cursorIcon() -> NSImage {
        if let url = findCursorApp() {
            // Load straight from the .icns in Resources – no macOS shadow/framing
            if let bundle = Bundle(url: url),
               let iconFile = bundle.infoDictionary?["CFBundleIconFile"] as? String {
                let icnsName = iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns"
                let icnsPath = (bundle.resourcePath ?? "") + "/" + icnsName
                if let img = NSImage(contentsOfFile: icnsPath) { return img }
            }
            // Fallback: workspace icon (may include system framing)
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return makeIcon("cursorarrow.rays",
                        color: NSColor(calibratedRed: 0.22, green: 0.53, blue: 0.96, alpha: 1))
    }

    // MARK: Icon rendering

    private func makeIcon(_ systemName: String, color: NSColor) -> NSImage {
        let size: CGFloat = 40
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Rounded-rect background
            let bg = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            color.setFill()
            bg.fill()

            // SF Symbol in white
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

    private func fetchRecentProjects() -> [CursorRecentProject] {
        let home   = NSHomeDirectory()
        let dbPath = home + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb"

        // SQLite path (Cursor 0.30+) — run via Process to avoid shell overhead
        let sqlTask = Process()
        sqlTask.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlTask.arguments     = [dbPath, "SELECT value FROM ItemTable WHERE key='history.recentlyOpenedPathsList'"]
        let sqlPipe = Pipe()
        sqlTask.standardOutput = sqlPipe
        sqlTask.standardError  = Pipe()
        if (try? sqlTask.run()) != nil {
            sqlTask.waitUntilExit()
            let raw = String(data: sqlPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !raw.isEmpty,
               let data   = raw.data(using: .utf8),
               let parsed = parseEntries(from: data), !parsed.isEmpty { return parsed }
        }

        // Fallback: storage.json
        let jsonURL = URL(fileURLWithPath: home + "/Library/Application Support/Cursor/storage.json")
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

    private func parseEntries(from data: Data) -> [CursorRecentProject]? {
        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return nil }
        return entries.compactMap { e -> CursorRecentProject? in
            if let uri = e["folderUri"] as? String, let url = URL(string: uri), url.isFileURL {
                return CursorRecentProject(name: url.lastPathComponent, path: url.path, isWorkspace: false)
            }
            if let ws  = e["workspace"] as? [String: Any],
               let cfg = ws["configPath"] as? String,
               let url = URL(string: cfg), url.isFileURL {
                return CursorRecentProject(name: url.deletingPathExtension().lastPathComponent,
                                           path: url.path, isWorkspace: true)
            }
            return nil
        }
    }

    // MARK: Git branch (direct Process – no shell startup overhead)

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
