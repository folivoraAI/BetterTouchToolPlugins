// BTT-Plugin-Name: Jira Issues
// BTT-Plugin-Identifier: com.bttuserplugin.jira.launcher
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: list.bullet.rectangle
// BTT-Plugin-Description: Browse and search your Jira issues
// BTT-AI-Managed: true

import Foundation
import AppKit
import SwiftUI

// MARK: - Data Model

struct JiraIssue {
    let key: String
    let summary: String
    let status: String
    let statusCategory: String
    let issueType: String
    let priority: String
}

struct JiraSurfaceState {
    let issues: [JiraIssue]
    let error: String?
    let lastFetchTime: Date?
}

// MARK: - UserDefaults Persistence

private enum JiraDefaults {
    static let baseURLKey = "com.bttuserplugin.jira.baseURL"
    static let tokenKey   = "com.bttuserplugin.jira.token"
    static let jqlKey     = "com.bttuserplugin.jira.jql"

    static func load() -> (url: String, token: String, jql: String) {
        let url   = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        let token = UserDefaults.standard.string(forKey: tokenKey)   ?? ""
        let jql   = UserDefaults.standard.string(forKey: jqlKey)     ?? "assignee = currentUser() ORDER BY updated DESC"
        return (url, token, jql)
    }

    static func save(url: String, token: String, jql: String) {
        UserDefaults.standard.set(url,   forKey: baseURLKey)
        UserDefaults.standard.set(token, forKey: tokenKey)
        UserDefaults.standard.set(jql,   forKey: jqlKey)
    }
}

/// Persists the user's preferred main-surface size across launches.
private enum JiraSurfaceSize {
    static let widthKey  = "com.bttuserplugin.jira.surfaceWidth"
    static let heightKey = "com.bttuserplugin.jira.surfaceHeight"

    static let defaultSize  = CGSize(width: 860, height: 620)
    static let minWidth:  CGFloat = 480
    static let minHeight: CGFloat = 320
    static let maxWidth:  CGFloat = 2000
    static let maxHeight: CGFloat = 1600

    static func load() -> CGSize {
        let w = UserDefaults.standard.object(forKey: widthKey)  as? CGFloat
        let h = UserDefaults.standard.object(forKey: heightKey) as? CGFloat
        guard let w, let h else { return defaultSize }
        return CGSize(
            width:  min(maxWidth,  max(minWidth,  w)),
            height: min(maxHeight, max(minHeight, h))
        )
    }

    static func save(_ size: CGSize) {
        guard size.width >= minWidth, size.height >= minHeight else { return }
        UserDefaults.standard.set(size.width,  forKey: widthKey)
        UserDefaults.standard.set(size.height, forKey: heightKey)
    }
}

// MARK: - Plugin

class JiraLauncherPlugin: NSObject, BTTLauncherPluginInterface {

    weak var delegate: (any BTTLauncherPluginDelegate)?

    // MARK: Configuration
    private var jiraBaseURL = ""
    private var jiraToken   = ""
    private var jiraJQL     = "assignee = currentUser() ORDER BY updated DESC"
    private let maxResults  = 50

    // MARK: Cache
    private var cachedIssues: [JiraIssue] = []
    private var lastFetchTime: Date?
    private var lastError: String?
    private var isFetching  = false
    private let cacheTTL: TimeInterval = 300

    // MARK: Init
    required override init() {
        super.init()
        let saved = JiraDefaults.load()
        jiraBaseURL = saved.url
        jiraJQL     = saved.jql
        if let env = ProcessInfo.processInfo.environment["JIRA_TOKEN"], !env.isEmpty {
            jiraToken = env
        } else if !saved.token.isEmpty {
            jiraToken = saved.token
        }
    }

    // MARK: Metadata
    static func launcherPluginName()        -> String { "Jira Issues" }
    static func launcherPluginDescription() -> String { "Browse and search your Jira issues" }
    static func launcherPluginIcon()        -> String { "list.bullet.rectangle" }

    // MARK: Configuration Form (BTT Preferences)
    static func configurationFormItems() -> BTTPluginFormItem? {
        let group = BTTPluginFormItem()
        group.formFieldType = BTTFormTypeFormGroup
        group.formLabel1    = "Jira Connection"

        let desc = BTTPluginFormItem()
        desc.formFieldType = BTTFormTypeDescription
        desc.formLabel1    = "Connect with a Personal Access Token (PAT). If the JIRA_TOKEN environment variable is set it is loaded automatically."

        let sep0 = BTTPluginFormItem()
        sep0.formFieldType = BTTFormTypeSeparator

        let urlField = BTTPluginFormItem()
        urlField.formFieldType = BTTFormTypeTextField
        urlField.formLabel1    = "Jira Base URL"
        urlField.formFieldID   = "jiraBaseURL"
        urlField.defaultValue  = "https://jira.corp.YOUR_ORG.com"

        let tokenField = BTTPluginFormItem()
        tokenField.formFieldType = BTTFormTypeTextField
        tokenField.formLabel1    = "API Token (PAT)"
        tokenField.formFieldID   = "jiraToken"
        tokenField.defaultValue  = ""

        let sep1 = BTTPluginFormItem()
        sep1.formFieldType = BTTFormTypeSeparator

        let jqlField = BTTPluginFormItem()
        jqlField.formFieldType = BTTFormTypeTextField
        jqlField.formLabel1    = "JQL Query"
        jqlField.formFieldID   = "jiraJQL"
        jqlField.defaultValue  = "assignee = currentUser() ORDER BY updated DESC"

        group.formOptions = [desc, sep0, urlField, tokenField, sep1, jqlField]
        return group
    }

