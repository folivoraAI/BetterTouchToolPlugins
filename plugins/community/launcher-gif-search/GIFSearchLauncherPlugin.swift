// BTT-Plugin-Name: GIF Search
// BTT-Plugin-Identifier: com.github.loaykhalifa.gifsearch
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: photo.stack

import AppKit
import SwiftUI
import Foundation
import ApplicationServices
import UniformTypeIdentifiers

private typealias GIFViewState<Value> = SwiftUI.State<Value>

class GIFSearchLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?
    private var selectedService = GIFService.giphy.rawValue
    private var credentials = GIFCredentials()
    private var configuredResultLimit = GIFResultLimit.legacyDefault

    override init() { super.init(); _ = GIFDestinationTracker.shared }

    private enum IDs { static let open = "open-gif-search"; static let surface = "gif-search-surface" }

    static func launcherPluginName() -> String { "GIF Search" }
    static func launcherPluginDescription() -> String { "GIF search with providers, favorites and recents." }
    static func launcherPluginIcon() -> String { "photo.stack" }

    static func configurationFormItems() -> BTTPluginFormItem? {
        let group = BTTPluginFormItem(); group.formFieldType = BTTFormTypeFormGroup
        let service = BTTPluginFormItem(); service.formFieldType = BTTFormTypePopupButton
        service.formFieldID = "gifService"; service.formLabel1 = "Default provider"
        service.formLabel2 = "Used when GIF Search first opens. The toolbar changes only the current session."
        service.shouldTriggerReload = true
        service.formOptions = GIFService.availableServices.map { provider in
            let option = BTTPluginFormItem()
            option.formLabel1 = provider.selectionTitle
            option.formOption = provider.title
            return option
        }
        service.defaultValue = GIFService.giphy.title; service.dataType = BTTFormDataString
        let count = BTTPluginFormItem()
        count.formFieldType = BTTFormTypePopupButton
        count.formFieldID = "gifResultLimit"; count.formLabel1 = "Results per search"
        count.formLabel2 = "Initial target for GIPHY/KLIPY: 100 uses two requests. Commons returns up to 50. Load more supports GIPHY/KLIPY."
        count.formOptions = GIFResultLimit.supported.map { value in
            let option = BTTPluginFormItem()
            option.formLabel1 = String(value); option.formOption = NSNumber(value: value)
            return option
        }
        count.defaultValue = NSNumber(value: GIFResultLimit.legacyDefault)
        count.dataType = BTTFormDataNumber; count.shouldTriggerReload = true
        let giphy = BTTPluginFormItem()
        giphy.formFieldType = BTTFormTypeTextField
        giphy.formFieldID = "giphyAPIKey"; giphy.formLabel1 = "GIPHY API key"
        giphy.formLabel2 = "Create at https://developers.giphy.com/dashboard/ • Used for GIPHY GIFs."
        giphy.defaultValue = ""; giphy.dataType = BTTFormDataString; giphy.shouldTriggerReload = true
        let klipy = BTTPluginFormItem()
        klipy.formFieldType = BTTFormTypeTextField
        klipy.formFieldID = "klipyAPIKey"; klipy.formLabel1 = "KLIPY app key — GIFs, Stickers & Memes"
        klipy.formLabel2 = "Create at https://partner.klipy.com/ • One key is used for all KLIPY content types."
        klipy.defaultValue = ""; klipy.dataType = BTTFormDataString; klipy.shouldTriggerReload = true
        let general = BTTPluginFormItem(); general.formFieldType = BTTFormTypeTitleField
        general.formLabel1 = "Startup"
        let apiTitle = BTTPluginFormItem(); apiTitle.formFieldType = BTTFormTypeTitleField
        apiTitle.formLabel1 = "API Keys"
        let keyInfo = BTTPluginFormItem(); keyInfo.formFieldType = BTTFormTypeDescription
        keyInfo.formLabel1 = "Wikimedia Commons needs no API key. Other keys are saved in BTT settings, not Keychain. Favorites / Recent refresh through their original providers."
        group.formOptions = [general, service, count, apiTitle, giphy, klipy, keyInfo]; return group
    }

    func didReceiveNewConfigurationValues(_ configurationValues: [AnyHashable: Any]?) {
        let raw = (configurationValues?["plugin_var_gifService"] ?? configurationValues?["gifService"]) as? String
        let requested = GIFService.from(raw) ?? .giphy
        selectedService = (GIFService.availableServices.contains(requested) ? requested : .giphy).rawValue
        configuredResultLimit = GIFResultLimit.from(configurationValues?["plugin_var_gifResultLimit"]
            ?? configurationValues?["gifResultLimit"]) ?? GIFResultLimit.legacyDefault
        credentials = GIFCredentials(
            giphy: ((configurationValues?["plugin_var_giphyAPIKey"] ?? configurationValues?["giphyAPIKey"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            klipy: ((configurationValues?["plugin_var_klipyAPIKey"] ?? configurationValues?["klipyAPIKey"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let result = BTTLauncherPluginResult(); result.itemIdentifier = IDs.open
        result.title = "GIF Search"; result.subtitle = "Choose GIPHY, KLIPY, Stickers, Memes, Wikimedia Commons, Favorites or Recent."
        result.systemImageName = "photo.stack"; result.surfaceIdentifier = IDs.surface; result.trailingHint = "Open"
        result.keywords = ["gif", "giphy", "klipy", "stickers", "memes", "commons", "wikimedia", "favorites", "recent"]
        result.searchMatchPriority = 80; return [result]
    }

    func launcherSurface(forItemIdentifier itemIdentifier: String, surfaceIdentifier: String?, context: BTTLauncherPluginContext) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard itemIdentifier == IDs.open, surfaceIdentifier == IDs.surface else { return nil }
        return GIFSearchSurface(destination: GIFDestinationTracker.shared.destination(for: context.frontmostBundleIdentifier), initialQuery: context.query ?? "", service: GIFPreferences.startingService(defaultService: GIFService(rawValue: selectedService) ?? .giphy), credentials: credentials, resultLimit: configuredResultLimit)
    }
}

final class GIFSearchSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private let model: GIFSearchViewModel
    private let insertion: GIFInsertionCoordinator
    convenience init(destination: GIFDestination? = nil, initialQuery: String, service: GIFService, credentials: GIFCredentials, resultLimit: Int? = nil) {
        self.init(model: GIFSearchViewModel(initialQuery: initialQuery, service: service, credentials: credentials, resultLimit: resultLimit), destination: destination)
    }
    init(model: GIFSearchViewModel, destination: GIFDestination? = nil) {
        // Pin the launcher's original app/window per surface; do not read mutable global focus at Insert time.
        var environment = GIFPasteEnvironment()
        environment.expected = { destination }
        self.insertion = GIFInsertionCoordinator(environment: environment)
        self.model = model; super.init()
        model.onCancelRequested = { [weak self] in guard let self else { return }; self.insertion.cancel(model: self.model) }
        model.onInsertRequested = { [weak self] item in
            guard let self else { return }
            self.insertion.begin(item: item, model: self.model, close: { [weak self] in
                self?.delegate?.requestLauncherSurfaceClose()
            })
        }
        model.onRequestChromeUpdate = { [weak self] in self?.delegate?.requestLauncherSurfaceUpdate() }
    }
    func makeLauncherSurfaceView() -> NSView { NSHostingView(rootView: GIFSearchRootView(model: model)) }
    func launcherSurfaceDidAppear() { model.refresh() }
    func launcherSurfaceWillDisappear() {
        model.cancelSearch()
        if !insertion.isClosingForPaste { insertion.cancel(model: model) }
    }
    func launcherSurfaceQueryDidChange(_ query: String?) { model.searchTextChanged(query ?? "") }
    func launcherSurfacePlaceholderText() -> String? { model.placeholder }
    func launcherSurfaceFooterHint() -> String? { "↵ Insert · ⌘C Copy · ⌘F Favorite · ⌥Space Preview · ? Help" }
    func launcherSurfaceStatusText() -> String? { nil }
    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 930, height: 610) }
    func launcherSurfaceMinimumContentSize() -> CGSize { CGSize(width: 700, height: 430) }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }
    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool { false }
    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        guard NSApp.modalWindow == nil, !model.showPreview, !model.showHelp else { return nil }
        let r = BTTLauncherPluginSurfaceCommandResult(); r.handled = true; r.closeLauncher = false; r.goBack = false
        switch command {
        case .moveLeft: model.moveSelection(dx: -1, dy: 0)
        case .moveRight: model.moveSelection(dx: 1, dy: 0)
        case .moveUp: model.moveSelection(dx: 0, dy: -1)
        case .moveDown: model.moveSelection(dx: 0, dy: 1)
        case .activateSelection:
            if !model.isPreparingMedia { insertSelectedMedia() }
        case .copySelection:
            model.copySelectedGIFToPasteboard()
        default: r.handled = false
        }
        return r
    }
    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, NSApp.modalWindow == nil, !model.showPreview, !model.showHelp else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let ch = event.charactersIgnoringModifiers?.lowercased()

        if event.keyCode == 49, flags == [.option] {
            if !event.isARepeat { model.showPreview = model.canAct }
            return true
        }
        if ch == "?", flags == [.shift] { model.showHelp = true; return true }
        if event.keyCode == 48, flags.isEmpty || flags == [.shift] {
            if !event.isARepeat { model.cycleProvider(backwards: flags.contains(.shift)) }
            return true
        }

        // Handle navigation here as well as in handleLauncherInputCommand because some
        // launcher surfaces deliver arrow/return keys as raw NSEvents.
        if flags.isEmpty { switch event.keyCode {
        case 123: // left arrow
            model.moveSelection(dx: -1, dy: 0)
            return true
        case 124: // right arrow
            model.moveSelection(dx: 1, dy: 0)
            return true
        case 126: // up arrow
            model.moveSelection(dx: 0, dy: -1)
            return true
        case 125: // down arrow
            model.moveSelection(dx: 0, dy: 1)
            return true
        case 36, 76: // return, keypad enter
            if !event.isARepeat { insertSelectedMedia() }
            return true
        default:
            break
        }

        }
        if flags == [.command, .shift], ch == "c" { model.copySelectedURLToPasteboard(); delegate?.requestLauncherSurfaceClose(); return true }
        if flags == [.command], ch == "c" { model.copySelectedGIFToPasteboard(); return true }
        if flags == [.command], ch == "f" { if !event.isARepeat { model.toggleFavoriteSelected() }; return true }
        return false
    }
    private func insertSelectedMedia() { model.requestInsert() }

}

