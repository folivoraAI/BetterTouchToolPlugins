// BTT-Plugin-Name: Quick Links
// BTT-Plugin-Identifier: com.folivora.launcher.quicklinks.example
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: link.badge.plus
// BTT-Principal-Class: QuickLinkLauncherPlugin
// BTT-AI-Managed: true

import AppKit
import Foundation
import SwiftUI

final class QuickLinkLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    static let pluginIdentifier = "com.folivora.launcher.quicklinks.example"

    private enum IDs {
        static let createItem = "create-quick-link"
        static let manageItem = "manage-quick-links"
        static let editorSurface = "quick-link-editor"
        static let manageChildren = "manage-children"
    }

    private enum Actions {
        static let open = "open"
        static let edit = "edit"
        static let copyURL = "copy-url"
        static let duplicate = "duplicate"
        static let delete = "delete"
    }

    static func launcherPluginName() -> String {
        "Quick Links"
    }

    static func launcherPluginDescription() -> String {
        "Create saved launcher items that open reusable URL templates."
    }

    static func launcherPluginIcon() -> String {
        "link.badge.plus"
    }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        var results: [BTTLauncherPluginResult] = []

        let create = BTTLauncherPluginResult()
        create.itemIdentifier = IDs.createItem
        create.title = "Create Quick Link"
        create.subtitle = "Save a reusable URL template as a launcher item."
        create.systemImageName = "link.badge.plus"
        create.keywords = ["quicklink", "quick link", "url", "bookmark", "browser", "web", "create", "new"]
        create.trailingHint = "Create"
        create.surfaceIdentifier = IDs.editorSurface
        create.searchMatchPriority = NSNumber(value: 50)
        results.append(create)

        // Only show "Manage" when there is at least one saved quick link.
        let savedCount = delegate?
            .launcherPluginInstances(forPluginIdentifier: Self.pluginIdentifier,
                                     launcherID: context.launcherID)
            .count ?? 0
        if savedCount > 0 {
            let manage = BTTLauncherPluginResult()
            manage.itemIdentifier = IDs.manageItem
            manage.title = "Manage Quick Links"
            manage.subtitle = "Browse saved quick links (\(savedCount))."
            manage.systemImageName = "slider.horizontal.3"
            manage.keywords = ["quicklink", "quick link", "manage", "edit", "delete", "list"]
            manage.trailingHint = "Manage"
            // Use launcher children instead of a custom surface — this gives
            // each row BTT's native ⌘P action popover for free.
            manage.dynamicChildrenIdentifier = IDs.manageChildren
            manage.searchMatchPriority = NSNumber(value: 50)
            results.append(manage)
        }

        return results
    }

    func launcherResult(
        for instance: BTTLauncherPluginInstance,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginResult? {
        let configuration = QuickLinkConfiguration(instance: instance)
        guard !configuration.urlTemplate.isEmpty else { return nil }

        let instanceID = instance.instanceIdentifier ?? UUID().uuidString
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = QuickLinkConfiguration.itemIdentifier(for: instanceID)
        result.title = configuration.name
        result.subtitle = previewSubtitle(for: configuration, context: context)
        result.systemImageName = configuration.systemImageName
        result.keywords = Array(Set(configuration.searchTerms + [
            "quicklink",
            "quick link",
            "link",
            "url",
            configuration.browserName ?? ""
        ] + (instance.keywords ?? []))).filter { !$0.isEmpty }
        result.trailingHint = "Open"
        result.primaryActionIdentifier = Actions.open
        result.surfaceIdentifier = IDs.editorSurface
        result.launcherDisplayMode = NSNumber(value: configuration.displayMode)
        result.commands = [
            command(
                id: Actions.edit,
                title: "Edit Quick Link",
                subtitle: "Change the name, URL template, browser, icon, or display mode.",
                systemImageName: "pencil",
                character: "e",
                modifiers: [.command],
                closesLauncher: false,
                surfaceIdentifier: IDs.editorSurface
            ),
            command(
                id: Actions.copyURL,
                title: "Copy Resolved URL",
                subtitle: "Copy this quick link after placeholders are filled.",
                systemImageName: "doc.on.doc",
                character: "c",
                modifiers: [.command],
                closesLauncher: false
            ),
            command(
                id: Actions.duplicate,
                title: "Duplicate Quick Link",
                subtitle: "Create another saved item using these settings.",
                systemImageName: "plus.square.on.square",
                character: "d",
                modifiers: [.command],
                closesLauncher: false
            ),
            command(
                id: Actions.delete,
                title: "Delete Quick Link",
                subtitle: "Remove this saved quick link.",
                systemImageName: "trash",
                character: "\u{8}",
                modifiers: [],
                closesLauncher: false,
                destructive: true
            )
        ]
        return result
    }

    func launcherSurface(
        forItemIdentifier itemIdentifier: String,
        surfaceIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard surfaceIdentifier == IDs.editorSurface else { return nil }
        guard itemIdentifier == IDs.createItem || context.launcherPluginInstance != nil else {
            return nil
        }

        return QuickLinkEditorSurface(
            context: context,
            existingInstance: context.launcherPluginInstance
        )
    }

    func launcherChildren(
        forItemIdentifier itemIdentifier: String,
        childrenIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> [BTTLauncherPluginResult]? {
        guard itemIdentifier == IDs.manageItem || childrenIdentifier == IDs.manageChildren else {
            return nil
        }
        let instances = delegate?
            .launcherPluginInstances(forPluginIdentifier: Self.pluginIdentifier,
                                     launcherID: context.launcherID) ?? []
        // Each saved instance already builds a launcher result with its
        // Edit / Copy URL / Duplicate / Delete commands attached via
        // `launcherResult(for instance:context:)`.
        return instances.compactMap { launcherResult(for: $0, context: context) }
    }

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {
        let action = actionIdentifier ?? Actions.open
        guard let instance = context.launcherPluginInstance else {
            return actionResult(success: false, message: "No quick link was selected.", closeLauncher: false)
        }

        let configuration = QuickLinkConfiguration(instance: instance)
        guard let resolvedURL = resolvedURL(for: configuration, context: context) else {
            return actionResult(success: false, message: "Could not build a valid URL.", closeLauncher: false)
        }

        switch action {
        case Actions.open:
            open(resolvedURL, browserBundleIdentifier: configuration.browserBundleIdentifier)
            return actionResult(success: true, message: "Opened \(configuration.name).", closeLauncher: true)

        case Actions.copyURL:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(resolvedURL.absoluteString, forType: .string)
            return actionResult(success: true, message: "Copied URL.", closeLauncher: false)

        case Actions.duplicate:
            let duplicate = configuration.instance(existingIdentifier: nil)
            duplicate.title = "\(configuration.name) Copy"
            _ = delegate?.saveLauncherPluginInstance(
                duplicate,
                pluginIdentifier: Self.pluginIdentifier,
                launcherID: context.launcherID
            )
            return actionResult(success: true, message: "Duplicated quick link.", closeLauncher: false)

        case Actions.delete:
            guard let instanceIdentifier = instance.instanceIdentifier else {
                return actionResult(success: false, message: "Could not delete this quick link.", closeLauncher: false)
            }
            delegate?.deleteLauncherPluginInstance(
                instanceIdentifier,
                pluginIdentifier: Self.pluginIdentifier,
                launcherID: context.launcherID
            )
            return actionResult(success: true, message: "Deleted quick link.", closeLauncher: false)

        default:
            return nil
        }
    }

    private func command(
        id: String,
        title: String,
        subtitle: String,
        systemImageName: String,
        character: String,
        modifiers: NSEvent.ModifierFlags,
        closesLauncher: Bool,
        surfaceIdentifier: String? = nil,
        destructive: Bool = false
    ) -> BTTLauncherPluginCommand {
        let shortcut = BTTLauncherPluginShortcut()
        shortcut.character = character
        shortcut.modifierFlags = modifiers
        shortcut.displayKeys = displayKeys(for: character, modifiers: modifiers)

        let command = BTTLauncherPluginCommand()
        command.commandIdentifier = id
        command.title = title
        command.subtitle = subtitle
        command.systemImageName = systemImageName
        command.shortcut = shortcut
        command.surfaceIdentifier = surfaceIdentifier
        command.closesLauncherOnSuccess = closesLauncher
        command.destructive = destructive
        return command
    }

    private func displayKeys(for character: String, modifiers: NSEvent.ModifierFlags) -> [String] {
        var keys: [String] = []
        if modifiers.contains(.command) { keys.append("Cmd") }
        if modifiers.contains(.option) { keys.append("Option") }
        if modifiers.contains(.control) { keys.append("Control") }
        if modifiers.contains(.shift) { keys.append("Shift") }
        keys.append(character == "\u{8}" ? "Delete" : character.uppercased())
        return keys
    }

    private func resolvedURL(
        for configuration: QuickLinkConfiguration,
        context: BTTLauncherPluginContext
    ) -> URL? {
        let argument = argumentText(for: configuration, context: context, useClipboardFallback: true)
        guard let urlString = resolvedURLString(
            for: configuration,
            context: context,
            argument: argument,
            includeEmptyArgument: true
        ) else {
            return nil
        }
        // Filesystem path — build a file URL directly so it opens in the
        // correct default app (Preview, Finder, …) rather than the browser.
        if isFilesystemPath(urlString) {
            let expanded = (urlString as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        return URL(string: urlString)
    }

    private func previewSubtitle(
        for configuration: QuickLinkConfiguration,
        context: BTTLauncherPluginContext
    ) -> String {
        let argument = argumentText(for: configuration, context: context, useClipboardFallback: false)
        guard !argument.isEmpty,
              let resolved = resolvedURLString(
                  for: configuration,
                  context: context,
                  argument: argument,
                  includeEmptyArgument: false
              ) else {
            return configuration.urlTemplate
        }
        return resolved
    }

    private func resolvedURLString(
        for configuration: QuickLinkConfiguration,
        context: BTTLauncherPluginContext,
        argument: String,
        includeEmptyArgument: Bool
    ) -> String? {
        let extraVariables = placeholderVariables(
            context: context,
            argument: argument,
            includeEmptyArgument: includeEmptyArgument
        )
        let templateWithPluginVariables = locallyReplaceVariables(
            in: configuration.urlTemplate,
            extraVariables: extraVariables
        )
        let resolvedTemplate = hostReplaceVariables(
            in: templateWithPluginVariables,
            extraVariables: nil
        ) ?? templateWithPluginVariables

        let trimmedURLString = resolvedTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURLString.isEmpty else { return nil }

        if URLComponents(string: trimmedURLString)?.scheme != nil {
            return trimmedURLString
        }
        // Don't slap https:// onto a filesystem path — leave it as-is so the
        // caller can build a file URL.
        if isFilesystemPath(trimmedURLString) {
            return trimmedURLString
        }
        return "https://\(trimmedURLString)"
    }

    /// True for absolute (`/...`), home-relative (`~/...`), or current-directory
    /// (`./...`) filesystem paths.
    private func isFilesystemPath(_ s: String) -> Bool {
        s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./")
    }

    private func hostReplaceVariables(
        in template: String,
        extraVariables: [String: Any]?
    ) -> String? {
        guard let delegateObject = delegate as? NSObject else { return nil }
        let selector = NSSelectorFromString("replaceVariablesInString:extraVariables:")
        guard delegateObject.responds(to: selector) else { return nil }
        return delegateObject
            .perform(selector, with: template, with: extraVariables)
            .takeUnretainedValue() as? String
    }

    private func argumentText(
        for configuration: QuickLinkConfiguration,
        context: BTTLauncherPluginContext,
        useClipboardFallback: Bool
    ) -> String {
        if let query = normalized(context.query) {
            if let remainder = leadingPromptRemainder(query: query, terms: configuration.searchTerms) {
                return remainder
            }
            return query
        }
        guard useClipboardFallback else { return "" }
        return normalized(NSPasteboard.general.string(forType: .string)) ?? ""
    }

    private func leadingPromptRemainder(query: String, terms: [String]) -> String? {
        let lowercasedQuery = query.lowercased()
        for term in terms {
            let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedTerm.isEmpty,
                  lowercasedQuery.count > normalizedTerm.count,
                  lowercasedQuery.hasPrefix(normalizedTerm) else {
                continue
            }
            let suffixIndex = lowercasedQuery.index(lowercasedQuery.startIndex, offsetBy: normalizedTerm.count)
            guard lowercasedQuery[suffixIndex].isWhitespace else { continue }
            return String(query[suffixIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func placeholderVariables(
        context: BTTLauncherPluginContext,
        argument: String,
        includeEmptyArgument: Bool
    ) -> [String: Any] {
        let query = context.query ?? ""
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let finderURL = context.finderURLs?.first

        var variables: [String: Any] = [
            "clipboard": percentEncoded(clipboard),
            "rawClipboard": clipboard,
            "finderPath": percentEncoded(finderURL?.path ?? ""),
            "rawFinderPath": finderURL?.path ?? "",
            "finderURL": percentEncoded(finderURL?.absoluteString ?? ""),
            "rawFinderURL": finderURL?.absoluteString ?? ""
        ]

        if includeEmptyArgument || !argument.isEmpty {
            variables["argument"] = percentEncoded(argument)
            variables["rawArgument"] = argument
        }
        if !query.isEmpty {
            variables["query"] = percentEncoded(query)
            variables["rawQuery"] = query
        }

        return variables
    }

    private func locallyReplaceVariables(
        in template: String,
        extraVariables: [String: Any]
    ) -> String {
        var resolved = template
        for (key, value) in extraVariables {
            let stringValue = "\(value)"
            resolved = resolved.replacingOccurrences(of: "{{\(key)}}", with: stringValue)
            resolved = resolved.replacingOccurrences(of: "{\(key)}", with: stringValue)
        }
        return resolved
    }

    private func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func open(_ url: URL, browserBundleIdentifier: String?) {
        guard let browserBundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleIdentifier) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }

    private func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func actionResult(
        success: Bool,
        message: String?,
        closeLauncher: Bool
    ) -> BTTLauncherPluginActionResult {
        let result = BTTLauncherPluginActionResult()
        result.success = success
        result.message = message
        result.closeLauncher = closeLauncher
        return result
    }
}

private enum QuickLinkDisplayMode: Int, CaseIterable, Identifiable {
    case launcherResult = 1
    case alwaysVisible = 3
    case keywordOnly = 4
    case promptMatchesOnly = 5
    case promptMatchesOrFallback = 6

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .launcherResult:
            return "Show & Filter"
        case .alwaysVisible:
            return "Always Show"
        case .keywordOnly:
            return "Keyword Match"
        case .promptMatchesOnly:
            return "Prompt Match"
        case .promptMatchesOrFallback:
            return "Fallback"
        }
    }
}

private struct QuickLinkConfiguration {
    static let nameKey = "name"
    static let urlTemplateKey = "urlTemplate"
    static let browserBundleIdentifierKey = "browserBundleIdentifier"
    static let browserNameKey = "browserName"
    static let systemImageNameKey = "systemImageName"
    static let displayModeKey = "displayMode"

    var name: String
    var urlTemplate: String
    var browserBundleIdentifier: String?
    var browserName: String?
    var systemImageName: String
    var displayMode: Int

    init(
        name: String = "",
        urlTemplate: String = "https://google.com/search?q={argument}",
        browserBundleIdentifier: String? = nil,
        browserName: String? = nil,
        systemImageName: String = "link",
        displayMode: Int = QuickLinkDisplayMode.keywordOnly.rawValue
    ) {
        self.name = name
        self.urlTemplate = urlTemplate
        self.browserBundleIdentifier = Self.normalized(browserBundleIdentifier)
        self.browserName = Self.normalized(browserName)
        self.systemImageName = Self.normalized(systemImageName) ?? "link"
        self.displayMode = QuickLinkDisplayMode(rawValue: displayMode)?.rawValue ?? QuickLinkDisplayMode.keywordOnly.rawValue
    }

    init(instance: BTTLauncherPluginInstance) {
        let configuration = instance.configuration ?? [:]
        self.init(
            name: Self.normalized(configuration[Self.nameKey] as? String)
                ?? Self.normalized(instance.title)
                ?? "Quick Link",
            urlTemplate: Self.normalized(configuration[Self.urlTemplateKey] as? String)
                ?? Self.normalized(instance.subtitle)
                ?? "",
            browserBundleIdentifier: Self.normalized(configuration[Self.browserBundleIdentifierKey] as? String),
            browserName: Self.normalized(configuration[Self.browserNameKey] as? String),
            systemImageName: Self.normalized(configuration[Self.systemImageNameKey] as? String)
                ?? Self.normalized(instance.systemImageName)
                ?? "link",
            displayMode: (configuration[Self.displayModeKey] as? NSNumber)?.intValue
                ?? instance.launcherDisplayMode?.intValue
                ?? QuickLinkDisplayMode.keywordOnly.rawValue
        )
    }

    var searchTerms: [String] {
        var terms = [name, urlTemplate]
        terms.append(contentsOf: name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func itemIdentifier(for instanceIdentifier: String) -> String {
        "instance:\(instanceIdentifier)"
    }

    func instance(existingIdentifier: String?) -> BTTLauncherPluginInstance {
        let instance = BTTLauncherPluginInstance()
        instance.instanceIdentifier = existingIdentifier
        instance.title = name
        instance.subtitle = urlTemplate
        instance.systemImageName = systemImageName
        instance.primaryActionIdentifier = "open"
        instance.surfaceIdentifier = "quick-link-editor"
        instance.launcherDisplayMode = NSNumber(value: displayMode)
        instance.keywords = (searchTerms + [browserName ?? ""]).filter { !$0.isEmpty }
        instance.configuration = [
            Self.nameKey: name,
            Self.urlTemplateKey: urlTemplate,
            Self.browserBundleIdentifierKey: browserBundleIdentifier ?? "",
            Self.browserNameKey: browserName ?? "",
            Self.systemImageNameKey: systemImageName,
            Self.displayModeKey: NSNumber(value: displayMode)
        ]
        return instance
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private enum QuickLinkEditorSurfaceSize {
    static let widthKey  = "com.folivora.launcher.quicklinks.editorWidth"
    static let heightKey = "com.folivora.launcher.quicklinks.editorHeight"

    static let defaultSize = CGSize(width: 760, height: 560)
    static let minWidth:  CGFloat = 620
    static let minHeight: CGFloat = 420
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

/// `NSHostingView` subclass that reports host-window size changes so the
/// surface can persist the user's resized dimensions.
private final class QuickLinkResizableHostingView<Root: View>: NSHostingView<Root> {
    var onSizeChanged: ((CGSize) -> Void)?
    private var resizeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            removeResizeObserver()
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                guard let self, let window else { return }
                self.onSizeChanged?(window.contentLayoutRect.size)
            }
        } else {
            removeResizeObserver()
        }
    }

    private func removeResizeObserver() {
        if let token = resizeObserver { NotificationCenter.default.removeObserver(token) }
        resizeObserver = nil
    }

    deinit { removeResizeObserver() }
}

private final class QuickLinkEditorSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?

    private let context: BTTLauncherPluginContext
    private let existingInstance: BTTLauncherPluginInstance?
    private let browserChoices = QuickLinkBrowserChoice.installedChoices()
    private var statusText: String?

    init(
        context: BTTLauncherPluginContext,
        existingInstance: BTTLauncherPluginInstance?
    ) {
        self.context = context
        self.existingInstance = existingInstance
        super.init()
    }

    func makeLauncherSurfaceView() -> NSView {
        let draft = QuickLinkEditorDraft(
            configuration: existingInstance.map(QuickLinkConfiguration.init(instance:))
                ?? QuickLinkConfiguration(urlTemplate: initialURLTemplate())
        )
        let host = QuickLinkResizableHostingView(rootView: QuickLinkEditorView(
            isEditing: existingInstance != nil,
            initialDraft: draft,
            browserChoices: browserChoices,
            onSave: { [weak self] draft in
                self?.save(draft)
            },
            onDelete: { [weak self] in
                self?.delete()
            },
            onCancel: { [weak self] in
                self?.delegate?.requestLauncherSurfaceGoBack()
            }
        ))
        host.onSizeChanged = { size in QuickLinkEditorSurfaceSize.save(size) }
        return host
    }

    func launcherSurfacePreferredContentSize() -> CGSize {
        QuickLinkEditorSurfaceSize.load()
    }

    func launcherSurfaceMinimumContentSize() -> CGSize {
        CGSize(width: QuickLinkEditorSurfaceSize.minWidth,
               height: QuickLinkEditorSurfaceSize.minHeight)
    }

    func launcherSurfaceKeepsLauncherPinned() -> Bool {
        false
    }

    func launcherSurfacePlaceholderText() -> String? {
        existingInstance == nil ? "Create Quick Link" : "Edit Quick Link"
    }

    func launcherSurfaceFooterHint() -> String? { nil }

    func launcherSurfaceStatusText() -> String? {
        statusText
    }

    private func initialURLTemplate() -> String {
        let query = context.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty {
            if URLComponents(string: query)?.scheme != nil || query.contains(".") {
                return query
            }
        }
        // Fall back to the clipboard if it currently holds a URL or a path —
        // saves the user from manually pasting it into the link field.
        if let clip = clipboardURLOrPath() {
            return clip
        }
        return "https://google.com/search?q={argument}"
    }

    /// Returns the pasteboard string only if it looks like a URL (any scheme),
    /// a domain-style host, or an absolute / `~`-rooted filesystem path.
    /// Anything else (plain prose, code snippets, etc.) is ignored.
    private func clipboardURLOrPath() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("\n"), s.count <= 2048 else { return nil }

        // Explicit URL with a scheme (https://, file://, ssh://, mailto:, …).
        if let comps = URLComponents(string: s), let scheme = comps.scheme, !scheme.isEmpty {
            return s
        }
        // Absolute / home-relative filesystem path.
        if s.hasPrefix("/") || s.hasPrefix("~/") {
            return s
        }
        // Bare domain like `example.com` or `example.com/path` — promote to https.
        let firstToken = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        if firstToken.contains("."),
           !firstToken.contains(" "),
           firstToken.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$"#,
                            options: .regularExpression) != nil {
            return "https://\(s)"
        }
        return nil
    }

    private func save(_ draft: QuickLinkEditorDraft) {
        guard let configuration = draft.configuration(browserChoices: browserChoices) else {
            statusText = "Enter a name and link first."
            delegate?.requestLauncherSurfaceUpdate()
            return
        }

        let instance = configuration.instance(existingIdentifier: existingInstance?.instanceIdentifier)
        _ = delegate?.saveLauncherPluginInstance(
            instance,
            pluginIdentifier: QuickLinkLauncherPlugin.pluginIdentifier,
            launcherID: context.launcherID
        )
        statusText = existingInstance == nil ? "Quick link saved." : "Quick link updated."
        delegate?.requestLauncherSurfaceGoBack()
    }

    private func delete() {
        guard let instanceIdentifier = existingInstance?.instanceIdentifier else { return }
        delegate?.deleteLauncherPluginInstance(
            instanceIdentifier,
            pluginIdentifier: QuickLinkLauncherPlugin.pluginIdentifier,
            launcherID: context.launcherID
        )
        delegate?.requestLauncherSurfaceGoBack()
    }
}

private struct QuickLinkBrowserChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let bundleIdentifier: String?

    /// Coarse classification of an "Open With" target — web vs. file-system path,
    /// and the type of file when it is a path. Drives which apps appear in the
    /// editor's picker.
    enum Kind: String {
        case browser    // any web URL  → browsers (Dia first)
        case image      // image file   → Preview, Photoshop, Pixelmator, Sketch
        case textCode   // text / code  → Cursor, VS Code, Sublime, Xcode, …
        case folder     // directory    → Finder, Cursor, VS Code, Terminal, iTerm
        case file       // generic file → Default app, Finder
    }

    /// Returns the relevant subset of installed apps for the given link kind,
    /// always starting with the system "Default" entry.
    static func choices(for kind: Kind) -> [QuickLinkBrowserChoice] {
        var choices: [QuickLinkBrowserChoice] = [
            QuickLinkBrowserChoice(id: "default", title: defaultTitle(for: kind), bundleIdentifier: nil)
        ]
        let bundles: [String]
        switch kind {
        case .browser:
            // System default is already the first entry; list the rest in a
            // neutral, popularity-ish order without elevating any one browser.
            bundles = [
                "com.apple.Safari",
                "com.google.Chrome",
                "company.thebrowser.Browser",
                "company.thebrowser.dia",
                "company.thebrowser.Dia",
                "org.mozilla.firefox",
                "com.brave.Browser",
                "com.microsoft.edgemac",
                "com.google.Chrome.canary",
            ]
        case .image:
            bundles = [
                "com.apple.Preview",
                "com.adobe.Photoshop",
                "com.pixelmatorteam.pixelmator.x",
                "com.bohemiancoding.sketch3",
                "com.figma.Desktop",
                "com.apple.Photos",
            ]
        case .textCode:
            bundles = [
                "com.todesktop.230313mzl4w4u92",     // Cursor
                "com.microsoft.VSCode",
                "com.microsoft.VSCodeInsiders",
                "com.sublimetext.4",
                "com.sublimetext.3",
                "com.apple.dt.Xcode",
                "com.panic.Nova",
                "com.barebones.bbedit",
                "com.apple.TextEdit",
            ]
        case .folder:
            bundles = [
                "com.apple.finder",
                "com.todesktop.230313mzl4w4u92",     // Cursor
                "com.microsoft.VSCode",
                "com.googlecode.iterm2",
                "com.apple.Terminal",
                "co.zeit.hyper",
            ]
        case .file:
            bundles = ["com.apple.finder"]
        }

        var seen = Set<String>()
        for bundleIdentifier in bundles where !seen.contains(bundleIdentifier) {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { continue }
            seen.insert(bundleIdentifier)
            choices.append(QuickLinkBrowserChoice(
                id: bundleIdentifier,
                title: displayName(for: appURL),
                bundleIdentifier: bundleIdentifier
            ))
        }
        return choices
    }

    /// Union of every kind's choices — used by the surface for save-time lookup
    /// so a user-selected app can always be resolved by ID even if the link
    /// kind changes mid-edit.
    static func installedChoices() -> [QuickLinkBrowserChoice] {
        var seen = Set<String>()
        var combined: [QuickLinkBrowserChoice] = []
        for kind: Kind in [.browser, .image, .textCode, .folder, .file] {
            for choice in choices(for: kind) where !seen.contains(choice.id) {
                seen.insert(choice.id)
                combined.append(choice)
            }
        }
        return combined
    }

    /// Detect the link kind from a URL template / path string.
    static func kind(forURLTemplate raw: String) -> Kind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .browser }

        // Strip BTT placeholders so things like `/Users/me/{argument}.png`
        // still classify by their suffix.
        let bare = s.replacingOccurrences(of: #"\{[^}]+\}"#, with: "",
                                          options: .regularExpression)

        // Web-ish URL → browsers.
        if let scheme = URLComponents(string: s)?.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return .browser }
            if scheme == "file" {
                let path = URL(string: s)?.path ?? ""
                return classifyPath(path)
            }
            // Other schemes (mailto:, ssh:, slack:, raycast:, …) → "default app".
            return .file
        }
        // Bare domain → web.
        let firstToken = bare.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? bare
        if firstToken.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$"#,
                            options: .regularExpression) != nil {
            return .browser
        }
        // Filesystem path.
        if bare.hasPrefix("/") || bare.hasPrefix("~/") || bare.hasPrefix("./") {
            return classifyPath(bare)
        }
        return .browser
    }

    private static func classifyPath(_ path: String) -> Kind {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { return .folder }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            // No extension: likely a directory.
            return .folder
        }
        let imageExts: Set<String> = [
            "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif",
            "bmp", "svg", "ico", "raw", "cr2", "nef", "arw", "dng", "psd"
        ]
        let textExts: Set<String> = [
            "txt", "md", "markdown", "rst",
            "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp",
            "js", "jsx", "ts", "tsx", "json", "yaml", "yml", "toml",
            "html", "htm", "css", "scss", "less",
            "py", "rb", "go", "rs", "java", "kt", "php", "lua", "pl",
            "sh", "bash", "zsh", "fish", "ps1",
            "xml", "csv", "tsv", "sql",
            "log", "ini", "conf", "env"
        ]
        if imageExts.contains(ext)  { return .image }
        if textExts.contains(ext)   { return .textCode }
        return .file
    }

    private static func defaultTitle(for kind: Kind) -> String {
        let probeURL: URL?
        switch kind {
        case .browser: probeURL = URL(string: "https://example.com")
        case .image:   probeURL = URL(string: "file:///System/Library/Desktop%20Pictures/Solid%20Colors/Black.png")
        case .folder:
            // Folders open in Finder by default; probing a directory URL
            // (not a text file) avoids picking up TextEdit by mistake.
            probeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        case .textCode, .file:
            probeURL = URL(string: "file:///etc/hosts")
        }
        if let url = probeURL, let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            return "\(displayName(for: appURL)) (Default)"
        }
        return "Default"
    }

    private static func displayName(for appURL: URL) -> String {
        let bundle = Bundle(url: appURL)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
    }
}