    func didReceiveNewConfigurationValues(_ configurationValues: [AnyHashable: Any]?) {
        guard let v = configurationValues else { return }
        var changed = false
        // Ignore the BTT form's placeholder default on every launch; otherwise
        // the saved URL would get clobbered with the placeholder.
        let urlPlaceholder = "https://jira.corp.YOUR_ORG.com"
        if let url = v["jiraBaseURL"] as? String,
           !url.isEmpty,
           url != urlPlaceholder,
           url != jiraBaseURL {
            jiraBaseURL = url; changed = true
        }
        // Only overwrite token if BTT form provides a non-empty value;
        // otherwise the empty preferences field would erase the saved PAT.
        if let tok = v["jiraToken"] as? String, !tok.isEmpty, tok != jiraToken {
            jiraToken = tok; changed = true
        }
        if let jql = v["jiraJQL"] as? String, !jql.isEmpty, jql != jiraJQL {
            jiraJQL = jql; changed = true
        }
        if changed {
            JiraDefaults.save(url: jiraBaseURL, token: jiraToken, jql: jiraJQL)
            invalidateCache()
        }
    }

    func applyConfig(url: String, token: String, jql: String) {
        let changed = url != jiraBaseURL || token != jiraToken || jql != jiraJQL
        guard changed else { return }
        jiraBaseURL = url
        jiraToken   = token
        jiraJQL     = jql
        JiraDefaults.save(url: url, token: token, jql: jql)
        invalidateCache()
        delegate?.requestLauncherResultsRefresh()
    }

