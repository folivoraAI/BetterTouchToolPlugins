// BTT-Plugin-Name: 1Password Launcher Example
// BTT-Plugin-Identifier: com.folivora.btt.launcher.onepassword
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: lock.shield
// BTT-Principal-Class: OnePasswordLauncherExamplePlugin
// BTT-AI-Managed: true

import AppKit
import Foundation

final class OnePasswordLauncherExamplePlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let browse = "onepassword-browse"
        static let authorize = "onepassword-authorize-cli"
        static let installCLI = "onepassword-install-cli"
        static let openApp = "onepassword-open-app"
        static let refresh = "onepassword-refresh"
    }

    private enum Actions {
        static let open = "open"
        static let openWebsite = "open-website"
        static let copyUsername = "copy-username"
        static let copyPassword = "copy-password"
        static let copyOneTimePassword = "copy-otp"
        static let authorize = "authorize"
        static let installCLI = "install-cli"
        static let openApp = "open-app"
        static let refresh = "refresh"
    }

    private var configuration = OnePasswordConfiguration.default
    private var cachedItems: [OnePasswordItem] = []
    private var cachedItemsDate: Date?
    private var cachedAccount: OnePasswordAccount?

    static func launcherPluginName() -> String {
        "1Password Launcher Example"
    }

    static func launcherPluginDescription() -> String {
        "Example launcher plugin that searches and opens 1Password items through the op CLI."
    }

    static func launcherPluginIcon() -> String {
        "lock.shield"
    }

    static func configurationFormItems() -> BTTPluginFormItem? {
        let group = BTTPluginFormItem()
        group.formFieldType = BTTFormTypeFormGroup

        let description = BTTPluginFormItem()
        description.formFieldType = BTTFormTypeDescription
        description.formLabel1 = "Example implementation of the 1Password launcher integration using only the public BTT launcher plugin API. Requires the 1Password CLI (`op`) and 1Password's CLI integration."

        let cliPath = BTTPluginFormItem()
        cliPath.formFieldType = BTTFormTypeTextField
        cliPath.formLabel1 = "Optional op CLI Path"
        cliPath.formFieldID = "cliPath"
        cliPath.defaultValue = ""

        let keywords = BTTPluginFormItem()
        keywords.formFieldType = BTTFormTypeTextField
        keywords.formLabel1 = "Search Keywords"
        keywords.formFieldID = "keywords"
        keywords.defaultValue = OnePasswordConfiguration.default.keywords.joined(separator: ", ")

        let searchAllQueries = BTTPluginFormItem()
        searchAllQueries.formFieldType = BTTFormTypeCheckbox
        searchAllQueries.formLabel1 = "Search 1Password for every launcher query"
        searchAllQueries.formFieldID = "searchAllQueries"
        searchAllQueries.defaultValue = false

        let loadBrowseChildren = BTTPluginFormItem()
        loadBrowseChildren.formFieldType = BTTFormTypeCheckbox
        loadBrowseChildren.formLabel1 = "Load browse results when the top-level item is shown"
        loadBrowseChildren.formFieldID = "loadBrowseChildren"
        loadBrowseChildren.defaultValue = true

        let maxResults = BTTPluginFormItem()
        maxResults.formFieldType = BTTFormTypeSlider
        maxResults.formLabel1 = "Maximum Results"
        maxResults.formFieldID = "maxResults"
        maxResults.dataType = BTTFormDataNumber
        maxResults.minValue = 10
        maxResults.maxValue = 200
        maxResults.defaultValue = 80

        group.formOptions = [description, cliPath, keywords, searchAllQueries, loadBrowseChildren, maxResults]
        return group
    }

    func didReceiveNewConfigurationValues(_ configurationValues: [AnyHashable: Any]?) {
        let newConfiguration = OnePasswordConfiguration(values: configurationValues ?? [:])
        if newConfiguration != configuration {
            configuration = newConfiguration
            invalidateCache()
        }
    }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let trimmedQuery = (context.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            return [browseEntry(loadChildren: configuration.loadBrowseChildren)]
        }

        let scopedQuery = scopedSearchText(from: trimmedQuery)
        if scopedQuery.isScoped, scopedQuery.searchText.isEmpty {
            return [keywordPromptEntry()]
        }

        let searchText: String
        if scopedQuery.isScoped {
            searchText = scopedQuery.searchText
        } else if configuration.searchAllQueries {
            searchText = trimmedQuery
        } else {
            return nil
        }

        guard !searchText.isEmpty else { return nil }
        return searchResults(for: searchText)
    }

    func loadLauncherResults(
        for context: BTTLauncherPluginContext,
        completion: @escaping ([BTTLauncherPluginResult]?) -> Void
    ) {
        let trimmedQuery = (context.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedQuery = scopedSearchText(from: trimmedQuery)
        let canAnswerWithoutCLI = trimmedQuery.isEmpty || (scopedQuery.isScoped && scopedQuery.searchText.isEmpty)

        guard !canAnswerWithoutCLI else {
            completion(launcherResults(for: context))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = self?.launcherResults(for: context)
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    func loadLauncherChildren(
        forItemIdentifier itemIdentifier: String,
        childrenIdentifier: String?,
        context: BTTLauncherPluginContext,
        completion: @escaping ([BTTLauncherPluginResult]?) -> Void
    ) {
        guard itemIdentifier == IDs.browse, childrenIdentifier == "items" else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = self?.browseChildren()
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {
        let action = actionIdentifier ?? itemIdentifier

        switch action {
        case Actions.refresh:
            do {
                _ = try items(forceRefresh: true)
                delegate?.requestLauncherResultsRefresh()
                return actionResult(success: true, message: "1Password items refreshed.", closeLauncher: false)
            } catch {
                return actionResult(success: false, message: friendlyErrorMessage(for: error), closeLauncher: false)
            }

        case Actions.authorize:
            do {
                let cliPath = try OnePasswordCLI.resolvedCLIPath(configuredPath: configuration.cliPath)
                _ = try OnePasswordCLI.signIn(cliPath: cliPath)
                cachedAccount = nil
                invalidateCache()
                delegate?.requestLauncherResultsRefresh()
                return actionResult(success: true, message: "1Password CLI authorization refreshed.", closeLauncher: false)
            } catch {
                return actionResult(success: false, message: friendlyErrorMessage(for: error), closeLauncher: false)
            }

        case Actions.installCLI:
            if let url = URL(string: "https://developer.1password.com/docs/cli/get-started/") {
                NSWorkspace.shared.open(url)
                return actionResult(success: true, message: "Opened 1Password CLI setup.", closeLauncher: true)
            }
            return actionResult(success: false, message: "Could not open the 1Password CLI setup page.", closeLauncher: false)

        case Actions.openApp:
            let opened = openOnePasswordApp()
            return actionResult(
                success: opened,
                message: opened ? nil : "Could not open 1Password.app.",
                closeLauncher: opened
            )

        default:
            guard let reference = itemReference(from: itemIdentifier) else {
                return actionResult(success: false, message: "No 1Password item was selected.", closeLauncher: false)
            }
            return performItemAction(action, reference: reference)
        }
    }

    private func browseEntry(loadChildren: Bool) -> BTTLauncherPluginResult {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = IDs.browse
        result.title = "1Password"
        result.subtitle = "Browse 1Password items through the op CLI."
        result.systemImageName = "lock.shield"
        result.keywords = ["1password", "1p", "password", "login", "vault"]
        result.trailingHint = "Browse"
        result.primaryActionIdentifier = Actions.refresh
        result.opensChildrenByDefault = true
        result.commands = [
            command(id: Actions.refresh, title: "Refresh Items", systemImageName: "arrow.clockwise", character: "r", closesLauncher: false),
            command(id: Actions.authorize, title: "Authorize 1Password CLI", systemImageName: "lock.shield", character: "a", closesLauncher: false),
            command(id: Actions.openApp, title: "Open 1Password", systemImageName: "lock.open", character: "o", closesLauncher: true),
        ]

        if loadChildren {
            result.dynamicChildrenIdentifier = "items"
        } else if !cachedItems.isEmpty {
            result.children = cachedItems.prefix(configuration.maxResults).enumerated().map { index, item in
                resultItem(for: item, sortOrder: index)
            }
        } else {
            let child = BTTLauncherPluginResult()
            child.itemIdentifier = IDs.refresh
            child.title = "Load 1Password Items"
            child.subtitle = "Press Return to fetch items, then open 1Password again."
            child.systemImageName = "arrow.clockwise"
            child.primaryActionIdentifier = Actions.refresh
            child.trailingHint = "Load"
            result.children = [child]
        }

        return result
    }

    private func keywordPromptEntry() -> BTTLauncherPluginResult {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = IDs.browse
        result.title = "1Password"
        result.subtitle = "Type a search after the keyword, for example: 1p github"
        result.systemImageName = "lock.shield"
        result.keywords = ["1password", "1p", "password", "login", "vault"]
        result.trailingHint = "Search"
        result.primaryActionIdentifier = Actions.refresh
        return result
    }

    private func browseChildren() -> [BTTLauncherPluginResult] {
        do {
            let loadedItems = try items(forceRefresh: false)
            guard !loadedItems.isEmpty else {
                return [statusResult(title: "No 1Password Items", subtitle: "The op CLI returned no items.", systemImageName: "tray")]
            }
            return loadedItems
                .sorted(by: OnePasswordItem.defaultSort(lhs:rhs:))
                .prefix(configuration.maxResults)
                .enumerated()
                .map { index, item in resultItem(for: item, sortOrder: index) }
        } catch {
            return [errorResult(for: error)]
        }
    }

    private func searchResults(for searchText: String) -> [BTTLauncherPluginResult]? {
        do {
            let loadedItems = try items(forceRefresh: false)
            let matches = loadedItems
                .compactMap { item -> (OnePasswordItem, Int)? in
                    guard let score = matchScore(for: item, searchText: searchText) else { return nil }
                    return (item, score)
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return OnePasswordItem.defaultSort(lhs: lhs.0, rhs: rhs.0)
                }
                .prefix(configuration.maxResults)

            let results = matches.enumerated().map { index, pair in
                resultItem(for: pair.0, sortOrder: index)
            }
            if !results.isEmpty {
                return results
            }

            return [
                statusResult(
                    title: "No 1Password Matches",
                    subtitle: "No item matched \"\(searchText)\".",
                    systemImageName: "magnifyingglass"
                )
            ]
        } catch {
            return [errorResult(for: error)]
        }
    }

    private func resultItem(for item: OnePasswordItem, sortOrder: Int) -> BTTLauncherPluginResult {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = item.itemIdentifier
        result.title = item.title
        result.subtitle = item.subtitle
        result.systemImageName = item.categoryIconSystemName
        result.keywords = item.searchCandidates
        result.trailingHint = "Open"
        result.primaryActionIdentifier = Actions.open
        result.sortOrder = NSNumber(value: sortOrder)

        var commands: [BTTLauncherPluginCommand] = [
            command(id: Actions.open, title: "Open in 1Password", systemImageName: "lock.open", character: "o", closesLauncher: true),
            command(id: Actions.copyUsername, title: "Copy Username", systemImageName: "person.crop.circle", character: "u", closesLauncher: true),
            command(id: Actions.copyPassword, title: "Copy Password", systemImageName: "key", character: "p", closesLauncher: true),
            command(id: Actions.copyOneTimePassword, title: "Copy One-Time Password", systemImageName: "timer", character: "t", closesLauncher: true),
        ]
        if item.primaryURL != nil {
            commands.insert(
                command(id: Actions.openWebsite, title: "Open Website", systemImageName: "safari", character: "w", closesLauncher: true),
                at: 1
            )
        }
        result.commands = commands

        return result
    }

    private func errorResult(for error: Error) -> BTTLauncherPluginResult {
        if let onePasswordError = error as? OnePasswordError, onePasswordError.isMissingCLI {
            let result = BTTLauncherPluginResult()
            result.itemIdentifier = IDs.installCLI
            result.title = "Install 1Password CLI"
            result.subtitle = "Install the op command or set its path in this plugin's settings."
            result.systemImageName = "terminal"
            result.primaryActionIdentifier = Actions.installCLI
            result.trailingHint = "Open"
            return result
        }

        let result = BTTLauncherPluginResult()
        result.itemIdentifier = IDs.authorize
        result.title = "Authorize 1Password CLI"
        result.subtitle = friendlyErrorMessage(for: error)
        result.systemImageName = "lock.shield"
        result.primaryActionIdentifier = Actions.authorize
        result.trailingHint = "Authorize"
        return result
    }

    private func statusResult(title: String, subtitle: String, systemImageName: String) -> BTTLauncherPluginResult {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = "status-\(title)"
        result.title = title
        result.subtitle = subtitle
        result.systemImageName = systemImageName
        return result
    }

    private func command(
        id: String,
        title: String,
        systemImageName: String,
        character: String,
        closesLauncher: Bool
    ) -> BTTLauncherPluginCommand {
        let shortcut = BTTLauncherPluginShortcut()
        shortcut.character = character
        shortcut.modifierFlags = [.command]
        shortcut.displayKeys = ["Cmd", character.uppercased()]

        let command = BTTLauncherPluginCommand()
        command.commandIdentifier = id
        command.title = title
        command.systemImageName = systemImageName
        command.shortcut = shortcut
        command.closesLauncherOnSuccess = closesLauncher
        return command
    }

    private func scopedSearchText(from query: String) -> (isScoped: Bool, searchText: String) {
        let lowercasedQuery = query.lowercased()
        for keyword in configuration.normalizedKeywords {
            if lowercasedQuery == keyword {
                return (true, "")
            }
            if lowercasedQuery.hasPrefix(keyword + " ") {
                let startIndex = query.index(query.startIndex, offsetBy: keyword.count)
                return (true, String(query[startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (false, query)
    }

    private func matchScore(for item: OnePasswordItem, searchText: String) -> Int? {
        let tokens = searchText
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }

        let candidates = item.searchCandidates.map { $0.lowercased() }
        var score = item.favorite ? 20 : 0

        for token in tokens {
            var bestTokenScore: Int?
            for candidate in candidates {
                if candidate == token {
                    bestTokenScore = max(bestTokenScore ?? 0, 120)
                } else if candidate.hasPrefix(token) {
                    bestTokenScore = max(bestTokenScore ?? 0, 90)
                } else if candidate.contains(token) {
                    bestTokenScore = max(bestTokenScore ?? 0, 45)
                }
            }
            guard let tokenScore = bestTokenScore else { return nil }
            score += tokenScore
        }

        if item.title.lowercased().hasPrefix(searchText.lowercased()) {
            score += 40
        }

        return score
    }

    private func performItemAction(_ action: String, reference: OnePasswordItemReference) -> BTTLauncherPluginActionResult {
        do {
            let cliPath = try OnePasswordCLI.resolvedCLIPath(configuredPath: configuration.cliPath)

            switch action {
            case Actions.open:
                let account = try account(cliPath: cliPath)
                guard let url = onePasswordURL(for: reference, account: account) else {
                    return actionResult(success: false, message: "Could not build the 1Password item URL.", closeLauncher: false)
                }
                let opened = NSWorkspace.shared.open(url)
                return actionResult(success: opened, message: opened ? nil : "Could not open the item in 1Password.", closeLauncher: opened)

            case Actions.openWebsite:
                guard let url = try primaryWebsiteURL(for: reference, cliPath: cliPath) else {
                    return actionResult(success: false, message: "This 1Password item does not include a website URL.", closeLauncher: false)
                }
                let opened = NSWorkspace.shared.open(url)
                return actionResult(success: opened, message: opened ? nil : "Could not open the website URL.", closeLauncher: opened)

            case Actions.copyUsername:
                return try copyField("username", displayName: "username", reference: reference, cliPath: cliPath)

            case Actions.copyPassword:
                return try copyField("password", displayName: "password", reference: reference, cliPath: cliPath)

            case Actions.copyOneTimePassword:
                let value = try OnePasswordCLI.oneTimePassword(
                    cliPath: cliPath,
                    itemID: reference.id,
                    vaultID: reference.vaultID
                )
                return copySecretToClipboard(value, displayName: "one-time password")

            default:
                return actionResult(success: false, message: "Unknown 1Password action.", closeLauncher: false)
            }
        } catch {
            return actionResult(success: false, message: friendlyErrorMessage(for: error), closeLauncher: false)
        }
    }

    private func items(forceRefresh: Bool) throws -> [OnePasswordItem] {
        if !forceRefresh,
           let cachedItemsDate,
           !cachedItems.isEmpty,
           Date().timeIntervalSince(cachedItemsDate) < configuration.cacheTimeToLive {
            return cachedItems
        }

        let cliPath = try OnePasswordCLI.resolvedCLIPath(configuredPath: configuration.cliPath)
        let loadedItems = try OnePasswordCLI.listItems(cliPath: cliPath)
        cachedItems = loadedItems
        cachedItemsDate = Date()
        return loadedItems
    }

    private func account(cliPath: String) throws -> OnePasswordAccount {
        if let cachedAccount {
            return cachedAccount
        }

        do {
            let account = try OnePasswordCLI.whoami(cliPath: cliPath)
            cachedAccount = account
            return account
        } catch {
            let accounts = (try? OnePasswordCLI.accountList(cliPath: cliPath)) ?? []
            let signedInAccounts = accounts.filter { !$0.accountUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard signedInAccounts.count == 1, let account = signedInAccounts.first else {
                throw error
            }
            cachedAccount = account
            return account
        }
    }

    private func primaryWebsiteURL(for reference: OnePasswordItemReference, cliPath: String) throws -> URL? {
        if let primaryURLString = reference.primaryURLString,
           let url = URL(string: primaryURLString) {
            return url
        }

        let details = try OnePasswordCLI.itemDetails(
            cliPath: cliPath,
            itemID: reference.id,
            vaultID: reference.vaultID
        )
        guard let urlString = details.primaryURL else { return nil }
        return URL(string: urlString)
    }

    private func copyField(
        _ field: String,
        displayName: String,
        reference: OnePasswordItemReference,
        cliPath: String
    ) throws -> BTTLauncherPluginActionResult {
        let value = try OnePasswordCLI.readField(
            cliPath: cliPath,
            vaultID: reference.vaultID,
            itemID: reference.id,
            field: field
        )
        return copySecretToClipboard(value, displayName: displayName)
    }

    private func copySecretToClipboard(_ value: String, displayName: String) -> BTTLauncherPluginActionResult {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return actionResult(success: false, message: "1Password returned an empty \(displayName).", closeLauncher: false)
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmedValue, forType: .string)
        return actionResult(success: true, message: "Copied \(displayName).", closeLauncher: true)
    }

    private func itemReference(from itemIdentifier: String) -> OnePasswordItemReference? {
        let parts = itemIdentifier.components(separatedBy: "|")
        guard parts.count == 3, parts[0] == "item" else { return nil }
        let vaultID = parts[1]
        let itemID = parts[2]

        if let item = cachedItems.first(where: { $0.id == itemID && $0.vault.id == vaultID }) {
            return item.reference
        }

        return OnePasswordItemReference(
            id: itemID,
            title: itemID,
            vaultID: vaultID,
            primaryURLString: nil
        )
    }

    private func onePasswordURL(for reference: OnePasswordItemReference, account: OnePasswordAccount) -> URL? {
        var components = URLComponents()
        components.scheme = "onepassword"
        components.host = "open"
        components.path = "/i"

        var queryItems = [
            URLQueryItem(name: "a", value: account.accountUUID),
            URLQueryItem(name: "v", value: reference.vaultID),
            URLQueryItem(name: "i", value: reference.id),
        ]
        if let host = account.host {
            queryItems.append(URLQueryItem(name: "h", value: host))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func openOnePasswordApp() -> Bool {
        let bundleIdentifiers = [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.agilebits.onepassword-osx",
        ]
        for bundleIdentifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return NSWorkspace.shared.open(url)
            }
        }

        let paths = [
            "/Applications/1Password.app",
            "/Applications/Setapp/1Password.app",
            NSHomeDirectory() + "/Applications/1Password.app",
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        return false
    }

    private func invalidateCache() {
        cachedItems = []
        cachedItemsDate = nil
        cachedAccount = nil
    }

    private func actionResult(success: Bool, message: String?, closeLauncher: Bool) -> BTTLauncherPluginActionResult {
        let result = BTTLauncherPluginActionResult()
        result.success = success
        result.message = message
        result.closeLauncher = closeLauncher
        return result
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        if let onePasswordError = error as? OnePasswordError {
            switch onePasswordError {
            case .missingCLI:
                return "1Password CLI is not installed or the configured path is invalid."
            case .timeout:
                return "1Password CLI did not respond in time."
            case .invalidOutput:
                return "1Password CLI returned invalid output."
            case .commandFailed(let message):
                return friendlyCommandFailureMessage(message)
            }
        }
        return error.localizedDescription
    }

    private func friendlyCommandFailureMessage(_ message: String) -> String {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredMessage = trimmedMessage.lowercased()
        if loweredMessage.contains("account is not signed in") ||
            loweredMessage.contains("not signed in") ||
            loweredMessage.contains("not currently signed in") ||
            loweredMessage.contains("signin") ||
            loweredMessage.contains("sign in") ||
            loweredMessage.contains("authenticate") ||
            loweredMessage.contains("authorization") {
            return "Unlock 1Password and allow the CLI integration, then try again."
        }
        if loweredMessage.contains("does not have a field") {
            return "This 1Password item does not contain that field."
        }
        if loweredMessage.contains("could not get item") || loweredMessage.contains("isn't an item") {
            return "1Password could not find that item."
        }
        return trimmedMessage.isEmpty ? "1Password CLI failed." : trimmedMessage
    }
}

private struct OnePasswordConfiguration: Equatable {
    var cliPath: String
    var keywords: [String]
    var searchAllQueries: Bool
    var loadBrowseChildren: Bool
    var maxResults: Int
    var cacheTimeToLive: TimeInterval

    static let defaultKeywords = ["1p", "1password", "password", "login"]

    static let `default` = OnePasswordConfiguration(
        cliPath: "",
        keywords: defaultKeywords,
        searchAllQueries: false,
        loadBrowseChildren: true,
        maxResults: 80,
        cacheTimeToLive: 300
    )

    init(
        cliPath: String,
        keywords: [String],
        searchAllQueries: Bool,
        loadBrowseChildren: Bool,
        maxResults: Int,
        cacheTimeToLive: TimeInterval
    ) {
        self.cliPath = cliPath
        self.keywords = OnePasswordConfiguration.normalizedKeywords(from: keywords)
        self.searchAllQueries = searchAllQueries
        self.loadBrowseChildren = loadBrowseChildren
        self.maxResults = max(1, maxResults)
        self.cacheTimeToLive = cacheTimeToLive
    }

    init(values: [AnyHashable: Any]) {
        let defaults = OnePasswordConfiguration.default
        let cliPath = Self.stringValue(from: values, keys: ["plugin_var_cliPath", "cliPath"]) ?? defaults.cliPath
        let rawKeywords = Self.stringValue(from: values, keys: ["plugin_var_keywords", "keywords"]) ?? defaults.keywords.joined(separator: ", ")
        let searchAllQueries = Self.boolValue(from: values, keys: ["plugin_var_searchAllQueries", "searchAllQueries"]) ?? defaults.searchAllQueries
        let loadBrowseChildren = Self.boolValue(from: values, keys: ["plugin_var_loadBrowseChildren", "loadBrowseChildren"]) ?? defaults.loadBrowseChildren
        let maxResults = Self.intValue(from: values, keys: ["plugin_var_maxResults", "maxResults"]) ?? defaults.maxResults

        self.init(
            cliPath: cliPath.trimmingCharacters(in: .whitespacesAndNewlines),
            keywords: rawKeywords.split(separator: ",").map { String($0) },
            searchAllQueries: searchAllQueries,
            loadBrowseChildren: loadBrowseChildren,
            maxResults: maxResults,
            cacheTimeToLive: defaults.cacheTimeToLive
        )
    }

    var normalizedKeywords: [String] {
        OnePasswordConfiguration.normalizedKeywords(from: keywords)
    }

    static func normalizedKeywords(from values: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for value in values {
            let keyword = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !keyword.isEmpty else { continue }
            if seen.insert(keyword).inserted {
                normalized.append(keyword)
            }
        }

        return normalized.isEmpty ? defaultKeywords : normalized
    }

    private static func stringValue(from values: [AnyHashable: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = values[key] as? String {
                return value
            }
            if let value = values[key] as? NSString {
                return value as String
            }
        }
        return nil
    }

    private static func boolValue(from values: [AnyHashable: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = values[key] as? Bool {
                return value
            }
            if let value = values[key] as? NSNumber {
                return value.boolValue
            }
            if let value = values[key] as? String {
                return NSString(string: value).boolValue
            }
        }
        return nil
    }

    private static func intValue(from values: [AnyHashable: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = values[key] as? Int {
                return value
            }
            if let value = values[key] as? NSNumber {
                return value.intValue
            }
            if let value = values[key] as? String, let intValue = Int(value) {
                return intValue
            }
        }
        return nil
    }
}

private struct OnePasswordItemReference {
    let id: String
    let title: String
    let vaultID: String
    let primaryURLString: String?
}

private struct OnePasswordItem: Decodable, Hashable {
    let id: String
    let title: String
    let category: String
    let additionalInformation: String?
    let favorite: Bool
    let urls: [OnePasswordItemURL]
    let vault: OnePasswordVault

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case category
        case additionalInformation = "additional_information"
        case favorite
        case urls
        case vault
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled 1Password Item"
        category = (try container.decodeIfPresent(String.self, forKey: .category) ?? "CUSTOM").uppercased()
        additionalInformation = try container.decodeIfPresent(String.self, forKey: .additionalInformation)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        urls = try container.decodeIfPresent([OnePasswordItemURL].self, forKey: .urls) ?? []
        vault = try container.decode(OnePasswordVault.self, forKey: .vault)
    }

    var itemIdentifier: String {
        "item|\(vault.id)|\(id)"
    }

    var reference: OnePasswordItemReference {
        OnePasswordItemReference(
            id: id,
            title: title,
            vaultID: vault.id,
            primaryURLString: primaryURL
        )
    }

    var subtitle: String {
        var parts: [String] = []
        if let additionalInformation = cleaned(additionalInformation) {
            parts.append(additionalInformation)
        }
        parts.append(categoryDisplayName)
        if let vaultName = cleaned(vault.name) {
            parts.append(vaultName)
        }
        return parts.joined(separator: " - ")
    }

    var primaryURL: String? {
        if let primary = urls.first(where: { $0.primary }), cleaned(primary.href) != nil {
            return primary.href
        }
        return urls.first(where: { cleaned($0.href) != nil })?.href
    }

    var searchCandidates: [String] {
        var candidates = [
            title,
            categoryDisplayName,
            category,
            vault.name ?? "",
            additionalInformation ?? "",
        ]

        for url in urls {
            candidates.append(url.href)
            if let host = URL(string: url.href)?.host {
                candidates.append(host)
            }
            if let label = url.label {
                candidates.append(label)
            }
        }

        return deduplicatedNonEmptyStrings(candidates)
    }

    var categoryDisplayName: String {
        category
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    var categoryIconSystemName: String {
        switch category {
        case "LOGIN":
            return "person.crop.circle"
        case "PASSWORD":
            return "key"
        case "CREDIT_CARD":
            return "creditcard"
        case "BANK_ACCOUNT":
            return "building.columns"
        case "SECURE_NOTE":
            return "note.text"
        case "IDENTITY":
            return "person.crop.rectangle"
        case "DOCUMENT":
            return "doc"
        case "SSH_KEY", "API_CREDENTIAL":
            return "terminal"
        case "WIRELESS_ROUTER":
            return "wifi"
        default:
            return "lock"
        }
    }

    static func defaultSort(lhs: OnePasswordItem, rhs: OnePasswordItem) -> Bool {
        if lhs.favorite != rhs.favorite {
            return lhs.favorite
        }
        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func deduplicatedNonEmptyStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                result.append(trimmed)
            }
        }

        return result
    }
}

private struct OnePasswordItemURL: Decodable, Hashable {
    let href: String
    let label: String?
    let primary: Bool

    enum CodingKeys: String, CodingKey {
        case href
        case label
        case primary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decodeIfPresent(String.self, forKey: .href) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label)
        primary = try container.decodeIfPresent(Bool.self, forKey: .primary) ?? false
    }
}

private struct OnePasswordVault: Decodable, Hashable {
    let id: String
    let name: String?
}

private struct OnePasswordAccount: Decodable, Hashable {
    let accountUUID: String
    let url: String?
    let email: String?
    let userUUID: String?

    enum CodingKeys: String, CodingKey {
        case accountUUID = "account_uuid"
        case url
        case email
        case userUUID = "user_uuid"
    }

    var host: String? {
        let trimmedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedURL.isEmpty else { return nil }

        let parseableURL = trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)"
        if let host = URL(string: parseableURL)?.host, !host.isEmpty {
            return host
        }

        let trimmedHost = trimmedURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedHost.isEmpty ? nil : trimmedHost
    }
}

private enum OnePasswordError: Error {
    case missingCLI
    case timeout
    case invalidOutput
    case commandFailed(String)

    var isMissingCLI: Bool {
        if case .missingCLI = self { return true }
        return false
    }
}

private enum OnePasswordCLI {
    static func resolvedCLIPath(configuredPath: String) throws -> String {
        let trimmedConfiguredPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredCandidates = trimmedConfiguredPath.isEmpty ? [] : [
            NSString(string: trimmedConfiguredPath).expandingTildeInPath,
        ]
        let candidates = configuredCandidates + [
            "/opt/homebrew/bin/op",
            "/usr/local/bin/op",
            "/Applications/1Password.app/Contents/MacOS/op",
            "/Applications/Setapp/1Password.app/Contents/MacOS/op",
            NSHomeDirectory() + "/Applications/1Password.app/Contents/MacOS/op",
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        if let shellPath = shellResolvedCLIPath() {
            return shellPath
        }

        throw OnePasswordError.missingCLI
    }

    static func listItems(cliPath: String) throws -> [OnePasswordItem] {
        do {
            return try listItems(cliPath: cliPath, accountUUID: nil, usesLegacyCommand: false)
        } catch {
            if let accountUUID = try? singleAccountUUID(cliPath: cliPath) {
                do {
                    return try listItems(cliPath: cliPath, accountUUID: accountUUID, usesLegacyCommand: false)
                } catch {
                    if shouldRetryWithLegacyItemsCommand(error) {
                        return try listItems(cliPath: cliPath, accountUUID: accountUUID, usesLegacyCommand: true)
                    }
                    throw error
                }
            }

            if shouldRetryWithLegacyItemsCommand(error) {
                return try listItems(cliPath: cliPath, accountUUID: nil, usesLegacyCommand: true)
            }
            throw error
        }
    }

    private static func listItems(
        cliPath: String,
        accountUUID: String?,
        usesLegacyCommand: Bool
    ) throws -> [OnePasswordItem] {
        var arguments: [String] = []
        if let accountUUID, !accountUUID.isEmpty {
            arguments.append(contentsOf: ["--account", accountUUID])
        }
        arguments.append(contentsOf: [
            usesLegacyCommand ? "items" : "item",
            "list",
            "--format",
            "json",
        ])

        let output = try runSynchronously(cliPath: cliPath, arguments: arguments, timeout: 45)
        do {
            return try JSONDecoder().decode([OnePasswordItem].self, from: output)
        } catch {
            throw OnePasswordError.invalidOutput
        }
    }

    static func itemDetails(cliPath: String, itemID: String, vaultID: String) throws -> OnePasswordItem {
        let output = try runSynchronously(
            cliPath: cliPath,
            arguments: ["item", "get", itemID, "--vault", vaultID, "--format", "json"],
            timeout: 20
        )
        do {
            return try JSONDecoder().decode(OnePasswordItem.self, from: output)
        } catch {
            throw OnePasswordError.invalidOutput
        }
    }

    static func whoami(cliPath: String) throws -> OnePasswordAccount {
        let output = try runSynchronously(cliPath: cliPath, arguments: ["whoami", "--format", "json"], timeout: 20)
        do {
            return try JSONDecoder().decode(OnePasswordAccount.self, from: output)
        } catch {
            throw OnePasswordError.invalidOutput
        }
    }

    static func accountList(cliPath: String) throws -> [OnePasswordAccount] {
        let output = try runSynchronously(cliPath: cliPath, arguments: ["account", "list", "--format", "json"], timeout: 20)
        do {
            return try JSONDecoder().decode([OnePasswordAccount].self, from: output)
        } catch {
            throw OnePasswordError.invalidOutput
        }
    }

    static func signIn(cliPath: String) throws -> Data {
        try runSynchronously(cliPath: cliPath, arguments: ["signin"], timeout: 60)
    }

    static func readField(cliPath: String, vaultID: String, itemID: String, field: String) throws -> String {
        let output = try runSynchronously(
            cliPath: cliPath,
            arguments: ["read", "op://\(vaultID)/\(itemID)/\(field)"],
            timeout: 20
        )
        return secretString(from: output)
    }

    static func oneTimePassword(cliPath: String, itemID: String, vaultID: String) throws -> String {
        let output = try runSynchronously(
            cliPath: cliPath,
            arguments: ["item", "get", itemID, "--vault", vaultID, "--otp"],
            timeout: 20
        )
        return secretString(from: output)
    }

    private static func singleAccountUUID(cliPath: String) throws -> String? {
        let accounts = try accountList(cliPath: cliPath)
        let accountUUIDs = accounts
            .map(\.accountUUID)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard accountUUIDs.count == 1 else { return nil }
        return accountUUIDs[0]
    }

    private static func shellResolvedCLIPath() -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return nil }
        let output = try? runSynchronously(
            cliPath: "/bin/zsh",
            arguments: ["-lc", "command -v op"],
            timeout: 3
        )
        guard let output,
              let path = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private static func runSynchronously(cliPath: String, arguments: [String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = defaultPath + ":" + existingPath
        } else {
            environment["PATH"] = defaultPath
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = PipeBuffer()
        let stderrBuffer = PipeBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw OnePasswordError.missingCLI
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.15)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw OnePasswordError.timeout
        }

        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.availableData)
        stderrBuffer.append(stderrPipe.fileHandleForReading.availableData)

        let stdout = stdoutBuffer.data
        let stderrString = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stdoutString = String(data: stdout, encoding: .utf8) ?? ""
            let combinedMessage = [stderrString, stdoutString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw OnePasswordError.commandFailed(combinedMessage)
        }

        return stdout
    }

    private static func shouldRetryWithLegacyItemsCommand(_ error: Error) -> Bool {
        guard let onePasswordError = error as? OnePasswordError,
              case .commandFailed(let message) = onePasswordError else {
            return false
        }
        let loweredMessage = message.lowercased()
        return loweredMessage.contains("unknown command") ||
            loweredMessage.contains("unknown subcommand") ||
            loweredMessage.contains("invalid command")
    }

    private static func secretString(from data: Data) -> String {
        var value = String(data: data, encoding: .utf8) ?? ""
        while value.last == "\n" || value.last == "\r" {
            value.removeLast()
        }
        return value
    }
}

private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
}