enum GIFResultLimit {
    static let supported = [24, 50, 100]
    static func from(_ value: Any?) -> Int? {
        let parsed: Int?
        if let number = value as? NSNumber {
            parsed = number.doubleValue.rounded() == number.doubleValue ? number.intValue : nil
        } else if let text = value as? String {
            parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else { parsed = nil }
        guard let parsed, supported.contains(parsed) else { return nil }
        return parsed
    }
    static var legacyDefault: Int {
        from(UserDefaults.standard.object(forKey: "BTTGIFSearchResultLimit")) ?? 24
    }
}

struct GIFCredentials {
    var giphy = ""
    var klipy = ""
}

// Do not retain the request URL: it can contain a provider API key.
struct GIFHTTPError: LocalizedError {
    let statusCode: Int
    var errorDescription: String? { "HTTP \(statusCode)" }
}

struct GIFPayload {
    let data: Data
    let mimeType: String?
}

// A short-lived, non-caching session per request bounds memory and total duration.
// Redirects cannot downgrade to HTTP or send an API key to a different origin.
final class GIFNetwork: NSObject, URLSessionDataDelegate {
    static var transport: GIFTransport = .shared
    private let source: URL
    private let maxBytes: Int
    private let completion: (Result<GIFPayload, Error>) -> Void
    private var received = Data()
    private var mimeType: String?
    private var failure: Error?
    fileprivate var usesSharedTransport = false

    private init(source: URL, maxBytes: Int, completion: @escaping (Result<GIFPayload, Error>) -> Void) {
        self.source = source; self.maxBytes = maxBytes; self.completion = completion
    }

    static func httpsURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func permitsRedirect(from source: URL, to target: URL) -> Bool {
        guard httpsURL(target.absoluteString) != nil else { return false }
        let mediaHosts = ["upload.wikimedia.org", "thumb.wikimedia.org"]
        if let from = source.host?.lowercased(), let to = target.host?.lowercased(),
           mediaHosts.contains(from), mediaHosts.contains(to),
           (source.port ?? 443) == 443, (target.port ?? 443) == 443 { return true }
        return source.host?.lowercased() == target.host?.lowercased() &&
            (source.port ?? 443) == (target.port ?? 443)
    }

    static func clipboardType(_ data: Data) -> NSPasteboard.PasteboardType? {
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return NSPasteboard.PasteboardType("com.compuserve.gif")
        }
        if data.starts(with: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
            return .png
        }
        if data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) {
            return NSPasteboard.PasteboardType("public.mpeg-4")
        }
        return nil
    }

    @discardableResult
    static func fetch(_ url: URL, maxBytes: Int,
                      completion: @escaping (Result<GIFPayload, Error>) -> Void) -> URLSessionDataTask? {
        guard httpsURL(url.absoluteString) != nil, maxBytes > 0 else {
            completion(.failure(URLError(.badURL))); return nil
        }
        let loader = GIFNetwork(source: url, maxBytes: maxBytes, completion: completion)
        loader.usesSharedTransport = true
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let wikimediaHosts = ["commons.wikimedia.org", "upload.wikimedia.org", "thumb.wikimedia.org"]
        let agent = wikimediaHosts.contains(url.host?.lowercased() ?? "")
            ? "BTTGIFSearch/1.0.9 (https://github.com/loaykhalifa/BetterTouchToolPlugins)"
            : "BetterTouchTool-GIFSearch"
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        let task = transport.start(request, loader: loader)
        return task
    }

    static func data(_ url: URL, maxBytes: Int) async throws -> GIFPayload {
        let cancellation = GIFRequestCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = fetch(url, maxBytes: maxBytes) { continuation.resume(with: $0) }
                cancellation.install(task)
            }
        }, onCancel: { cancellation.cancel() })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, Self.permitsRedirect(from: source, to: target) else {
            failure = URLError(.redirectToNonExistentLocation)
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              let url = response.url, Self.httpsURL(url.absoluteString) != nil,
              response.expectedContentLength <= Int64(maxBytes) else {
            failure = URLError(.badServerResponse); completionHandler(.cancel); return
        }
        guard (200...299).contains(response.statusCode) else {
            failure = GIFHTTPError(statusCode: response.statusCode)
            completionHandler(.cancel); return
        }
        mimeType = response.mimeType
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maxBytes - received.count else {
            failure = URLError(.dataLengthExceedsMaximum)
            dataTask.cancel(); return
        }
        received.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { if !usesSharedTransport { session.finishTasksAndInvalidate() } }
        if let error = failure ?? error { completion(.failure(error)) }
        else if received.isEmpty { completion(.failure(URLError(.zeroByteResource))) }
        else { completion(.success(GIFPayload(data: received, mimeType: mimeType))) }
    }
}

enum GIFService: String, CaseIterable, Codable {
    // Retain retired providers for existing saved references, not new selections.
    case giphy, giphyClips, klipy, klipyStickers, klipyMemes, commons, finerGifs, favorites, recents
    static let availableServices: [GIFService] = [.giphy, .klipy, .klipyStickers, .klipyMemes, .commons, .favorites, .recents]
    var title: String { switch self { case .giphy: return "GIPHY GIFs"; case .giphyClips: return "GIPHY Clips"; case .klipy: return "Klipy"; case .klipyStickers: return "KLIPY Stickers"; case .klipyMemes: return "KLIPY Memes"; case .commons: return "Wikimedia Commons"; case .finerGifs: return "Finer Gifs Club"; case .favorites: return "Favorites"; case .recents: return "Recent" } }
    var icon: String { switch self { case .favorites: return "star.fill"; case .recents: return "clock.arrow.circlepath"; case .finerGifs: return "rectangle.stack.fill"; case .klipy: return "sparkles.rectangle.stack"; case .klipyStickers: return "face.smiling"; case .klipyMemes: return "text.bubble"; case .commons: return "globe"; default: return "photo.stack" } }
    static func from(_ raw: String?) -> GIFService? { guard let raw else { return nil }; return allCases.first { $0.title == raw || $0.rawValue == raw } }
    var switcherTitle: String {
        switch self {
        case .giphy: return "GIPHY"
        case .klipy: return "KLIPY"
        case .klipyStickers: return "Stickers"
        case .klipyMemes: return "Memes"
        case .commons: return "Commons"
        default: return title
        }
    }
    func nextProvider(backwards: Bool = false) -> GIFService {
        let choices = Self.availableServices
        guard let index = choices.firstIndex(of: self) else { return choices[0] }
        return choices[(index + (backwards ? choices.count - 1 : 1)) % choices.count]
    }
    var selectionTitle: String { self == .giphyClips ? "GIPHY Clips · Approval required" : title }
    var klipyCollection: String? {
        switch self {
        case .klipy: return "gifs"
        case .klipyStickers: return "stickers"
        case .klipyMemes: return "static-memes"
        default: return nil
        }
    }
    var isKlipy: Bool { klipyCollection != nil }
    var isLocal: Bool { self == .favorites || self == .recents }
    var apiKeyPortal: GIFAPIKeyPortal? {
        switch self {
        case .giphy, .giphyClips: return .giphy
        case .klipy, .klipyStickers, .klipyMemes: return .klipy
        case .commons, .finerGifs, .favorites, .recents: return nil
        }
    }
}

// Persist references, not stale provider media URLs or media bytes.
struct GIFBookmark: Codable {
    let id: String
    let title: String
    let provider: String
    init(_ item: GIFItem) { id = item.id; title = item.title; provider = item.provider }
    var stableID: String { provider + ":" + id }
}

final class GIFStore {
    static let shared = GIFStore()
    private let defaults: UserDefaults
    private let favKey = "BTTGIFSearchFavoritesV2"
    private let recentKey = "BTTGIFSearchRecentV2"
    private var favoriteData: Data?
    private var favoriteCache: [GIFBookmark] = []
    private var favoriteIDs = Set<String>()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func load(_ key: String) -> [GIFBookmark] {
        guard let data = defaults.data(forKey: key) else { return [] }
        if let legacy = try? JSONDecoder().decode([GIFItem].self, from: data) {
            let bookmarks = legacy.filter { $0.hasSafeURLs }.map(GIFBookmark.init)
            save(bookmarks, key) // Strip old cached URLs but preserve safe IDs/titles.
            return bookmarks
        }
        return (try? JSONDecoder().decode([GIFBookmark].self, from: data)) ?? []
    }
    private func save(_ items: [GIFBookmark], _ key: String) {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }
    func favorites() -> [GIFBookmark] {
        let data = defaults.data(forKey: favKey)
        if data != favoriteData {
            favoriteCache = load(favKey)
            favoriteData = defaults.data(forKey: favKey)
            favoriteIDs = Set(favoriteCache.map { $0.stableID })
        }
        return favoriteCache
    }
    func recents() -> [GIFBookmark] { load(recentKey) }
    func isFavorite(_ item: GIFItem) -> Bool { _ = favorites(); return favoriteIDs.contains(item.stableID) }
    func addRecent(_ item: GIFItem) {
        guard item.hasSafeURLs else { return }
        var items = recents().filter { $0.stableID != item.stableID }
        items.insert(GIFBookmark(item), at: 0); save(Array(items.prefix(80)), recentKey)
    }
    func toggleFavorite(_ item: GIFItem) -> Bool {
        guard item.hasSafeURLs else { return false }
        var items = favorites()
        if let index = items.firstIndex(where: { $0.stableID == item.stableID }) {
            items.remove(at: index); save(items, favKey); return false
        }
        items.insert(GIFBookmark(item), at: 0); save(Array(items.prefix(200)), favKey); return true
    }
}

final class GIFSearchViewModel: ObservableObject {
    @Published var sections: [GIFSection] = []; @Published var selectedFlatIndex = 0; @Published var isLoading = false
    @Published var message = "Loading…"; @Published var currentQuery: String; @Published var selectedService: GIFService; let resultLimit: Int
    var onRequestChromeUpdate: (() -> Void)?; private var requestSerial = 0
    @Published private(set) var columns = 5
    @Published private(set) var gridWidth: CGFloat = 930
    var cardWidth: CGFloat { max(1, (gridWidth - 56 - CGFloat(columns - 1) * 14) / CGFloat(columns)) }
    private let credentials: GIFCredentials
    private let clipboard: NSPasteboard
    private let store: GIFStore
    private let mediaLoader: (URL, @escaping (Result<GIFPayload, Error>) -> Void) -> Void
    private var searchTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    @Published var actionMessage = ""
    @Published var isPreparingMedia = false
    @Published var showPreview = false
    @Published var showHelp = false
    @Published var selectedCollection = "All"
    @Published var unavailable: [GIFBookmark] = []
    @Published var canLoadMore = false
    @Published var isLoadingMore = false
    var pageLoader: ((GIFService, String, Int, GIFCredentials, Int, Int) async -> GIFOutcome)?
    private var nextOffset = 0
    private var nextPage = 1
    private var operationSerial = 0
    var onInsertRequested: ((GIFItem) -> Void)?
    var onCancelRequested: (() -> Void)?
    @Published var previewRevision = 0
    var canAct: Bool { !isLoading && !isPreparingMedia && selectedMediaInfo != nil }
    func requestInsert() {
        guard canAct, let item = selectedItem() else { return }
        onInsertRequested?(item)
    }
    func cancelSearch() { requestSerial += 1; searchTask?.cancel(); connectionTask?.cancel(); isLoading = false; isLoadingMore = false }
    var collections: [String] { ["All"] + store.collections() }
    func collection(of item: GIFItem) -> String { store.collection(for: item.stableID) ?? "Unsorted" }
    func assignCollection(_ name: String, to item: GIFItem) {
        if !store.isFavorite(item) { _ = store.toggleFavorite(item) }
        store.assignCollection(name, to: item.stableID)
        actionMessage = "Saved to " + name
        objectWillChange.send()
        if selectedService == .favorites { selectedCollection = "All"; loadForCurrent() }
    }
    func newCollection() {
        guard let item = selectedItem() else { return }
        let alert = NSAlert(); alert.messageText = "Save to a collection"
        alert.informativeText = "Choose a short name. Existing collections are kept."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. Reactions"; alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "All", name.count <= 60 else { return }
        assignCollection(name, to: item)
    }