    // MARK: Sync Results
    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        [makeMainResult()]
    }

    // MARK: Async Results
    func loadLauncherResults(for context: BTTLauncherPluginContext,
                             completion: @escaping ([BTTLauncherPluginResult]?) -> Void) {
        completion([makeMainResult()])
    }

    // MARK: Surface
    func launcherSurface(forItemIdentifier itemIdentifier: String,
                         surfaceIdentifier: String?,
                         context: BTTLauncherPluginContext) -> (any BTTLauncherPluginSurfaceInterface)? {
        if surfaceIdentifier == "jira-main" {
            return JiraMainSurface(
                initialURL: jiraBaseURL,
                initialToken: jiraToken,
                initialJQL: jiraJQL,
                initialState: currentSurfaceState(),
                onSaveConfig: { [weak self] url, token, jql in
                    self?.applyConfig(url: url, token: token, jql: jql)
                },
                onRefresh: { [weak self] jql, force, completion in
                    self?.refreshState(jql: jql, force: force, completion: completion)
                },
                onOpenIssue: { [weak self] key in
                    self?.openIssue(withKey: key)
                }
            )
        }

        guard surfaceIdentifier == "jira-config" else { return nil }
        return JiraConfigSurface(
            initialURL:   jiraBaseURL,
            initialToken: jiraToken,
            initialJQL:   jiraJQL,
            onSave: { [weak self] url, token, jql in
                self?.applyConfig(url: url, token: token, jql: jql)
            }
        )
    }

    // MARK: Actions
    func launcherResultSelected(_ result: BTTLauncherPluginResult,
                                context: BTTLauncherPluginContext) {
        guard let id = result.itemIdentifier else { return }
        if id == "jira-root" { return }
        if id == "refresh" {
            invalidateCache()
            delegate?.requestLauncherResultsRefresh()
            return
        }
        if id == "setup" || id == "settings" || id == "empty" || id == "error" { return }
        openIssue(withKey: id)
    }

    func launcherResultCommandSelected(_ result: BTTLauncherPluginResult,
                                       command: BTTLauncherPluginCommand,
                                       context: BTTLauncherPluginContext) {
        guard let id = result.itemIdentifier else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if command.commandIdentifier == "copy_url" {
            pb.setString("\(jiraBaseURL)/browse/\(id)", forType: .string)
        } else if command.commandIdentifier == "copy_key" {
            pb.setString(id, forType: .string)
        }
    }

    // MARK: Private Helpers

    private var isConfigured: Bool { !jiraToken.isEmpty && !jiraBaseURL.isEmpty }

    private func invalidateCache() {
        cachedIssues  = []
        lastFetchTime = nil
        lastError     = nil
    }

    private func currentSurfaceState() -> JiraSurfaceState {
        JiraSurfaceState(issues: cachedIssues, error: lastError, lastFetchTime: lastFetchTime)
    }

    private func refreshState(jql: String,
                              force: Bool,
                              completion: @escaping (JiraSurfaceState) -> Void) {
        if !isConfigured {
            completion(currentSurfaceState())
            return
        }

        let trimmed = jql.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveJQL = trimmed.isEmpty ? jiraJQL : trimmed
        fetchIssues(jql: effectiveJQL) { [weak self] in
            guard let self else { return }
            completion(self.currentSurfaceState())
        }
    }

    private func openIssue(withKey key: String) {
        guard let url = URL(string: "\(jiraBaseURL)/browse/\(key)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func makeMainResult() -> BTTLauncherPluginResult {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier = "jira-root"
        r.title = "Jira"
        r.subtitle = isConfigured ? "Open Jira dashboard" : "Open Jira and configure connection"
        r.systemImageName = "list.bullet.rectangle"
        r.surfaceIdentifier = "jira-main"
        r.trailingHint = "Open"
        return r
    }

    private func buildResults(query: String) -> [BTTLauncherPluginResult] {
        var results: [BTTLauncherPluginResult] = []

        let q = query.lowercased()
        let filtered = q.isEmpty ? cachedIssues : cachedIssues.filter {
            $0.key.lowercased().contains(q)      ||
            $0.summary.lowercased().contains(q)  ||
            $0.status.lowercased().contains(q)   ||
            $0.issueType.lowercased().contains(q)
        }

        if filtered.isEmpty {
            if let err = lastError {
                results.append(makeErrorResult(err))
            } else {
                results.append(makeEmptyResult(query: query))
            }
        } else {
            results = filtered.map { makeIssueResult($0) }
        }
        results.append(makeRefreshResult())
        results.append(makeSettingsResult())
        return results
    }

    private func makeIssueResult(_ issue: JiraIssue) -> BTTLauncherPluginResult {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier  = issue.key
        r.title           = "\(issue.key): \(issue.summary)"
        r.subtitle        = "\(statusEmoji(issue.statusCategory)) \(issue.status)  ·  \(priorityLabel(issue.priority))  ·  \(issue.issueType)"
        r.systemImageName = typeIcon(issue.issueType)

        let copyURL = BTTLauncherPluginCommand()
        copyURL.title             = "Copy URL"
        copyURL.commandIdentifier = "copy_url"
        let urlShortcut = BTTLauncherPluginShortcut()
        urlShortcut.character     = "u"
        urlShortcut.modifierFlags = [.command]
        urlShortcut.displayKeys   = ["⌘", "U"]
        copyURL.shortcut = urlShortcut

        let copyKey = BTTLauncherPluginCommand()
        copyKey.title             = "Copy Key"
        copyKey.commandIdentifier = "copy_key"
        let keyShortcut = BTTLauncherPluginShortcut()
        keyShortcut.character     = "k"
        keyShortcut.modifierFlags = [.command]
        keyShortcut.displayKeys   = ["⌘", "K"]
        copyKey.shortcut = keyShortcut

        r.commands = [copyURL, copyKey]
        return r
    }

    private func makeSetupResult() -> BTTLauncherPluginResult {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier    = "setup"
        r.title             = "Configure Jira Connection"
        r.subtitle          = "Enter your Jira Base URL and Personal Access Token (PAT)"
        r.systemImageName   = "gear.badge.questionmark"
        r.surfaceIdentifier = "jira-config"
        r.trailingHint      = "Open"
        return r
    }

    private func makeSettingsResult() -> BTTLauncherPluginResult {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier    = "settings"
        r.title             = "Settings"
        r.subtitle          = jiraBaseURL
        r.systemImageName   = "gear"
        r.surfaceIdentifier = "jira-config"
        r.trailingHint      = "Configure"
        return r
    }

    private func makeRefreshResult() -> BTTLauncherPluginResult {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier  = "refresh"
        r.title           = "Refresh"
        if let last = lastFetchTime {
            let fmt = RelativeDateTimeFormatter()
            fmt.unitsStyle = .short
            r.subtitle = "Last updated \(fmt.localizedString(for: last, relativeTo: Date()))"
        } else {
            r.subtitle = "Fetch latest issues from Jira"
        }
        r.systemImageName = "arrow.clockwise"
        return r
    }

    private func makeErrorResult(_ msg: String) -> BTTLauncherPluginResult {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier  = "error"
        r.title           = "Failed to load Jira issues"
        r.subtitle        = msg
        r.systemImageName = "exclamationmark.triangle"
        return r
    }

    private func makeEmptyResult(query: String) -> BTTLauncherPluginResult {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier  = "empty"
        r.title           = query.isEmpty ? "No issues found" : "No results for \"\(query)\""
        r.subtitle        = "Try adjusting your JQL query in plugin settings"
        r.systemImageName = "magnifyingglass"
        return r
    }

    private func typeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "bug":                        return "ladybug.fill"
        case "story", "user story":        return "book.fill"
        case "task":                       return "checkmark.circle.fill"
        case "epic":                       return "bolt.fill"
        case "sub-task", "subtask":        return "arrow.turn.down.right"
        case "improvement", "new feature": return "star.fill"
        default:                           return "ticket"
        }
    }

    private func statusEmoji(_ cat: String) -> String {
        switch cat.lowercased() {
        case "in progress", "indeterminate": return "🔵"
        case "done":                         return "✅"
        default:                             return "⚪️"
        }
    }

    private func priorityLabel(_ p: String) -> String {
        switch p.lowercased() {
        case "blocker":  return "🔴 Blocker"
        case "critical": return "🟠 Critical"
        case "major":    return "🟡 Major"
        case "minor":    return "🟢 Minor"
        case "trivial":  return "⚪ Trivial"
        default:         return p
        }
    }

    // MARK: API Fetch
    private func fetchIssues(completion: @escaping () -> Void) {
        fetchIssues(jql: jiraJQL, completion: completion)
    }

    private func fetchIssues(jql: String, completion: @escaping () -> Void) {
        guard !isFetching else { completion(); return }
        isFetching = true

        let fields = "summary,status,issuetype,priority"
        guard let encodedJQL = jql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(jiraBaseURL)/rest/api/2/search?jql=\(encodedJQL)&fields=\(fields)&maxResults=\(maxResults)") else {
            lastError  = "Invalid Jira URL"
            isFetching = false
            completion()
            return
        }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(jiraToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",    forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFetching = false

                if let error = error {
                    self.lastError = error.localizedDescription
                    completion(); return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    self.lastError = "HTTP \(http.statusCode)"
                    completion(); return
                }
                guard let data   = data,
                      let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let issues = json["issues"] as? [[String: Any]] else {
                    self.lastError = "Could not parse Jira response"
                    completion(); return
                }

                self.cachedIssues = issues.compactMap { issue -> JiraIssue? in
                    guard let key    = issue["key"] as? String,
                          let fields = issue["fields"] as? [String: Any] else { return nil }
                    let summary   = fields["summary"]   as? String ?? ""
                    let statusObj = fields["status"]    as? [String: Any]
                    let status    = statusObj?["name"]  as? String ?? ""
                    let statusCat = (statusObj?["statusCategory"] as? [String: Any])?["name"] as? String ?? ""
                    let typeObj   = fields["issuetype"] as? [String: Any]
                    let issueType = typeObj?["name"]    as? String ?? ""
                    let priorObj  = fields["priority"]  as? [String: Any]
                    let priority  = priorObj?["name"]   as? String ?? ""
                    return JiraIssue(key: key, summary: summary, status: status,
                                     statusCategory: statusCat, issueType: issueType, priority: priority)
                }
                self.lastFetchTime = Date()
                self.lastError     = nil
                completion()
            }
        }.resume()
    }
}