private struct QuickLinkEditorDraft {
    var name: String
    var urlTemplate: String
    var browserChoiceID: String
    var systemImageName: String
    var displayMode: Int

    init(configuration: QuickLinkConfiguration) {
        name = configuration.name
        urlTemplate = configuration.urlTemplate
        browserChoiceID = configuration.browserBundleIdentifier ?? "default"
        systemImageName = configuration.systemImageName
        displayMode = configuration.displayMode
    }

    func configuration(browserChoices: [QuickLinkBrowserChoice]) -> QuickLinkConfiguration? {
        let normalizedName = trimmed(name)
        let normalizedURLTemplate = trimmed(urlTemplate)
        guard !normalizedName.isEmpty, !normalizedURLTemplate.isEmpty else { return nil }

        let browserChoice = browserChoices.first { $0.id == browserChoiceID }
        let iconName = trimmed(systemImageName).isEmpty ? "link" : trimmed(systemImageName)
        return QuickLinkConfiguration(
            name: normalizedName,
            urlTemplate: normalizedURLTemplate,
            browserBundleIdentifier: browserChoice?.bundleIdentifier,
            browserName: browserChoice?.bundleIdentifier == nil ? nil : browserChoice?.title,
            systemImageName: iconName,
            displayMode: displayMode
        )
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct QuickLinkIconChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImageName: String

    static let choices = [
        QuickLinkIconChoice(id: "link", title: "Default", systemImageName: "link"),
        QuickLinkIconChoice(id: "globe", title: "Web", systemImageName: "globe"),
        QuickLinkIconChoice(id: "magnifyingglass", title: "Search", systemImageName: "magnifyingglass"),
        QuickLinkIconChoice(id: "star", title: "Favorite", systemImageName: "star"),
        QuickLinkIconChoice(id: "house", title: "Home", systemImageName: "house"),
        QuickLinkIconChoice(id: "doc.text", title: "Document", systemImageName: "doc.text")
    ]
}

private struct QuickLinkEditorView: View {
    let isEditing: Bool
    let browserChoices: [QuickLinkBrowserChoice]
    let onSave: (QuickLinkEditorDraft) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var draft: QuickLinkEditorDraft
    @State private var validationMessage: String?