    init(initialQuery: String, service: GIFService, credentials: GIFCredentials = GIFCredentials(), resultLimit: Int? = nil, clipboard: NSPasteboard = .general, store: GIFStore = .shared,
         mediaLoader: @escaping (URL, @escaping (Result<GIFPayload, Error>) -> Void) -> Void = { url, completion in
             GIFNetwork.fetch(url, maxBytes: 32 * 1024 * 1024, completion: completion)
         }) { self.credentials = credentials; self.clipboard = clipboard; self.store = store; self.mediaLoader = mediaLoader; self.currentQuery = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines); self.selectedService = service; self.resultLimit = GIFResultLimit.from(resultLimit) ?? GIFResultLimit.legacyDefault }
    var hasSelectedProviderKey: Bool {
        switch selectedService.apiKeyPortal {
        case .giphy: return !credentials.giphy.isEmpty
        case .klipy: return !credentials.klipy.isEmpty
        case nil: return false
        }
    }
    var emptyStateTitle: String {
        if selectedService == .commons {
            return currentQuery.isEmpty ? "Search Wikimedia Commons" : "Wikimedia Commons"
        }
        if selectedService == .favorites { return "Your favorites" }
        if selectedService == .recents { return "Recently copied" }
        if let portal = selectedService.apiKeyPortal, !hasSelectedProviderKey { return "Connect \(portal.title)" }
        return "Nothing to show on \(selectedService.title)"
    }
    var emptyStateDescription: String {
        if selectedService == .commons && currentQuery.isEmpty {
            return "Type a topic in the search bar above to see GIF results in this section. Try orbit, physics, or animals. No API key or account needed."
        }
        if let portal = selectedService.apiKeyPortal, !hasSelectedProviderKey {
            return portal == .giphy
                ? "Add your GIPHY API key in Launcher Settings to search GIFs and load trending results."
                : "Add your KLIPY app key in Launcher Settings. One key works for GIFs, Stickers, and Memes."
        }
        return message
    }
    var gridRows: [GIFGridRow] {
        sections.flatMap { section in
            stride(from: 0, to: section.items.count, by: columns).map { offset in
                GIFGridRow(id: "\(section.id.uuidString):\(columns):\(offset)",
                    title: offset == 0 ? section.title : nil,
                    items: Array(section.items.dropFirst(offset).prefix(columns)))
            }
        }
    }
    var selectedScrollRowID: String? {
        guard let selected = selectedItem()?.stableID else { return nil }
        return gridRows.first { $0.items.contains { $0.stableID == selected } }?.id
    }
    func updateGridWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        // Fit at least 144pt cards, then distribute ALL remaining width across them.
        // Row grouping, keyboard navigation and rendered card sizes share this count.
        let newCount = max(1, Int((max(0, width - 56) + 14) / 158))
        if gridWidth != width { gridWidth = width }
        if columns != newCount { columns = newCount }
    }
    var shouldOfferAPIKeyCreation: Bool {
        guard selectedService.apiKeyPortal != nil else { return false }
        // An existing GIF key cannot gain Clips access by creating another key.
        return selectedService != .giphyClips || credentials.giphy.isEmpty
    }
    var placeholder: String {
        switch selectedService {
        case .favorites: return "Search favorites"
        case .recents: return "Search recent items"
        case .klipyStickers: return "Search stickers on KLIPY"
        case .klipyMemes: return "Search memes on KLIPY"
        case .commons: return "Search GIFs on Wikimedia Commons — no API key"
        default: return "Search for GIFs on \(selectedService.title)"
        }
    }
    var statusText: String { if isLoading { return "Loading \(selectedService.title)…" }; let c = allItems().count; return c == 0 ? message : "\(c) items • \(selectedService.title) • selected \(min(selectedFlatIndex+1,c))/\(c)" }
    func allItems() -> [GIFItem] { sections.flatMap { $0.items } }
    func refresh() { loadForCurrent() }
    func changeService(_ service: GIFService) { cancelPendingMediaForNavigation(); GIFPreferences.remember(service); selectedCollection = "All"; selectedService = service; sections = []; selectedFlatIndex = 0; loadForCurrent() }
    func cycleProvider(backwards: Bool = false) {
        changeService(selectedService.nextProvider(backwards: backwards))
    }
    func searchTextChanged(_ q: String) { let t = q.trimmingCharacters(in: .whitespacesAndNewlines); if t == currentQuery, !sections.isEmpty { return }; cancelPendingMediaForNavigation(); currentQuery = t; loadForCurrent() }
    func moveSelection(dx: Int, dy: Int) {
        let items = allItems()
        guard !items.isEmpty else { return }
        selectedFlatIndex = max(0, min(selectedFlatIndex, items.count - 1))
        if dy != 0 {
            let rows = gridRows
            let selected = items[selectedFlatIndex].stableID
            if let row = rows.firstIndex(where: { $0.items.contains { $0.stableID == selected } }),
               let column = rows[row].items.firstIndex(where: { $0.stableID == selected }) {
                let nextRow = rows[max(0, min(rows.count - 1, row + dy))]
                let target = nextRow.items[min(column, nextRow.items.count - 1)].stableID
                selectedFlatIndex = items.firstIndex { $0.stableID == target } ?? selectedFlatIndex
            }
        }
        selectedFlatIndex = max(0, min(items.count - 1, selectedFlatIndex + dx))
        onRequestChromeUpdate?()
    }
    func itemIsSelected(_ item: GIFItem) -> Bool { let items = allItems(); return selectedFlatIndex < items.count && items[selectedFlatIndex].stableID == item.stableID }
    func select(_ item: GIFItem) { if let i = allItems().firstIndex(where: { $0.stableID == item.stableID }) { selectedFlatIndex = i; onRequestChromeUpdate?() } }
    func isFavorite(_ item: GIFItem) -> Bool { store.isFavorite(item) }
    func toggleFavoriteSelected() { guard canAct else { return }; guard let item = selectedItem() else { return }; let added = store.toggleFavorite(item); message = added ? "Added to Favorites" : "Removed from Favorites"; actionMessage = message; if selectedCollection != "All" && !collections.contains(selectedCollection) { selectedCollection = "All" }; if selectedService == .favorites { loadForCurrent() } else { objectWillChange.send(); onRequestChromeUpdate?() } }
    var selectedMediaInfo: GIFItem? { selectedItem() }
    func copySelectedAttributionToPasteboard() {
        guard let item = selectedItem(), item.provider == GIFService.commons.title,
              item.hasSafeURLs, let source = item.sourceURL else { return }
        let text = "\(item.title) — \(item.artist ?? "See file page for creator") — \(item.licenseName ?? "Check file license")\n\(source.absoluteString)"
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }
    func copySelectedURLToPasteboard() {
        guard canAct, let item = selectedItem(), item.hasSafeURLs else { return }
        clipboard.clearContents()
        let source = item.sourceURL ?? item.originalURL
        clipboard.setString(source.absoluteString, forType: .string)
        clipboard.setString(source.absoluteString, forType: .URL)
        actionMessage = "Link copied"
        store.addRecent(item)
    }
    func copySelectedGIFToPasteboard(onMediaReady: ((Int) -> Void)? = nil) {
        guard canAct, let item = selectedItem() else { return }
        prepareMedia(item) { result in
            switch result {
            case .success(let count): self.actionMessage = "Media copied"; onMediaReady?(count)
            case .failure(let error): self.actionMessage = error.localizedDescription
            }
        }
    }
    func prepareMedia(_ item: GIFItem, completion: @escaping (Result<Int, Error>) -> Void) {
        guard !isPreparingMedia, item.hasSafeURLs else {
            completion(.failure(GIFOperationError("Another media operation is running."))); return
        }
        isPreparingMedia = true; actionMessage = "Preparing media…"
        operationSerial += 1; let serial = operationSerial
        let pb = clipboard; let url = item.downloadURL
        pb.clearContents(); pb.setString(url.absoluteString, forType: .string); pb.setString(url.absoluteString, forType: .URL)
        let expected = pb.changeCount
        mediaLoader(url) { result in
            DispatchQueue.main.async {
                guard serial == self.operationSerial else { return }
                self.isPreparingMedia = false
                guard pb.changeCount == expected else {
                    completion(.failure(GIFOperationError("Cancelled: clipboard changed."))); return
                }
                switch result {
                case .failure:
                    completion(.failure(GIFOperationError("Couldn’t load media. Its link is on the clipboard.")))
                case .success(let payload):
                    guard let type = GIFNetwork.clipboardType(payload.data) else {
                        completion(.failure(GIFOperationError("Unsupported media. Its link is on the clipboard."))); return
                    }
                    pb.clearContents(); pb.setData(payload.data, forType: type)
                    pb.setString(url.absoluteString, forType: .string); pb.setString(url.absoluteString, forType: .URL)
                    self.store.addRecent(item)
                    completion(.success(pb.changeCount))
                }
            }
        }
    }
    func cancelMedia() { operationSerial += 1; isPreparingMedia = false }
    private func cancelPendingMediaForNavigation() {
        if isPreparingMedia { onCancelRequested?(); cancelMedia() }
    }
    private func selectedItem() -> GIFItem? { guard !isLoading else { return nil }; let items = allItems(); return selectedFlatIndex >= 0 && selectedFlatIndex < items.count ? items[selectedFlatIndex] : nil }
    private func loadForCurrent() {
        let query = currentQuery; let service = selectedService; let limit = resultLimit; requestSerial += 1; let serial = requestSerial
        searchTask?.cancel(); connectionTask?.cancel()
        isLoadingMore = false; canLoadMore = false; nextOffset = 0; nextPage = 1
        unavailable = []; actionMessage = ""
        if service.isLocal {
            let allSaved = service == .favorites ? store.favorites() : store.recents()
            let base = selectedCollection == "All" || service != .favorites ? allSaved :
                allSaved.filter { store.collection(for: $0.stableID) == selectedCollection }
            let saved = query.isEmpty ? base : base.filter {
                $0.title.localizedCaseInsensitiveContains(query) || $0.provider.localizedCaseInsensitiveContains(query)
            }
            sections = []; selectedFlatIndex = 0
            guard !saved.isEmpty else {
                isLoading = false
                if base.isEmpty {
                    message = service == .favorites ? "No favorites yet. Select a GIF and press ⌘F." : "No recent copies yet."
                } else {
                    message = "No \(service.title.lowercased()) match “\(query)”. Clear the search field to see all saved items."
                }
                onRequestChromeUpdate?(); return
            }
            unavailable = saved
            isLoading = true; message = "Refreshing saved items from their providers…"
            onRequestChromeUpdate?()
            let keys = credentials
            searchTask = Task { [weak self] in
                guard let self else { return }
                let outcome = await GIFSearchViewModel.requestBookmarks(saved, credentials: keys)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.requestSerial == serial else { return }
                    self.isLoading = false; self.sections = outcome.sections
                    let restored = Set(outcome.sections.flatMap { $0.items }.map { $0.stableID })
                    self.unavailable = saved.filter { !restored.contains($0.stableID) }
                    self.message = outcome.message; self.onRequestChromeUpdate?()
                }
            }
            return
        }
        sections = []; selectedFlatIndex = 0
        isLoading = true; message = query.isEmpty ? "Loading trending from \(service.title)…" : "Searching \(service.title) for “\(query)”…"; onRequestChromeUpdate?()
        let keys = credentials
        searchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            let outcome = await self.initialPage(service: service, query: query, limit: limit, credentials: keys)
            await MainActor.run {
                guard serial == self.requestSerial else { return }
                self.isLoading = false
                self.sections = outcome.items.isEmpty ? [] : [GIFSection(title: query.isEmpty ? "Trending • \(service.title)" : "Results • \(service.title)", items: outcome.items)]
                self.selectedFlatIndex = 0; self.message = outcome.message
                self.nextOffset = outcome.nextOffset; self.nextPage = outcome.nextPage
                self.canLoadMore = outcome.hasMore
                self.onRequestChromeUpdate?()
            }
        }
    }

    private static func requestBookmarks(_ bookmarks: [GIFBookmark], credentials: GIFCredentials) async -> (sections: [GIFSection], message: String) {
        var sections: [GIFSection] = []
        var warnings: [String] = []
        for service in [GIFService.giphy, .giphyClips, .klipy, .klipyStickers, .klipyMemes, .commons, .finerGifs] {
            let saved = bookmarks.filter { $0.provider == service.title }
            guard !saved.isEmpty else { continue }
            var items: [GIFItem] = []
            if service == .commons {
                for offset in stride(from: 0, to: saved.count, by: 20) {
                    guard !Task.isCancelled else { return ([], "Cancelled") }
                    let ids = Array(saved.dropFirst(offset).prefix(20)).map { $0.id }
                    guard let url = commonsURL(query: nil, ids: ids) else { continue }
                    do {
                        let root = try await getJSON(url)
                        items += commonsItems(root)
                    } catch { warnings.append("Wikimedia Commons saved items could not be refreshed. Retry later.") }
                }
            } else if service == .finerGifs {
                items = saved.compactMap { mapFiner(["fields": ["fileid": $0.id, "text": $0.title]]) }
            } else {
                let key = service.isKlipy ? credentials.klipy : credentials.giphy
                guard !key.isEmpty else { warnings.append("Set your \(service.title) key to refresh saved items."); continue }
                let safe = saved.filter { validIdentifier($0.id) }
                let batchSize = service.isKlipy ? 50 : 100
                for offset in stride(from: 0, to: safe.count, by: batchSize) {
                    guard !Task.isCancelled else { return ([], "Cancelled") }
                    let batch = Array(safe.dropFirst(offset).prefix(batchSize))
                    guard let url = bookmarkURL(service: service, ids: batch.map { $0.id }, key: key) else { continue }
                    do {
                        guard let root = try await getJSON(url) as? [String: Any] else { throw URLError(.cannotParseResponse) }
                        let data: [[String: Any]]
                        if service.isKlipy {
                            guard root["result"] as? Bool == true,
                                  let envelope = root["data"] as? [String: Any],
                                  let rows = envelope["data"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
                            data = rows
                        } else {
                            guard let rows = root["data"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
                            data = rows
                        }
                        items += data.compactMap { service.isKlipy ? mapKlipy($0, service: service) : mapGiphy($0, clips: service == .giphyClips) }
                    } catch { warnings.append("\(service.title) saved items unavailable; check key, access, quota, and connection.") }
                }
            }
            let ordered = restoreBookmarkOrder(saved, items: items)
            if ordered.count < saved.count {
                warnings.append("\(saved.count - ordered.count) \(service.title) saved item(s) could not be refreshed. Your saved references are kept.")
            }
            if !ordered.isEmpty {
                let attribution = service == .giphy || service == .giphyClips ? " • Powered By GIPHY" : service.isKlipy ? " • Powered by KLIPY" : ""
                sections.append(GIFSection(title: service.title + attribution, items: ordered))
            }
        }
        return (sections, warnings.isEmpty ? (sections.isEmpty ? "Could not refresh saved items. They are still saved; retry or check provider access." : "Ready") : warnings.joined(separator: " "))
    }

    private static func restoreBookmarkOrder(_ bookmarks: [GIFBookmark], items: [GIFItem]) -> [GIFItem] {
        var exact: [String: GIFItem] = [:]
        for item in items { exact[item.stableID] = item }
        return bookmarks.compactMap { bookmark in
            if let item = exact[bookmark.stableID] { return item }
            // KLIPY search slugs may include a --suffix, while /items returns the
            // canonical slug. Accept only a unique provider-matched prefix, and
            // retain the original saved identity so favorite toggling still works.
            guard GIFService.from(bookmark.provider)?.isKlipy == true else { return nil }
            let matches = items.filter {
                $0.provider == bookmark.provider && bookmark.id.hasPrefix($0.id + "--")
            }
            guard matches.count == 1, let item = matches.first else { return nil }
            return GIFItem(id: bookmark.id, title: item.title, provider: item.provider,
                           previewURL: item.previewURL, originalURL: item.originalURL, downloadURL: item.downloadURL)
        }
    }

    private static func validIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func bookmarkURL(service: GIFService, ids: [String], key: String) -> URL? {
        guard !ids.isEmpty, ids.allSatisfy(validIdentifier) else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        if let collection = service.klipyCollection {
            guard validIdentifier(key) else { return nil }
            c.host = "api.klipy.com"; c.path = "/api/v1/\(key)/\(collection)/items"
            c.queryItems = [URLQueryItem(name: "slugs", value: ids.joined(separator: ","))]
        } else if service == .giphy || service == .giphyClips {
            c.host = "api.giphy.com"; c.path = service == .giphy ? "/v1/gifs" : "/v1/content"
            c.queryItems = [URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        } else { return nil }
        return c.url
    }

    private static func request(service: GIFService, query: String, limit: Int, credentials: GIFCredentials) async -> GIFOutcome {
        switch service {
        case .giphy, .giphyClips:
            guard !credentials.giphy.isEmpty else {
                return GIFOutcome(items: [], message: "Enter your GIPHY API key in GIF Search’s BTT settings. GIFs and Clips share this field; Clips also requires GIPHY approval.")
            }
            return await requestGiphy(query: query, clips: service == .giphyClips, limit: limit, key: credentials.giphy)
        case .klipy, .klipyStickers, .klipyMemes:
            guard !credentials.klipy.isEmpty else {
                return GIFOutcome(items: [], message: "Enter your KLIPY app key in this plugin’s BTT settings.")
            }
            return await requestKlipy(query: query, limit: limit, key: credentials.klipy, service: service)
        case .commons: return await requestCommons(query: query, limit: limit)
        case .finerGifs: return await requestFiner(query: query, limit: limit)
        case .favorites, .recents: return GIFOutcome(items: [], message: "Local")
        }
    }

    private static func getJSON(_ url: URL) async throws -> Any {
        let payload = try await GIFNetwork.data(url, maxBytes: 2 * 1024 * 1024)
        return try JSONSerialization.jsonObject(with: payload.data)
    }

    private static func giphyURL(query: String, clips: Bool, limit: Int, key: String, offset: Int = 0) -> URL? {
        var c = URLComponents()
        c.scheme = "https"; c.host = "api.giphy.com"
        c.path = "/v1/\(clips ? "clips" : "gifs")/\(query.isEmpty ? "trending" : "search")"
        c.queryItems = [URLQueryItem(name: "api_key", value: key),
                        URLQueryItem(name: "limit", value: String(min(50, max(1, limit)))),
                        URLQueryItem(name: "offset", value: String(max(0, offset)))]
        if !query.isEmpty { c.queryItems?.append(URLQueryItem(name: "q", value: query)) }
        return c.url
    }

    private static func requestGiphy(query: String, clips: Bool, limit: Int, key: String, offset: Int = 0) async -> GIFOutcome {
        guard let url = giphyURL(query: query, clips: clips, limit: limit, key: key, offset: offset) else {
            return GIFOutcome(items: [], message: "Invalid GIPHY configuration")
        }
        do {
            guard let root = try await getJSON(url) as? [String: Any],
                  let data = root["data"] as? [[String: Any]] else {
                return GIFOutcome(items: [], message: "Bad GIPHY response")
            }
            let next = offset + data.count
            let total = (root["pagination"] as? [String: Any])?["total_count"] as? Int
            let maximum = query.isEmpty ? 499 : 4999
            let more = !data.isEmpty && next <= maximum && (total.map { next < $0 } ?? (data.count >= min(50, limit)))
            return GIFOutcome(items: data.compactMap { mapGiphy($0, clips: clips) }, message: data.isEmpty ? "No more GIPHY results" : "Ready", hasMore: more, nextOffset: next)
        } catch {
            return GIFOutcome(items: [], message: giphyFailureMessage(error, clips: clips))
        }
    }

    private static func giphyFailureMessage(_ error: Error, clips: Bool) -> String {
        let provider = clips ? "GIPHY Clips" : "GIPHY"
        if let http = error as? GIFHTTPError {
            switch http.statusCode {
            case 401:
                return "\(provider) could not authenticate your API key (HTTP 401). Check the GIPHY key in GIF Search’s BTT settings."
            case 403:
                return clips
                    ? "GIPHY Clips access was denied (HTTP 403). Request Clips approval from GIPHY, or use GIPHY GIFs. Creating another key does not automatically enable Clips."
                    : "GIPHY access was denied (HTTP 403). Check your key’s permissions and account status."
            case 429:
                return "\(provider)’s rate limit was reached (HTTP 429). Wait before retrying; creating another key is not the solution."
            case 500...599:
                return "\(provider)’s server is unavailable (HTTP \(http.statusCode)). Please retry later."
            default:
                return "\(provider) returned HTTP \(http.statusCode). Please retry later or check your provider account."
            }
        }
        if let network = error as? URLError {
            if network.code == .cannotParseResponse {
                return "\(provider) returned an unreadable response. Please retry later."
            }
            return "Could not connect to \(provider). Check your connection and retry. This does not confirm an approval problem."
        }
        return "\(provider)’s response could not be read. Please retry later."
    }

    private static func mapGiphy(_ d: [String: Any], clips: Bool) -> GIFItem? {
        guard let id = d["id"] as? String, !id.isEmpty,
              let images = d["images"] as? [String: Any],
              let original = images["original"] as? [String: Any],
              let gifURL = GIFNetwork.httpsURL(original["url"] as? String) else { return nil }
        let title = d["title"] as? String ?? d["slug"] as? String ?? "GIF"
        let previewString = ((images["preview_gif"] as? [String: Any])?["url"] as? String)
            ?? ((images["fixed_height"] as? [String: Any])?["url"] as? String)
            ?? gifURL.absoluteString
        var downloadURL = gifURL
        if clips {
            guard let video = d["video"] as? [String: Any],
                  let assets = video["assets"] as? [String: Any],
                  let small = assets["360p"] as? [String: Any],
                  let clip = GIFNetwork.httpsURL(small["url"] as? String) else { return nil }
            downloadURL = clip
        }
        guard let previewURL = GIFNetwork.httpsURL(previewString) else { return nil }
        return GIFItem(id: id, title: title, provider: clips ? GIFService.giphyClips.title : GIFService.giphy.title,
                       previewURL: previewURL, originalURL: gifURL, downloadURL: downloadURL)
    }

    private static func klipyURL(query: String, limit: Int, key: String, service: GIFService = .klipy, page: Int = 1) -> URL? {
        guard let collection = service.klipyCollection else { return nil }
        // Keys are one path segment, never a caller-controlled URL.
        guard !key.isEmpty, key.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        var c = URLComponents()
        c.scheme = "https"; c.host = "api.klipy.com"
        c.path = "/api/v1/\(key)/\(collection)/\(query.isEmpty ? "trending" : "search")"
        c.queryItems = [URLQueryItem(name: "page", value: String(max(1, page))),
                        URLQueryItem(name: "per_page", value: String(min(50, max(8, limit))))]
        if service == .klipy {
            c.queryItems?.append(URLQueryItem(name: "format_filter", value: "gif"))
        }
        if !query.isEmpty { c.queryItems?.append(URLQueryItem(name: "q", value: query)) }
        return c.url
    }

    private static func requestKlipy(query: String, limit: Int, key: String, service: GIFService = .klipy, page: Int = 1) async -> GIFOutcome {
        guard let url = klipyURL(query: query, limit: limit, key: key, service: service, page: page) else {
            return GIFOutcome(items: [], message: "Invalid KLIPY app key. Check this plugin’s BTT settings.")
        }
        do {
            guard let root = try await getJSON(url) as? [String: Any], root["result"] as? Bool == true,
                  let envelope = root["data"] as? [String: Any],
                  let data = envelope["data"] as? [[String: Any]] else {
                return GIFOutcome(items: [], message: "Bad KLIPY response")
            }
            return GIFOutcome(items: data.compactMap { mapKlipy($0, service: service) }, message: data.isEmpty ? "No more \(service.title) results" : "Ready", hasMore: data.count >= min(50, max(8, limit)), nextPage: page + 1)
        } catch {
            return GIFOutcome(items: [], message: providerFailure(error, provider: service.title))
        }
    }

    private static func mapKlipy(_ d: [String: Any], service: GIFService = .klipy) -> GIFItem? {
        guard service.isKlipy, let slug = d["slug"] as? String, !slug.isEmpty,
              let file = d["file"] as? [String: Any] else { return nil }
        let formats = service == .klipyMemes ? ["png"] : service == .klipyStickers ? ["gif", "png"] : ["gif"]
        func rendition(_ sizes: [String]) -> URL? {
            // Prefer the GIF representation at any size before falling back to a still PNG.
            for format in formats {
                for size in sizes {
                    if let renditions = file[size] as? [String: Any],
                       let data = renditions[format] as? [String: Any],
                       let url = GIFNetwork.httpsURL(data["url"] as? String) { return url }
                }
            }
            return nil
        }
        guard let full = rendition(["hd", "md", "sm", "xs"]) else { return nil }
        let preview = rendition(["xs", "sm", "md", "hd"]) ?? full
        return GIFItem(id: slug, title: d["title"] as? String ?? service.switcherTitle,
                       provider: service.title, previewURL: preview, originalURL: full, downloadURL: full)
    }

    private static func commonsURL(query: String?, ids: [String] = [], limit: Int = 24) -> URL? {
        var c = URLComponents()
        c.scheme = "https"; c.host = "commons.wikimedia.org"; c.path = "/w/api.php"
        c.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|mime|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "320"),
            URLQueryItem(name: "iiextmetadatafilter", value: "Artist|LicenseShortName|LicenseUrl")]
        if !ids.isEmpty {
            guard ids.count <= 20, ids.allSatisfy({ id in
                !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) } && (Int64(id) ?? 0) > 0
            }) else { return nil }
            c.queryItems?.append(URLQueryItem(name: "pageids", value: ids.joined(separator: "|")))
        } else {
            guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            c.queryItems? += [
                URLQueryItem(name: "generator", value: "search"),
                URLQueryItem(name: "gsrsearch", value: "(\(query)) filemime:image/gif"),
                URLQueryItem(name: "gsrnamespace", value: "6"),
                URLQueryItem(name: "gsrlimit", value: String(min(50, max(1, limit))))]
        }
        return c.url
    }

    private static func commonsItems(_ root: Any) -> [GIFItem] {
        guard let root = root as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]] else { return [] }
        return pages.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }.compactMap(mapCommons)
    }

    private static func plainMetadata(_ value: Any?) -> String? {
        guard let text = (value as? [String: Any])?["value"] as? String else { return nil }
        let stripped = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : String(stripped.prefix(500))
    }

    private static func mapCommons(_ page: [String: Any]) -> GIFItem? {
        guard let pageID = page["pageid"] as? Int, pageID > 0,
              let title = page["title"] as? String, title.hasPrefix("File:"),
              let info = (page["imageinfo"] as? [[String: Any]])?.first,
              info["mime"] as? String == "image/gif",
              let full = GIFNetwork.httpsURL(info["url"] as? String),
              ["upload.wikimedia.org", "thumb.wikimedia.org"].contains(full.host?.lowercased() ?? ""),
              let source = GIFNetwork.httpsURL(info["descriptionurl"] as? String),
              source.host?.lowercased() == "commons.wikimedia.org" else { return nil }
        let candidate = GIFNetwork.httpsURL(info["thumburl"] as? String)
        let preview = candidate.flatMap {
            ["upload.wikimedia.org", "thumb.wikimedia.org"].contains($0.host?.lowercased() ?? "") ? $0 : nil
        } ?? full
        let metadata = info["extmetadata"] as? [String: Any] ?? [:]
        return GIFItem(id: String(pageID), title: String(title.dropFirst(5)),
            provider: GIFService.commons.title, previewURL: preview, originalURL: full, downloadURL: full,
            sourceURL: source, licenseName: plainMetadata(metadata["LicenseShortName"]),
            artist: plainMetadata(metadata["Artist"]))
    }

    private static func requestCommons(query: String, limit: Int) async -> GIFOutcome {
        guard let url = commonsURL(query: query, limit: limit) else {
            return GIFOutcome(items: [], message: "Search Wikimedia Commons for educational GIFs, diagrams, and animations. No API key is needed.")
        }
        do {
            let root = try await getJSON(url)
            let items = commonsItems(root)
            return GIFOutcome(items: items, message: "No Commons GIFs matched. Try a topic such as orbit, physics, or animals.")
        } catch {
            if let http = error as? GIFHTTPError {
                return GIFOutcome(items: [], message: "Wikimedia Commons is unavailable (HTTP \(http.statusCode)). Retry later; no API key is required.")
            }
            return GIFOutcome(items: [], message: "Could not reach Wikimedia Commons. Check your connection and retry; no API key is required.")
        }
    }

    private static func requestFiner(query: String, limit: Int) async -> GIFOutcome {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GIFOutcome(items: [], message: "Finer Gifs Club needs a search term.")
        }
        var c = URLComponents()
        c.scheme = "https"; c.host = "api.thefinergifs.club"; c.path = "/search"
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "q.parser", value: "simple"),
                        URLQueryItem(name: "sort", value: "_score desc"), URLQueryItem(name: "size", value: String(limit))]
        do {
            guard let url = c.url, let root = try await getJSON(url) as? [String: Any],
                  let data = root["results"] as? [[String: Any]] else { return GIFOutcome(items: [], message: "Bad Finer Gifs response") }
            return GIFOutcome(items: data.compactMap(mapFiner), message: "No Finer Gifs Club results")
        } catch {
            return GIFOutcome(items: [], message: finerFailureMessage(error))
        }
    }

    private static func finerFailureMessage(_ error: Error) -> String {
        if let http = error as? GIFHTTPError {
            if (500...599).contains(http.statusCode) {
                return "Finer Gifs Club’s server is unavailable (HTTP \(http.statusCode)). Retry later or choose GIPHY / Klipy. Those providers need your own key in BTT settings."
            }
            return "Finer Gifs Club rejected the request (HTTP \(http.statusCode)). Retry later or choose another provider."
        }
        return "Could not reach Finer Gifs Club. Check your connection, retry, or choose another provider."
    }

    private static func mapFiner(_ d: [String: Any]) -> GIFItem? {
        guard let fields = d["fields"] as? [String: Any], let id = fields["fileid"] as? String,
              !id.isEmpty, id.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              }),
              let url = GIFNetwork.httpsURL("https://media.thefinergifs.club/\(id).gif") else { return nil }
        return GIFItem(id: id, title: fields["text"] as? String ?? fields["name"] as? String ?? "GIF",
                       provider: GIFService.finerGifs.title, previewURL: url, originalURL: url, downloadURL: url)
    }

}