// MARK: - Focus-aware Hosting View

private final class FocusableHostingView<Root: View>: NSHostingView<Root> {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onSelectCurrent: (() -> Void)?
    /// Called whenever the host window's content size changes. The surface
    /// uses this to persist the user's preferred size to UserDefaults.
    var onSizeChanged: ((CGSize) -> Void)?
    private var eventMonitor: Any?
    private var resizeObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            installMonitor()
            installResizeObserver(on: window)
        } else {
            removeMonitor()
            removeResizeObserver()
        }
    }

    private func installMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Navigation keys are always intercepted first, even when the launcher's
            // search field is the first responder — otherwise it would swallow them.
            switch event.keyCode {
            case 125: self.onMoveDown?();      return nil   // ↓
            case 126: self.onMoveUp?();        return nil   // ↑
            case 36, 76: self.onSelectCurrent?(); return nil // Return / numpad Enter
            default:
                // Let text fields / search fields keep their own non-nav key events
                if let fr = self.window?.firstResponder, fr is NSTextView {
                    return event
                }
                // Redirect typed characters to the launcher's search field that
                // lives outside our hosting view, so the user can start typing
                // from anywhere in the surface without clicking the search box.
                if self.redirectTypedCharacterToLauncherSearch(event) {
                    return nil
                }
                return event
            }
        }
    }

    /// If the event is a printable character (no Command/Control/Option) and
    /// the launcher's external search field can be found, focus it and insert
    /// the character. Returns `true` when the event was redirected.
    private func redirectTypedCharacterToLauncherSearch(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Allow plain typing and Shift-typing; ignore ⌘/⌃/⌥ shortcuts.
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return false
        }
        guard let chars = event.charactersIgnoringModifiers,
              !chars.isEmpty,
              let scalar = chars.unicodeScalars.first,
              CharacterSet.alphanumerics.union(.punctuationCharacters)
                  .union(.symbols).union(.whitespaces).contains(scalar) else {
            return false
        }
        guard let window = self.window,
              let searchField = self.findLauncherSearchField(in: window.contentView) else {
            return false
        }
        // Focus the search field and forward the typed character into it.
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.insertText(event.characters ?? chars)
        } else {
            searchField.stringValue.append(event.characters ?? chars)
        }
        return true
    }

    /// Walks the window's view hierarchy looking for an `NSTextField` that is
    /// NOT inside our hosting view. The launcher's search box matches this.
    private func findLauncherSearchField(in root: NSView?) -> NSTextField? {
        guard let root else { return nil }
        if root === self { return nil }
        if let tf = root as? NSTextField, tf.isEditable, !tf.isHidden,
           !self.contains(view: tf) {
            return tf
        }
        for sub in root.subviews {
            if sub === self { continue }
            if let found = findLauncherSearchField(in: sub) { return found }
        }
        return nil
    }

    /// True iff `view` lives anywhere in the subtree rooted at `self`.
    private func contains(view: NSView) -> Bool {
        var v: NSView? = view
        while let candidate = v {
            if candidate === self { return true }
            v = candidate.superview
        }
        return false
    }

    private func removeMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
    }

    private func installResizeObserver(on window: NSWindow) {
        removeResizeObserver()
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.onSizeChanged?(window.contentLayoutRect.size)
        }
    }

    private func removeResizeObserver() {
        if let token = resizeObserver { NotificationCenter.default.removeObserver(token) }
        resizeObserver = nil
    }

    deinit { removeMonitor(); removeResizeObserver() }
}

