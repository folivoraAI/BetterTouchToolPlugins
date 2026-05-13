// BTT-Plugin-Name: Google Search Launcher
// BTT-Plugin-Identifier: com.folivora.btt.launcher.googlesearch
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: magnifyingglass
// BTT-AI-Managed: true

import AppKit

final class GoogleSearchLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let search = "google-search"
    }

    static func launcherPluginName() -> String { "Google Search Launcher" }
    static func launcherPluginDescription() -> String { "Searches Google for the current launcher query." }
    static func launcherPluginIcon() -> String { "magnifyingglass" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let query = (context.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let result = BTTLauncherPluginResult()
            result.itemIdentifier = IDs.search
            result.title = "Search Google"
            result.subtitle = "Type a query, then press Return to open it in your browser."
            result.systemImageName = "magnifyingglass"
            result.primaryActionIdentifier = IDs.search
            result.trailingHint = "Open"
            return [result]
        }

        let result = BTTLauncherPluginResult()
        result.itemIdentifier = IDs.search
        result.title = "Search Google for \"\(query)\""
        result.subtitle = "Open the default browser with this search."
        result.systemImageName = "globe"
        result.primaryActionIdentifier = IDs.search
        result.trailingHint = "Open"
        return [result]
    }

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {
        guard itemIdentifier == IDs.search else { return nil }

        let query = (context.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            let result = BTTLauncherPluginActionResult()
            result.success = false
            result.message = "Type a search query first."
            result.closeLauncher = false
            return result
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components.url else {
            let result = BTTLauncherPluginActionResult()
            result.success = false
            result.message = "Could not build the Google search URL."
            result.closeLauncher = false
            return result
        }

        NSWorkspace.shared.open(url)

        let result = BTTLauncherPluginActionResult()
        result.success = true
        result.message = "Opened Google search."
        result.closeLauncher = true
        return result
    }
}