struct GIFOutcome { let items: [GIFItem]; let message: String; var hasMore = false; var nextOffset = 0; var nextPage = 1 }
struct GIFGridRow: Identifiable { let id: String; let title: String?; let items: [GIFItem] }
struct GIFSection: Identifiable { let id = UUID(); let title: String; var items: [GIFItem] }
struct GIFItem: Identifiable, Hashable, Codable { let id: String; let title: String; let provider: String; let previewURL: URL; let originalURL: URL; let downloadURL: URL; var sourceURL: URL? = nil; var licenseName: String? = nil; var artist: String? = nil; var stableID: String { provider + ":" + id }
    var hasSafeURLs: Bool { ([previewURL, originalURL, downloadURL] + (sourceURL.map { [$0] } ?? [])).allSatisfy { GIFNetwork.httpsURL($0.absoluteString) != nil } }
}

enum GIFClipsAccess {
    // No API key is put into the email draft, URL, or clipboard.
    static var requestURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"; components.path = "clips@giphy.com"
        components.queryItems = [URLQueryItem(name: "subject", value: "GIPHY Clips API access request")]
        return components.url
    }
}

enum GIFAPIKeyPortal: CaseIterable {
    case giphy, klipy
    var title: String { self == .giphy ? "GIPHY" : "KLIPY" }
    var actionTitle: String { self == .giphy ? "Create API key" : "Create app key" }
    static func ordered(for service: GIFService) -> [GIFAPIKeyPortal] {
        guard let selected = service.apiKeyPortal else { return allCases }
        return [selected] + allCases.filter { $0 != selected }
    }
    var destination: URL? {
        URL(string: self == .giphy
            ? "https://developers.giphy.com/dashboard/"
            : "https://partner.klipy.com/")
    }
}