// MARK: - Main Surface

final class JiraMainSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?

    private let initialURL: String
    private let initialToken: String
    private let initialJQL: String
    private let initialState: JiraSurfaceState
    private let onSaveConfig: (String, String, String) -> Void
    private let onRefresh: (String, Bool, @escaping (JiraSurfaceState) -> Void) -> Void
    private let onOpenIssue: (String) -> Void
    private var vm: JiraMainViewModel?

    fileprivate init(initialURL: String,
         initialToken: String,
         initialJQL: String,
         initialState: JiraSurfaceState,
         onSaveConfig: @escaping (String, String, String) -> Void,
         onRefresh: @escaping (String, Bool, @escaping (JiraSurfaceState) -> Void) -> Void,
         onOpenIssue: @escaping (String) -> Void) {
        self.initialURL = initialURL
        self.initialToken = initialToken
        self.initialJQL = initialJQL
        self.initialState = initialState
        self.onSaveConfig = onSaveConfig
        self.onRefresh = onRefresh
        self.onOpenIssue = onOpenIssue
    }

    func makeLauncherSurfaceView() -> NSView {
        // Wrap the open-issue callback so the launcher closes after the
        // browser is launched. The surface delegate (provided by BTT)
        // exposes requestLauncherSurfaceClose() for exactly this purpose.
        let openIssueAndClose: (String) -> Void = { [weak self] key in
            self?.onOpenIssue(key)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.requestLauncherSurfaceClose()
            }
        }

        let vm = JiraMainViewModel(
            initialURL: initialURL,
            initialToken: initialToken,
            initialJQL: initialJQL,
            initialState: initialState,
            onSaveConfig: onSaveConfig,
            onRefresh: onRefresh,
            onOpenIssue: openIssueAndClose
        )
        self.vm = vm
        let hostingView = FocusableHostingView(rootView: JiraMainView(vm: vm))
        hostingView.onMoveUp = { [weak vm] in DispatchQueue.main.async { vm?.navigateUp() } }
        hostingView.onMoveDown = { [weak vm] in DispatchQueue.main.async { vm?.navigateDown() } }
        hostingView.onSelectCurrent = { [weak vm] in DispatchQueue.main.async { vm?.openSelected() } }
        hostingView.onSizeChanged = { size in
            JiraSurfaceSize.save(size)
        }
        return hostingView
    }

    func launcherSurfacePreferredContentSize() -> CGSize { JiraSurfaceSize.load() }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }
    func launcherSurfacePlaceholderText() -> String? { "Jira" }
    func launcherSurfaceFooterHint() -> String? { "Return Open Issue  |  Cmd+R Refresh  |  Cmd+, Settings" }

    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool {
        // Let BTT keep handling navigation keys (↑/↓/Return) so it can route
        // them through handleLauncherInputCommand. Everything else — in
        // particular printable characters going to the search field — bypasses.
        guard event.type == .keyDown else { return true }
        switch event.keyCode {
        case 125, 126, 36, 76, 123, 124: return false   // ↓ ↑ Return Enter ← →
        default: return true
        }
    }

    func launcherSurfaceQueryDidChange(_ query: String?) {
        vm?.filterQuery = query ?? ""
    }

    // BTT routes arrow keys through this hook regardless of which view holds
    // focus — use it as the primary navigation path so the launcher's search
    // field can't swallow ↑/↓.
    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        let result = BTTLauncherPluginSurfaceCommandResult()
        switch command {
        case .moveUp:
            DispatchQueue.main.async { [weak self] in self?.vm?.navigateUp() }
            result.handled = true
            return result
        case .moveDown:
            DispatchQueue.main.async { [weak self] in self?.vm?.navigateDown() }
            result.handled = true
            return result
        default:
            return nil
        }
    }

    // BTT doesn't expose a `confirmSelection` input command, so handle Return /
    // numpad Enter directly here. This fires regardless of whether the launcher's
    // search field has focus.
    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 36 || event.keyCode == 76 {
            DispatchQueue.main.async { [weak self] in
                self?.vm?.openSelected()
                self?.delegate?.requestLauncherSurfaceClose()
            }
            return true
        }
        return false
    }
}