    init(
        isEditing: Bool,
        initialDraft: QuickLinkEditorDraft,
        browserChoices: [QuickLinkBrowserChoice],
        onSave: @escaping (QuickLinkEditorDraft) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.isEditing = isEditing
        self.browserChoices = browserChoices
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel

        // If the editor opens with a pre-filled link (e.g. clipboard auto-fill)
        // but no name yet, seed a suggested name now — onChange wouldn't fire
        // for an initial value.
        var seeded = initialDraft
        if seeded.name.trimmingCharacters(in: .whitespaces).isEmpty,
           let suggested = QuickLinkEditorView.suggestedTitle(forURLTemplate: seeded.urlTemplate) {
            seeded.name = suggested
        }
        _draft = State(initialValue: seeded)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    formRow("Name", icon: "textformat", tint: .blue) {
                        TextField("Quicklink name", text: $draft.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    formRow("Link", icon: "link", tint: .purple) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("https://google.com/search?q={argument}", text: $draft.urlTemplate)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: draft.urlTemplate) { newValue in
                                    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty,
                                       let suggested = QuickLinkEditorView.suggestedTitle(forURLTemplate: newValue) {
                                        draft.name = suggested
                                    }
                                }
                            Text("Use {argument}, {clipboard}, {finderPath}, {finderURL}, or any BTT variable. Use raw variants like {rawArgument} when the value should not be URL-encoded.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    formRow("Open With", icon: "app.badge", tint: .teal) {
                        let kindChoices = QuickLinkBrowserChoice.choices(
                            for: QuickLinkBrowserChoice.kind(forURLTemplate: draft.urlTemplate)
                        )
                        Picker("", selection: $draft.browserChoiceID) {
                            ForEach(kindChoices) { browser in
                                Text(browser.title).tag(browser.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: draft.urlTemplate) { _ in
                            if !kindChoices.contains(where: { $0.id == draft.browserChoiceID }) {
                                draft.browserChoiceID = "default"
                            }
                        }
                    }

                    formRow("Icon", icon: "paintpalette.fill", tint: .pink) {
                        Picker("", selection: $draft.systemImageName) {
                            ForEach(QuickLinkIconChoice.choices) { icon in
                                Label(icon.title, systemImage: icon.systemImageName)
                                    .tag(icon.systemImageName)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    formRow("Display", icon: "eye.fill", tint: .orange) {
                        Picker("", selection: $draft.displayMode) {
                            ForEach(QuickLinkDisplayMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let validationMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 11))
                            Text(validationMessage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.red)
                        }
                        .padding(.leading, 118)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footerBar
        }
        .frame(minWidth: 560)
    }

    // MARK: - Sections

    private var footerBar: some View {
        let accent = headerAccent
        return HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(accent)
                Text(isEditing ? "Editing Quick Link" : "New Quick Link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isEditing {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
            Button("Cancel", action: onCancel)
            Button(isEditing ? "Save Quick Link" : "Create Quick Link") {
                save()
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
            // Follow the Launcher's current theme color rather than the
            // per-link-kind accent so buttons match the rest of the launcher UI.
            .tint(Color.accentColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04))
    }

    // MARK: - Helpers

    /// The accent color used for the header/footer/preview. Matches the
    /// per-link-kind tint so the editor visually adapts to whatever link
    /// is being created.
    private var headerAccent: Color {
        switch QuickLinkBrowserChoice.kind(forURLTemplate: draft.urlTemplate) {
        case .browser:   return .blue
        case .image:     return .pink
        case .textCode:  return .purple
        case .folder:    return .orange
        case .file:      return .teal
        }
    }

    /// Compact one-line row: tinted label on the left at a fixed width, control
    /// stretched leading on the right.
    @ViewBuilder
    private func formRow<Content: View>(
        _ title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint.opacity(0.85))
            }
            .frame(width: 110, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func save() {
        guard draft.configuration(browserChoices: browserChoices) != nil else {
            validationMessage = "Name and link are required."
            return
        }
        validationMessage = nil
        onSave(draft)
    }

    /// Derive a sensible Quick Link name from a URL or filesystem path so the
    /// user doesn't have to type one when the field is empty.
    static func suggestedTitle(forURLTemplate template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Filesystem paths: use the last path component (or "Home" for ~).
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed == "~" || trimmed.hasPrefix("./") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            let last = (expanded as NSString).lastPathComponent
            if last.isEmpty || last == "/" {
                return "Home"
            }
            return last
        }

        // URL with scheme — pull the host.
        if let url = URL(string: trimmed),
           let host = url.host, !host.isEmpty {
            return prettyHost(host)
        }

        // No scheme but looks like a domain (e.g. "example.com/foo").
        let firstSegment = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        if firstSegment.contains("."),
           firstSegment.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*\\.[A-Za-z]{2,}$",
                              options: .regularExpression) != nil {
            return prettyHost(firstSegment)
        }
        return nil
    }

    /// "www.github.com" -> "Github", "jira.corp.adobe.com" -> "Jira".
    private static func prettyHost(_ host: String) -> String {
        var trimmed = host
        if trimmed.hasPrefix("www.") {
            trimmed.removeFirst(4)
        }
        let label = trimmed.split(separator: ".").first.map(String.init) ?? trimmed
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