struct GIFSearchRootView: View {
    @ObservedObject var model: GIFSearchViewModel
    @GIFViewState private var rowFrames: [String: CGRect] = [:]
    @AppStorage("GIFSearchRememberProvider") private var rememberProvider = false
    @AppStorage("GIFSearchAnimatePreviews") private var animatePreviews = true
    var body: some View {
        VStack(spacing: 0) {
            topBar
            collectionBar
            commonsAttribution
            feedback
            grid
            actionBar
        }
        .sheet(isPresented: $model.showPreview) { GIFQuickPreview(model: model) }
        .sheet(isPresented: $model.showHelp) { GIFShortcutHelp() }
    }
    private var topBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(GIFService.availableServices, id: \.self) { service in
                    Button {
                        model.changeService(service)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: service.icon)
                                .font(.system(size: 12, weight: .medium))
                            Text(service.switcherTitle)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(model.selectedService == service ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .background {
                            if model.selectedService == service {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.22))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(Color.accentColor.opacity(0.42), lineWidth: 1)
                                    }
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .help("\(service.title) — Tab next, Shift-Tab previous")
                    .accessibilityLabel(service.title)
                    .accessibilityValue(model.selectedService == service ? "Selected" : "Not selected")
                }
            }
            .padding(4)
            .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(1)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.14), value: model.selectedService)

                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
            if model.selectedService == .giphy || model.selectedService == .giphyClips {
                Text("Powered By GIPHY").font(.caption).foregroundStyle(.secondary).fixedSize()
            } else if model.selectedService.isKlipy {
                Text("Powered by KLIPY").font(.caption).foregroundStyle(.secondary).fixedSize()
            } else if model.selectedService == .commons {
                Text("Wikimedia Commons · No API key").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
    @ViewBuilder private var commonsAttribution: some View {
        if let item = model.selectedMediaInfo,
           item.provider == GIFService.commons.title, let source = item.sourceURL {
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("\(item.licenseName ?? "Check file license") · \(item.artist ?? "Creator listed on file page")")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(item.artist ?? "") — \(item.licenseName ?? "See file page for reuse terms")")
                Spacer(minLength: 0)
                Link("File & license", destination: source).font(.caption)
                Button("Copy attribution") { model.copySelectedAttributionToPasteboard() }
                    .font(.caption).buttonStyle(.borderless)
            }
            .padding(.horizontal, 28).padding(.bottom, 8)
        }
    }
    @ViewBuilder private var collectionBar: some View {
        if model.selectedService == .favorites {
            HStack {
                Picker("Collection", selection: $model.selectedCollection) {
                    ForEach(model.collections, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 250)
                .onChange(of: model.selectedCollection) { _ in model.refresh() }
                Spacer()
                Text("\(model.allItems().count) available · \(model.unavailable.count) unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 28).padding(.bottom, 8)
        }
    }
    @ViewBuilder private var feedback: some View {
        if !model.actionMessage.isEmpty || (!model.isLoading && !model.sections.isEmpty && model.message != "Ready") {
            HStack(spacing: 8) {
                if model.isPreparingMedia { ProgressView().controlSize(.small) }
                else { Image(systemName: "info.circle").foregroundStyle(.secondary) }
                Text(!model.actionMessage.isEmpty ? model.actionMessage : model.message)
                    .font(.caption).lineLimit(3).accessibilityLabel("Status")
                Spacer(minLength: 4)
                if model.isPreparingMedia {
                    Button("Cancel") { model.onCancelRequested?(); model.cancelMedia() }.buttonStyle(.borderless)
                }
            }
            .padding(10).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 28).padding(.bottom, 6)
        }
    }
    private var grid: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    if model.isLoading {
                        loading.frame(maxWidth: .infinity, minHeight: max(160, geometry.size.height - 24))
                    } else if model.sections.isEmpty && model.unavailable.isEmpty {
                        emptyView.frame(maxWidth: .infinity, minHeight: max(260, geometry.size.height - 24))
                    } else {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(model.gridRows) { row in
                                gridRow(row)
                                    .id(row.id)
                                    .background(GeometryReader { frame in
                                        Color.clear.preference(key: GIFRowFrames.self,
                                                               value: [row.id: frame.frame(in: .named("gifViewport"))])
                                    })
                            }
                            if !model.unavailable.isEmpty { unavailableItems }
                            if model.canLoadMore {
                                HStack {
                                    Spacer()
                                    Button { model.loadMore() } label: {
                                        if model.isLoadingMore { ProgressView().controlSize(.small) }
                                        else { Label("Load more", systemImage: "plus.circle") }
                                    }.disabled(model.isLoadingMore || model.isPreparingMedia)
                                    Spacer()
                                }.padding(.vertical, 10)
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 12)
                        .id("gifResultsTop")
                    }
                }
                .coordinateSpace(name: "gifViewport")
                .onPreferenceChange(GIFRowFrames.self) { rowFrames = $0 }
                .task(id: model.selectedScrollRowID) {
                    do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                    guard !Task.isCancelled, let rowID = model.selectedScrollRowID else { return }
                    if rowID == model.gridRows.first?.id {
                        proxy.scrollTo("gifResultsTop", anchor: .top)
                        return
                    }
                    if let frame = rowFrames[rowID] {
                        guard frame.minY < 0 || frame.maxY > geometry.size.height else { return }
                        proxy.scrollTo(rowID, anchor: frame.minY < 0 ? .top : .bottom)
                    } else { proxy.scrollTo(rowID, anchor: .center) }
                }
            }
            .onAppear { model.updateGridWidth(geometry.size.width) }
            .onChange(of: geometry.size.width) { width in model.updateGridWidth(width) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func gridRow(_ row: GIFGridRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = row.title { Text(title).font(.headline).foregroundStyle(.secondary) }
            HStack(alignment: .top, spacing: 14) {
                ForEach(row.items, id: \.stableID) { item in
                    GIFCard(item: item, selected: model.itemIsSelected(item), favorite: model.isFavorite(item),
                            width: model.cardWidth, onFavorite: { model.select(item); model.toggleFavoriteSelected() })
                        .id(item.stableID + ":\(model.previewRevision)")
                        .onTapGesture { model.select(item) }
                        .contextMenu {
                            Button("Insert") { model.select(item); model.requestInsert() }
                            Button("Copy media") { model.select(item); model.copySelectedGIFToPasteboard() }
                            Button(model.isFavorite(item) ? "Remove from favorites" : "Add to favorites") {
                                model.select(item); model.toggleFavoriteSelected()
                            }
                            Divider()
                            Button("Preview") { model.select(item); model.showPreview = true }
                            Button("Copy link") { model.select(item); model.copySelectedURLToPasteboard() }
                            Button("Save to collection…") { model.select(item); model.newCollection() }
                        }
                }
                Spacer(minLength: 0)
            }
        }
    }
    private var unavailableItems: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Saved but unavailable", systemImage: "icloud.slash").font(.headline)
                Spacer()
                Button("Retry") { model.refresh() }.disabled(model.isLoading)
            }
            Text("These references are still saved. Check your provider key or try again later.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.unavailable, id: \.stableID) { item in
                HStack(spacing: 10) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text(item.provider).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                }.padding(10).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button { model.requestInsert() } label: { Label("Insert ↵", systemImage: "arrow.down.doc") }
                    .buttonStyle(.borderedProminent).disabled(!model.canAct)
                Button("Copy ⌘C") { model.copySelectedGIFToPasteboard() }.disabled(!model.canAct)
                Button {
                    model.toggleFavoriteSelected()
                } label: {
                    Label("Favorite ⌘F", systemImage: model.selectedMediaInfo.map { model.isFavorite($0) } == true ? "star.fill" : "star")
                }.disabled(!model.canAct)
                Spacer(minLength: 0)
                Menu {
                    Button("Preview · ⌥Space") { model.showPreview = model.canAct }.disabled(!model.canAct)
                    Button("Copy link · ⌘⇧C") { model.copySelectedURLToPasteboard() }.disabled(!model.canAct)
                    if let item = model.selectedMediaInfo {
                        Button("Open source page") { NSWorkspace.shared.open(item.sourceURL ?? item.originalURL) }
                        Menu("Save to collection") {
                            ForEach(model.collections.filter { $0 != "All" }, id: \.self) { name in
                                Button(name) { model.assignCollection(name, to: item) }
                            }
                            Button("New collection…") { model.newCollection() }
                        }.disabled(!model.canAct)
                        if item.provider == GIFService.commons.title {
                            Button("Copy attribution") { model.copySelectedAttributionToPasteboard() }
                        }
                    }
                    Divider()
                    if model.selectedService.apiKeyPortal != nil {
                        Button("Test provider connection") { model.testConnection() }.disabled(!model.hasSelectedProviderKey || model.isLoading)
                    }
                    Button("Retry previews") { GIFPreviewRepository.shared.clear(); model.previewRevision += 1 }
                    Toggle("Animate previews", isOn: $animatePreviews)
                    Toggle("Remember last provider", isOn: $rememberProvider)
                    Divider()
                    Button("Export favorites…") { model.exportFavorites() }
                    Button("Import favorites…") { model.importFavorites() }
                    Button("Keyboard shortcuts") { model.showHelp = true }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("More actions")
            }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 11)
        }
    }
    private var loading: some View { VStack(spacing: 10) { ProgressView(); Text(model.message).foregroundStyle(.secondary) }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
    private var emptyView: some View {
        VStack(spacing: 18) {
            Image(systemName: model.selectedService.icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(width: 66, height: 66)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))

            VStack(spacing: 9) {
                Text(model.emptyStateTitle).font(.title2.weight(.semibold))
                Text(model.emptyStateDescription)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 510)

            if model.selectedService == .commons && model.currentQuery.isEmpty {
                Label("Search above to get started", systemImage: "arrow.up")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 12) {
                if let portal = model.selectedService.apiKeyPortal,
                   let destination = portal.destination {
                    Link(destination: destination) {
                        Label(model.hasSelectedProviderKey
                              ? "Manage \(portal.title) key"
                              : "Get \(portal.title) \(portal == .giphy ? "API key" : "app key")",
                              systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Opens only \(portal.title)’s key dashboard")
                }
                if (model.selectedService.apiKeyPortal != nil && model.hasSelectedProviderKey) || (model.selectedService == .commons && !model.currentQuery.isEmpty) {
                    Button { model.refresh() } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if model.selectedService.apiKeyPortal != nil {
                VStack(spacing: 6) {
                    Label("Launcher Settings → GIF Search → API Keys",
                          systemImage: "slider.horizontal.3")
                        .font(.callout.weight(.medium))
                    Text("Paste your key in the provider’s field there, not in the launcher search bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            } else if model.selectedService == .favorites {
                Text("Save an item with Command-F. Your saved items are kept if a provider is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if model.selectedService == .recents {
                Text("Items appear here after you insert with Return or copy with Command-C.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Tab: next provider   ·   Shift-Tab: previous")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
    }
}

struct GIFCard: View {
    let item: GIFItem
    let selected: Bool
    let favorite: Bool
    var width: CGFloat = 160
    var onFavorite: () -> Void = {}
    @GIFViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                AnimatedGIFPreview(url: item.previewURL)
                    .frame(width: width, height: width * 0.75)
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3))
                    .shadow(color: selected ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.08),
                            radius: selected ? 8 : 3, x: 0, y: 2)
                Button(action: onFavorite) {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .foregroundStyle(favorite ? Color.yellow : Color.primary)
                        .padding(7).background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain).padding(5)
                .opacity(favorite || hovering || selected ? 1 : 0.3)
                .help(favorite ? "Remove from favorites" : "Add to favorites")
                .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
            Text(item.title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .lineLimit(1).frame(width: width, alignment: .leading)
            Text(item.provider)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: width, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering ? Color.primary.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .help(item.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title + ", " + item.provider + (selected ? ", selected" : ""))
        .accessibilityAction(named: "Toggle favorite", onFavorite)
    }
}

struct AnimatedGIFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = true
        imageView.canDrawSubviewsIntoLayer = true
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        context.coordinator.load(url: url, into: imageView)
        return imageView
    }

    func updateNSView(_ imageView: NSImageView, context: Context) {
        imageView.animates = true
        context.coordinator.load(url: url, into: imageView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var currentURL: URL?
        private var subscription: (URL, UUID)?
        private weak var imageView: NSImageView?
        private var visibilityTimer: Timer?
        func load(url: URL, into view: NSImageView) {
            imageView = view
            if visibilityTimer == nil {
                visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.updatePlayback() }
            }
            updatePlayback()
            guard currentURL != url else { return }
            if let subscription { GIFPreviewRepository.shared.cancel(subscription) }
            currentURL = url
            view.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Loading preview")
            view.toolTip = "Loading preview…"
            subscription = GIFPreviewRepository.shared.load(url) { [weak self, weak view] result in
                guard let self, let view, self.currentURL == url else { return }
                switch result {
                case .success(let data):
                    guard let image = NSImage(data: data) else {
                        self.showFailure(view); return
                    }
                    view.image = image; view.toolTip = nil
                    view.setAccessibilityLabel("Media preview")
                    self.updatePlayback()
                case .failure: self.showFailure(view)
                }
            }
        }
        private func showFailure(_ view: NSImageView) {
            view.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Preview unavailable")
            view.toolTip = "Preview unavailable. Use Retry previews in the actions menu."
            view.setAccessibilityLabel("Preview unavailable")
        }
        private func updatePlayback() {
            guard let view = imageView else { return }
            let enabled = UserDefaults.standard.object(forKey: "GIFSearchAnimatePreviews") as? Bool ?? true
            view.animates = enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion &&
                view.window?.isVisible == true && !view.visibleRect.isEmpty
        }
        deinit {
            visibilityTimer?.invalidate()
            if let subscription { GIFPreviewRepository.shared.cancel(subscription) }
        }
    }
}

// MARK: - Preferences, saved collections and safe insertion
struct GIFOperationError: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
enum GIFPreferences {
    static var defaults: UserDefaults = .standard
    static var rememberLast: Bool {
        get { defaults.bool(forKey: "GIFSearchRememberProvider") }
        set { defaults.set(newValue, forKey: "GIFSearchRememberProvider") }
    }
    static func remember(_ service: GIFService) {
        defaults.set(service.rawValue, forKey: "GIFSearchLastProvider")
    }
    static func startingService(defaultService: GIFService) -> GIFService {
        guard rememberLast, let raw = defaults.string(forKey: "GIFSearchLastProvider"),
              let service = GIFService(rawValue: raw), GIFService.availableServices.contains(service) else { return defaultService }
        return service
    }
}
extension GIFStore {
    private var collectionMap: [String: String] { defaults.dictionary(forKey: "GIFSearchCollectionsV1") as? [String: String] ?? [:] }
    func collection(for id: String) -> String? { collectionMap[id] }
    func collections() -> [String] {
        let active = Set(favorites().map { $0.stableID })
        return Array(Set(collectionMap.filter { active.contains($0.key) }.map { $0.value })).sorted()
    }
    func assignCollection(_ name: String, to id: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, clean != "All",
              favorites().contains(where: { $0.stableID == id }) else { return }
        var map = collectionMap; map[id] = clean
        defaults.set(map, forKey: "GIFSearchCollectionsV1")
    }
}
struct GIFDestination {
    let pid: pid_t
    let window: AXUIElement?
    static func current() -> GIFDestination? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return capture(pid: app.processIdentifier)
    }
    static func capture(pid: pid_t) -> GIFDestination {
        var value: CFTypeRef?
        let app = AXUIElementCreateApplication(pid)
        let status = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
        let window = status == .success && value.map { CFGetTypeID($0) == AXUIElementGetTypeID() } == true
            ? (value as! AXUIElement) : nil
        return GIFDestination(pid: pid, window: window)
    }
    func matches(_ other: GIFDestination) -> Bool {
        guard pid == other.pid, let window, let otherWindow = other.window else { return false }
        return CFEqual(window, otherWindow)
    }
}
final class GIFDestinationTracker {
    static let shared = GIFDestinationTracker()
    private(set) var previous: GIFDestination?
    private var observers: [NSObjectProtocol] = []
    private init() {
        previous = GIFDestination.current()
        let center = NSWorkspace.shared.notificationCenter
        // Capture the outgoing application's focused window, not an arbitrary app after a delay.
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let captured = GIFDestination.capture(pid: app.processIdentifier)
            self?.previous = Self.resolve(pid: app.processIdentifier, captured: captured, previous: self?.previous)
        })
    }
    // The plugin may be loaded after BTT has already taken focus, so workspace history alone is insufficient.
    // BTT's context identifies the app from which the launcher was opened.
    func destination(for bundleIdentifier: String?) -> GIFDestination? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard apps.count == 1, let app = apps.first else { return nil }
        return Self.resolve(pid: app.processIdentifier,
                            captured: GIFDestination.capture(pid: app.processIdentifier), previous: previous)
    }
    static func resolve(pid: pid_t?, captured: GIFDestination?, previous: GIFDestination?) -> GIFDestination? {
        guard let pid, pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        if let captured, captured.pid == pid, captured.window != nil { return captured }
        if let previous, previous.pid == pid, previous.window != nil { return previous }
        return nil
    }
    deinit { observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
}
struct GIFPasteEnvironment {
    var trusted: () -> Bool = { AXIsProcessTrusted() }
    var expected: () -> GIFDestination? = { GIFDestinationTracker.shared.previous }
    var current: () -> GIFDestination? = { GIFDestination.current() }
    var clipboardCount: () -> Int = { NSPasteboard.general.changeCount }
    var paste: () -> Bool = {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
    var notify: (String) -> Void = { GIFToast.show($0) }
}
final class GIFInsertionCoordinator {
    private(set) var isClosingForPaste = false
    private var busy = false
    private var serial = 0
    private var waitTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var environment: GIFPasteEnvironment
    init(environment: GIFPasteEnvironment = GIFPasteEnvironment()) { self.environment = environment }
    func begin(item: GIFItem, model: GIFSearchViewModel, close: @escaping () -> Void) {
        guard !busy, !model.isPreparingMedia else { return }
        guard environment.trusted() else {
            model.actionMessage = "Enable BetterTouchTool in System Settings → Privacy & Security → Accessibility."
            return
        }
        guard let target = environment.expected(), target.window != nil else {
            model.actionMessage = "Open GIF Search again from the app and window where you want to paste."
            return
        }
        busy = true; serial += 1; let token = serial
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self, weak model] note in
            guard let self, let model,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier != ProcessInfo.processInfo.processIdentifier && app.processIdentifier != target.pid {
                self.cancel(model: model)
                self.environment.notify("Insert cancelled: destination changed.")
            }
        }
        // Download while the Launcher is visible. The selected item is captured, not re-read later.
        model.prepareMedia(item) { [self, weak model] result in
            guard let model, token == self.serial else { return }
            switch result {
            case .failure(let error):
                self.finish(); model.actionMessage = error.localizedDescription
            case .success(let changeCount):
                self.isClosingForPaste = true
                model.actionMessage = "Restoring destination…"; close()
                self.waitTask = Task { @MainActor [self, model] in
                    for _ in 0..<40 {
                        guard !Task.isCancelled, token == self.serial else { return }
                        guard self.environment.clipboardCount() == changeCount else {
                            self.fail("Insert cancelled: clipboard changed.", model: model); return
                        }
                        if let current = self.environment.current() {
                            guard target.matches(current) else {
                                self.fail("Insert cancelled: destination window changed. Media remains copied.", model: model); return
                            }
                            // Recheck focus on a second turn before emitting keyboard events.
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            guard !Task.isCancelled, token == self.serial else { return }
                            guard self.environment.clipboardCount() == changeCount,
                                  let final = self.environment.current(), target.matches(final) else {
                                self.fail("Insert cancelled: focus or clipboard changed.", model: model); return
                            }
                            let sent = self.environment.paste()
                            self.finish()
                            model.actionMessage = sent ? "Paste requested" : "Couldn’t send paste. Media remains copied."
                            if !sent { self.environment.notify(model.actionMessage) }
                            return
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    self.fail("Destination did not regain focus. Media remains copied.", model: model)
                }
            }
        }
    }
    func cancel(model: GIFSearchViewModel) {
        serial += 1; waitTask?.cancel(); model.cancelMedia()
        finish(); model.actionMessage = "Insert cancelled"
    }
    private func fail(_ text: String, model: GIFSearchViewModel) {
        finish(); model.actionMessage = text; environment.notify(text)
    }
    private func finish() {
        busy = false; isClosingForPaste = false
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        activationObserver = nil
    }
    deinit {
        waitTask?.cancel()
        if let observer = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
enum GIFToast {
    private static var panel: NSPanel?
    static func show(_ message: String) {
        panel?.orderOut(nil)
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: Text(message).font(.callout).multilineTextAlignment(.center)
            .padding(18).frame(width: 400, height: 80).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)))
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 200, y: screen.visibleFrame.maxY - 130))
        }
        panel = window; window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            window.orderOut(nil); if panel === window { panel = nil }
        }
    }
}