enum JiraTab: String, CaseIterable, Identifiable {
    case assignedToMe
    case reportedByMe
    case watching
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assignedToMe: return "Assigned to me"
        case .reportedByMe: return "Reported by me"
        case .watching:     return "Watching"
        case .custom:       return "Custom JQL"
        }
    }

    var icon: String {
        switch self {
        case .assignedToMe: return "person.crop.circle.badge.checkmark"
        case .reportedByMe: return "square.and.pencil"
        case .watching:     return "eye"
        case .custom:       return "line.3.horizontal.decrease.circle"
        }
    }

    var tint: Color {
        switch self {
        case .assignedToMe: return .accentColor
        case .reportedByMe: return .purple
        case .watching:     return .teal
        case .custom:       return .orange
        }
    }

    var jql: String {
        switch self {
        case .assignedToMe: return "assignee = currentUser() ORDER BY updated DESC"
        case .reportedByMe: return "reporter = currentUser() ORDER BY updated DESC"
        case .watching:     return "watcher = currentUser() ORDER BY updated DESC"
        case .custom:       return ""
        }
    }
}

final class JiraMainViewModel: ObservableObject {
    @Published var url: String
    @Published var token: String
    @Published var jql: String
    @Published var issues: [JiraIssue]
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var selectedTab: JiraTab = .assignedToMe
    @Published var customJQL: String
    @Published var filterQuery: String = "" {
        didSet { selectedIssueKey = nil }
    }
    @Published var selectedIssueKey: String? = nil

    var filteredIssues: [JiraIssue] {
        let q = filterQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return issues }
        return issues.filter {
            $0.key.lowercased().contains(q)      ||
            $0.summary.lowercased().contains(q)  ||
            $0.status.lowercased().contains(q)   ||
            $0.issueType.lowercased().contains(q)
        }
    }

    private let onSaveConfig: (String, String, String) -> Void
    private let onRefresh: (String, Bool, @escaping (JiraSurfaceState) -> Void) -> Void
    private let onOpenIssue: (String) -> Void

    fileprivate init(initialURL: String,
         initialToken: String,
         initialJQL: String,
         initialState: JiraSurfaceState,
         onSaveConfig: @escaping (String, String, String) -> Void,
         onRefresh: @escaping (String, Bool, @escaping (JiraSurfaceState) -> Void) -> Void,
         onOpenIssue: @escaping (String) -> Void) {
        self.url = initialURL
        self.token = initialToken
        self.jql = initialJQL
        self.customJQL = initialJQL
        self.issues = initialState.issues
        self.errorMessage = initialState.error
        self.lastUpdated = initialState.lastFetchTime
        self.onSaveConfig = onSaveConfig
        self.onRefresh = onRefresh
        self.onOpenIssue = onOpenIssue
    }

    var canConnect: Bool { !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !token.isEmpty }

    var activeJQL: String {
        switch selectedTab {
        case .custom: return customJQL
        default:      return selectedTab.jql
        }
    }

    func saveConfiguration() {
        onSaveConfig(url.trimmingCharacters(in: .whitespacesAndNewlines), token, jql.trimmingCharacters(in: .whitespacesAndNewlines))
        refresh(force: true)
    }

    func selectTab(_ tab: JiraTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        selectedIssueKey = nil
        if tab != .custom {
            refresh(force: true)
        }
    }

    func runCustomQuery() {
        selectedTab = .custom
        refresh(force: true)
    }

    func loadIfNeeded() {
        guard canConnect else { return }
        if issues.isEmpty {
            refresh(force: true)
        }
    }

    func refresh(force: Bool) {
        guard canConnect else {
            errorMessage = "Enter Base URL and PAT token in Settings."
            return
        }

        let jqlToRun = activeJQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jqlToRun.isEmpty else {
            errorMessage = "Enter a JQL query."
            issues = []
            return
        }

        isLoading = true
        errorMessage = nil
        onRefresh(jqlToRun, force) { [weak self] state in
            guard let self else { return }
            self.issues = state.issues
            self.errorMessage = state.error
            self.lastUpdated = state.lastFetchTime
            self.isLoading = false
            // Pre-select the first row once the list is populated so
            // keyboard navigation works immediately, even if the user
            // pressed arrow keys while the fetch was in flight.
            if self.selectedIssueKey == nil, let first = self.filteredIssues.first {
                self.selectedIssueKey = first.key
            }
        }
    }

    func openIssue(_ key: String) {
        onOpenIssue(key)
    }

    func navigateDown() {
        let list = filteredIssues
        guard !list.isEmpty else { return }
        if let key = selectedIssueKey, let idx = list.firstIndex(where: { $0.key == key }) {
            selectedIssueKey = list[min(list.count - 1, idx + 1)].key
        } else {
            selectedIssueKey = list.first?.key
        }
    }

    func navigateUp() {
        let list = filteredIssues
        guard !list.isEmpty else { return }
        if let key = selectedIssueKey, let idx = list.firstIndex(where: { $0.key == key }) {
            selectedIssueKey = list[max(0, idx - 1)].key
        } else {
            selectedIssueKey = list.last?.key
        }
    }

    func openSelected() {
        if let key = selectedIssueKey { openIssue(key) }
    }
}