// MARK: - Explicit paging (never switches providers)
extension GIFSearchViewModel {
    private static func providerFailure(_ error: Error, provider: String) -> String {
        if let http = error as? GIFHTTPError {
            switch http.statusCode {
            case 401: return "\(provider) could not authenticate your key. Check it in Launcher Settings."
            case 403: return "\(provider) denied access. Check your account and content permissions."
            case 429: return "\(provider) rate limit reached. Wait before retrying."
            case 500...599: return "\(provider) is temporarily unavailable. Retry later."
            default: return "\(provider) request failed (HTTP \(http.statusCode))."
            }
        }
        return "Could not reach \(provider). Check your connection and retry."
    }
    private static func requestPage(service: GIFService, query: String, limit: Int, credentials: GIFCredentials,
                                    offset: Int = 0, page: Int = 1) async -> GIFOutcome {
        if service == .giphy && !credentials.giphy.isEmpty {
            return await requestGiphy(query: query, clips: false, limit: limit, key: credentials.giphy, offset: offset)
        }
        if service.isKlipy && !credentials.klipy.isEmpty {
            return await requestKlipy(query: query, limit: limit, key: credentials.klipy, service: service, page: page)
        }
        return await request(service: service, query: query, limit: limit, credentials: credentials)
    }
    private func initialPage(service: GIFService, query: String, limit: Int, credentials: GIFCredentials) async -> GIFOutcome {
        guard let loader = pageLoader else {
            return await Self.requestInitial(service: service, query: query, limit: limit, credentials: credentials)
        }
        let first = await loader(service, query, min(50, limit), credentials, 0, 1)
        guard limit > 50, first.hasMore, !Task.isCancelled else { return first }
        let second = await loader(service, query, min(50, limit), credentials, first.nextOffset, first.nextPage)
        return Self.combinePages(first, second)
    }
    private static func combinePages(_ first: GIFOutcome, _ second: GIFOutcome) -> GIFOutcome {
        var seen = Set(first.items.map { $0.stableID })
        let added = second.items.filter { seen.insert($0.stableID).inserted }
        guard !second.items.isEmpty else {
            return GIFOutcome(items: first.items, message: second.message,
                hasMore: !second.message.hasPrefix("No more") && first.hasMore,
                nextOffset: first.nextOffset, nextPage: first.nextPage)
        }
        return GIFOutcome(items: first.items + added, message: second.message,
            hasMore: second.hasMore && !added.isEmpty, nextOffset: second.nextOffset, nextPage: second.nextPage)
    }
    private static func requestInitial(service: GIFService, query: String, limit: Int, credentials: GIFCredentials) async -> GIFOutcome {
        let first = await requestPage(service: service, query: query, limit: min(50, limit), credentials: credentials)
        guard limit > 50, first.hasMore, !Task.isCancelled else { return first }
        let second = await requestPage(service: service, query: query, limit: min(50, limit), credentials: credentials,
                                       offset: first.nextOffset, page: first.nextPage)
        return combinePages(first, second)
    }