struct JiraMainView: View {
    @ObservedObject var vm: JiraMainViewModel
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tabBar

            if vm.selectedTab == .custom {
                customJQLBar
            }

            Divider()

            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .onAppear {
            if !vm.canConnect { showSettings = true }
            vm.loadIfNeeded()
        }
    }

    // MARK: Header (inline toolbar items live inside tabBar)

    @ViewBuilder
    private var toolbarButtons: some View {
        if let lastUpdated = vm.lastUpdated {
            Text("Updated \(relativeTime(lastUpdated))")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Reserve a stable slot so the surrounding tab pills don't
                // reflow as the relative time string grows ("0 sec" → "5 min").
                .frame(width: 110, alignment: .trailing)
        }

        Button {
            vm.refresh(force: true)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(vm.canConnect ? 1.0 : 0.35))
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(vm.isLoading || !vm.canConnect)
        .help("Refresh (\u{2318}R)")

        Button {
            showSettings.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",", modifiers: [.command])
        .help("Settings (\u{2318},)")
        .popover(isPresented: $showSettings, arrowEdge: .top) {
            settingsPopover
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(JiraTab.allCases) { tab in
                let isSelected = vm.selectedTab == tab
                Button {
                    vm.selectTab(tab)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        // Always render at semibold to keep width stable across
                        // selection changes; use opacity to dim unselected tabs
                        // so the visual emphasis still tracks selection without
                        // causing layout reflow / flicker.
                        Text(tab.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isSelected ? tab.tint.opacity(0.22) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isSelected ? tab.tint : Color.clear, lineWidth: 1)
                    )
                    .foregroundColor(isSelected ? tab.tint : .primary)
                    .opacity(isSelected ? 1.0 : 0.85)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 12)
            toolbarButtons
        }
        .animation(nil, value: vm.selectedTab)
    }

    // MARK: Custom JQL

    private var customJQLBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundColor(.secondary)
            TextField("Enter custom JQL, e.g. project = PS AND status = \"In Progress\"", text: $vm.customJQL, onCommit: {
                vm.runCustomQuery()
            })
            .textFieldStyle(.roundedBorder)
            Button("Run") { vm.runCustomQuery() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(vm.customJQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !vm.canConnect)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var contentArea: some View {
        if !vm.canConnect {
            VStack(alignment: .leading, spacing: 10) {
                Text("Configure Base URL and PAT token to load your assigned issues.")
                    .foregroundColor(.secondary)
                Button("Open Settings") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        } else if vm.isLoading && vm.issues.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading issues...")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = vm.errorMessage, vm.issues.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Failed to load issues", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Retry") { vm.refresh(force: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isLoading)
            }
        } else if vm.issues.isEmpty {
            Text("No issues found.")
                .foregroundColor(.secondary)
        } else {
            VStack(spacing: 0) {
                JiraSectionHeader(
                    title: vm.filterQuery.isEmpty ? vm.selectedTab.title : "Search Results",
                    icon: vm.filterQuery.isEmpty ? vm.selectedTab.icon : "magnifyingglass",
                    count: vm.filteredIssues.count,
                    color: vm.selectedTab.tint
                )
                if vm.filteredIssues.isEmpty {
                    Text("No results for \"\(vm.filterQuery)\"")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(vm.filteredIssues, id: \.key) { issue in
                                    JiraIssueRow(
                                        issue: issue,
                                        accent: vm.selectedTab.tint,
                                        isSelected: vm.selectedIssueKey == issue.key
                                    ) {
                                        vm.selectedIssueKey = issue.key
                                        vm.openIssue(issue.key)
                                    }
                                    .id(issue.key)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: vm.selectedIssueKey) { newKey in
                            if let key = newKey {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    proxy.scrollTo(key, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    // MARK: Settings Popover

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jira Connection")
                .font(.headline)

            LabeledConfigField(label: "Base URL", icon: "globe") {
                TextField("https://jira.corp.YOUR_ORG.com", text: $vm.url)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledConfigField(label: "PAT Token", icon: "key.fill") {
                SecureField("Paste your Jira PAT token", text: $vm.token)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { showSettings = false }
                Button("Save") {
                    vm.saveConfiguration()
                    showSettings = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!vm.canConnect)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct JiraIssueRow: View {
    let issue: JiraIssue
    let accent: Color
    var isSelected: Bool = false
    let onOpen: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: typeIcon(issue.issueType))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(typeColor(issue.issueType))
                    .frame(width: 22, alignment: .center)

                Text(issue.key)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(accent.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.summary)
                        .font(.system(size: 13))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        StatusBadge(text: issue.status, category: issue.statusCategory)
                        PriorityBadge(priority: issue.priority)
                        Text(issue.issueType)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundColor((isSelected || hovered) ? accent : Color.secondary.opacity(0.35))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? accent.opacity(0.22) : (hovered ? accent.opacity(0.12) : Color.clear))
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private func typeIcon(_ type: String) -> String {
        switch type.lowercased() {
        case "bug":                        return "ladybug.fill"
        case "story", "user story":        return "book.fill"
        case "task":                       return "checkmark.circle.fill"
        case "epic":                       return "bolt.fill"
        case "sub-task", "subtask":        return "arrow.turn.down.right"
        case "improvement", "new feature": return "star.fill"
        default:                           return "circle.fill"
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type.lowercased() {
        case "bug":                        return .red
        case "story", "user story":        return .green
        case "task":                       return .blue
        case "epic":                       return .purple
        case "sub-task", "subtask":        return .teal
        case "improvement", "new feature": return .yellow
        default:                           return .gray
        }
    }
}

struct StatusBadge: View {
    let text: String
    let category: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color)
            .cornerRadius(3)
    }

    private var color: Color {
        switch category.lowercased() {
        case "in progress", "indeterminate": return .blue
        case "done":                         return .green
        case "new", "to do":                 return .gray
        default:                             return Color.secondary.opacity(0.7)
        }
    }
}

struct PriorityBadge: View {
    let priority: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(priority)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.15))
        )
    }

    private var color: Color {
        switch priority.lowercased() {
        case "blocker":  return .red
        case "critical": return .orange
        case "major":    return .yellow
        case "minor":    return .green
        case "trivial":  return .gray
        default:         return .secondary
        }
    }

    private var icon: String {
        switch priority.lowercased() {
        case "blocker":  return "exclamationmark.octagon.fill"
        case "critical": return "arrow.up.circle.fill"
        case "major":    return "arrow.up"
        case "minor":    return "arrow.down"
        case "trivial":  return "minus"
        default:         return "circle"
        }
    }
}

struct JiraSectionHeader: View {
    let title: String
    let icon: String
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(0.4)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(minWidth: 20, minHeight: 16)
                    .padding(.horizontal, 4)
                    .background(color)
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06))
        .clipShape(
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
        )
    }
}