    func loadMore() {
        guard canLoadMore, !isLoading, !isLoadingMore, !isPreparingMedia else { return }
        isLoadingMore = true
        let serial = requestSerial; let service = selectedService; let query = currentQuery
        let offset = nextOffset; let page = nextPage; let keys = credentials; let limit = min(50, resultLimit)
        searchTask = Task { [weak self] in
            guard let self else { return }
            let result: GIFOutcome
            if let loader = self.pageLoader { result = await loader(service, query, limit, keys, offset, page) }
            else { result = await Self.requestPage(service: service, query: query, limit: limit, credentials: keys, offset: offset, page: page) }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard serial == self.requestSerial else { return }
                self.isLoadingMore = false
                var ids = Set(self.allItems().map { $0.stableID })
                let added = result.items.filter { ids.insert($0.stableID).inserted }
                if !added.isEmpty, !self.sections.isEmpty {
                    self.sections[0].items += added
                    self.nextOffset = result.nextOffset; self.nextPage = result.nextPage
                    self.canLoadMore = result.hasMore
                } else if result.message.hasPrefix("No more") || !result.items.isEmpty {
                    self.canLoadMore = false
                }
                self.actionMessage = added.isEmpty ? result.message : "Loaded \(added.count) more items"
                self.onRequestChromeUpdate?()
            }
        }
    }
    func testConnection() {
        guard selectedService.apiKeyPortal != nil, hasSelectedProviderKey, !isLoading else { return }
        actionMessage = "Testing \(selectedService.title)…"
        let service = selectedService; let serial = requestSerial; let keys = credentials
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.request(service: service, query: "", limit: 8, credentials: keys)
            await MainActor.run {
                guard serial == self.requestSerial else { return }
                self.actionMessage = outcome.items.isEmpty ? outcome.message : "\(service.title) connection works"
            }
        }
    }
}