// MARK: - Config Surface

final class JiraConfigSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?

    private let initialURL:   String
    private let initialToken: String
    private let initialJQL:   String
    private let onSave:       (String, String, String) -> Void
    private var vm: JiraConfigViewModel?

    init(initialURL: String, initialToken: String, initialJQL: String,
         onSave: @escaping (String, String, String) -> Void) {
        self.initialURL   = initialURL
        self.initialToken = initialToken
        self.initialJQL   = initialJQL
        self.onSave       = onSave
    }

    func makeLauncherSurfaceView() -> NSView {
        let vm = JiraConfigViewModel(url: initialURL, token: initialToken, jql: initialJQL)
        self.vm = vm
        let view = JiraConfigView(
            vm: vm,
            onSave: { [weak self] in
                guard let self, let vm = self.vm else { return }
                self.onSave(vm.url, vm.token, vm.jql)
                self.delegate?.requestLauncherSurfaceGoBack()
            },
            onCancel: { [weak self] in
                self?.delegate?.requestLauncherSurfaceGoBack()
            }
        )
        return NSHostingView(rootView: view)
    }

    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 560, height: 360) }
    func launcherSurfaceKeepsLauncherPinned()  -> Bool   { false }
    func launcherSurfacePlaceholderText()      -> String? { "Jira Configuration" }
    func launcherSurfaceFooterHint()           -> String? { "Return Save  ·  Esc Cancel" }

    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool {
        true
    }
}

// MARK: - Config ViewModel

final class JiraConfigViewModel: ObservableObject {
    @Published var url:   String
    @Published var token: String
    @Published var jql:   String

    init(url: String, token: String, jql: String) {
        self.url   = url
        self.token = token
        self.jql   = jql
    }
}

// MARK: - Config SwiftUI View

struct JiraConfigView: View {
    @ObservedObject var vm: JiraConfigViewModel
    let onSave:   () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: ConfigField?
    enum ConfigField { case url, token, jql }

    var canSave: Bool { !vm.url.isEmpty && !vm.token.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jira Connection")
                        .font(.title3.weight(.semibold))
                    Text("Configure your Jira Personal Access Token (PAT)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                LabeledConfigField(label: "Base URL", icon: "globe") {
                    TextField("https://jira.corp.YOUR_ORG.com", text: $vm.url)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .url)
                }

                LabeledConfigField(label: "API Token (PAT)", icon: "key.fill") {
                    SecureField("Paste your Personal Access Token here", text: $vm.token)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .token)
                }

                LabeledConfigField(label: "JQL Query", icon: "line.3.horizontal.decrease.circle") {
                    TextField("assignee = currentUser() ORDER BY updated DESC", text: $vm.jql)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .jql)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save & Connect") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .onAppear { focused = vm.token.isEmpty ? .token : .url }
    }
}

struct LabeledConfigField<Content: View>: View {
    let label:   String
    let icon:    String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
            content()
        }
    }
}