// MARK: - Shared ephemeral network transport and cooperative cancellation
final class GIFRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ value: URLSessionTask?) {
        lock.lock(); task = value; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { value?.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = task; lock.unlock()
        value?.cancel()
    }
}
final class GIFTransport: NSObject, URLSessionDataDelegate {
    static let shared = GIFTransport()
    private let lock = NSLock()
    private var loaders: [Int: GIFNetwork] = [:]
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration; super.init() }
    private lazy var session: URLSession = {
        let config = configuration
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()
    func start(_ request: URLRequest, loader: GIFNetwork) -> URLSessionDataTask {
        lock.lock()
        let task = session.dataTask(with: request)
        loaders[task.taskIdentifier] = loader
        lock.unlock()
        task.resume(); return task
    }
    func invalidate() { session.invalidateAndCancel() }
    private func loader(_ task: URLSessionTask) -> GIFNetwork? {
        lock.lock(); defer { lock.unlock() }; return loaders[task.taskIdentifier]
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let loader = loader(task) else { completionHandler(nil); return }
        loader.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let loader = loader(dataTask) else { completionHandler(.cancel); return }
        loader.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        loader(dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let value = loaders.removeValue(forKey: task.taskIdentifier); lock.unlock()
        value?.urlSession(session, task: task, didCompleteWithError: error)
    }
}
final class GIFPreviewRepository {
    static let shared = GIFPreviewRepository()
    private let cache = NSCache<NSURL, NSData>()
    private struct Pending {
        let generation: UUID
        var callbacks: [UUID: (Result<Data, Error>) -> Void]
        var task: URLSessionDataTask?
    }
    private var pending: [URL: Pending] = [:]
    private let fetcher: (URL, @escaping (Result<GIFPayload, Error>) -> Void) -> URLSessionDataTask?
    init(fetcher: @escaping (URL, @escaping (Result<GIFPayload, Error>) -> Void) -> URLSessionDataTask? = {
        GIFNetwork.fetch($0, maxBytes: 8 * 1024 * 1024, completion: $1)
    }) {
        self.fetcher = fetcher; cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 48
    }
    @discardableResult
    func load(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) -> (URL, UUID) {
        let id = UUID()
        if let bytes = cache.object(forKey: url as NSURL) {
            completion(.success(bytes as Data)); return (url, id)
        }
        if pending[url] != nil {
            pending[url]?.callbacks[id] = completion; return (url, id)
        }
        pending[url] = Pending(generation: id, callbacks: [id: completion], task: nil)
        let task = fetcher(url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.pending[url]?.generation == id,
                      let request = self.pending.removeValue(forKey: url) else { return }
                let mapped = result.map { $0.data }
                if case .success(let data) = mapped, NSImage(data: data) != nil {
                    self.cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
                }
                request.callbacks.values.forEach { $0(mapped) }
            }
        }
        pending[url]?.task = task
        return (url, id)
    }
    func cancel(_ subscription: (URL, UUID)) {
        let (url, id) = subscription
        pending[url]?.callbacks.removeValue(forKey: id)
        if pending[url]?.callbacks.isEmpty == true {
            let task = pending.removeValue(forKey: url)?.task; task?.cancel()
        }
    }
    func clear() { cache.removeAllObjects() }
}

struct GIFRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
struct GIFQuickPreview: View {
    @ObservedObject var model: GIFSearchViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preview").font(.title2.weight(.semibold))
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let item = model.selectedMediaInfo {
                AnimatedGIFPreview(url: item.previewURL)
                    .frame(maxWidth: .infinity).frame(height: 330)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                Text(item.title).font(.headline).textSelection(.enabled)
                Text(item.provider + " · " + item.downloadURL.pathExtension.uppercased()).font(.caption).foregroundStyle(.secondary)
                if item.provider == GIFService.commons.title {
                    Text("\(item.artist ?? "See file page for creator") · \(item.licenseName ?? "Check file license")")
                        .font(.caption).textSelection(.enabled)
                }
                HStack {
                    Link("Open source", destination: item.sourceURL ?? item.originalURL)
                    Spacer()
                    Button("Copy media") { model.copySelectedGIFToPasteboard() }.disabled(!model.canAct)
                    Button(model.isFavorite(item) ? "Remove favorite" : "Add favorite") { model.toggleFavoriteSelected() }
                }
                if !model.actionMessage.isEmpty { Text(model.actionMessage).font(.caption) }
            }
        }.padding(22).frame(width: 610)
    }
}
struct GIFShortcutHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GIF Search shortcuts").font(.title2.weight(.semibold))
            Text("Return / Enter — Insert selected media\n⌘C — Copy media\n⌘F — Toggle favorite\n⌘⇧C — Copy link and close\n⌥Space — Large preview\nArrow keys — Select a result\nTab / ⇧Tab — Next / previous provider\n? — Show this help")
                .font(.body).lineSpacing(7)
            Text("Plain Space stays available for typing searches. Insertion requires Accessibility access and a known destination window. Media paste support depends on the destination app.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 440)
    }
}

// MARK: - User-initiated reference-only backup/restore (never exports API keys)
struct GIFFavoritesArchive: Codable {
    var schemaVersion = 1
    let favorites: [GIFBookmark]
    let collections: [String: String]
}
extension GIFStore {
    func archive() -> GIFFavoritesArchive {
        let saved = favorites()
        let ids = Set(saved.map { $0.stableID })
        return GIFFavoritesArchive(favorites: saved, collections: collectionMap.filter { ids.contains($0.key) })
    }
    static func validBookmark(_ bookmark: GIFBookmark) -> Bool {
        guard let service = GIFService.from(bookmark.provider), !service.isLocal,
              !bookmark.id.isEmpty, bookmark.id.count <= 240, bookmark.title.count <= 1000 else { return false }
        if service == .commons {
            return bookmark.id.utf8.allSatisfy { (48...57).contains($0) } && (Int64(bookmark.id) ?? 0) > 0
        }
        return bookmark.id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    func merge(_ archive: GIFFavoritesArchive) throws -> Int {
        guard archive.schemaVersion == 1, archive.favorites.count <= 200,
              archive.favorites.allSatisfy(Self.validBookmark),
              archive.collections.count <= 200,
              archive.collections.values.allSatisfy({ !$0.isEmpty && $0.count <= 60 && $0 != "All" }) else {
            throw GIFOperationError("Invalid favorites file. Nothing was imported.")
        }
        var saved = favorites(); var ids = Set(saved.map { $0.stableID }); var count = 0
        for bookmark in archive.favorites where !ids.contains(bookmark.stableID) {
            guard saved.count < 200 else { break }
            saved.append(bookmark); ids.insert(bookmark.stableID); count += 1
        }
        save(saved, favKey)
        var map = collectionMap
        for (id, name) in archive.collections where ids.contains(id) && map[id] == nil { map[id] = name }
        defaults.set(map, forKey: "GIFSearchCollectionsV1")
        return count
    }
}
extension GIFSearchViewModel {
    func exportFavorites() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "GIF-Search-Favorites.json"
        panel.title = "Export favorite references"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(store.archive()).write(to: url, options: .atomic)
            actionMessage = "Favorites exported. No API keys or media files included."
        } catch { actionMessage = "Couldn’t export favorites." }
    }
    func importFavorites() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.title = "Import favorite references"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 1024 * 1024 else { throw GIFOperationError("Favorites file is too large.") }
            let archive = try JSONDecoder().decode(GIFFavoritesArchive.self, from: Data(contentsOf: url))
            let alert = NSAlert(); alert.messageText = "Import favorites?"
            alert.informativeText = "Merge up to \(archive.favorites.count) references without replacing existing favorites. The total limit is 200. No media is downloaded until a provider refresh is requested."
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let added = try store.merge(archive)
            actionMessage = "Imported \(added) favorites. Open Favorites to refresh."
            objectWillChange.send()
        } catch { actionMessage = "Couldn’t import: invalid or unreadable favorites file." }
    }
}
