// BTT-Plugin-Name: News Search
// BTT-Plugin-Identifier: com.bttuserplugin.newssearch
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: newspaper.fill
// BTT-AI-Managed: true

import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Persistence

private enum NewsPrefs {
    static let showImagesKey = "com.bttuserplugin.newssearch.showImages"
    static var showImages: Bool {
        get { UserDefaults.standard.bool(forKey: showImagesKey) }
        set { UserDefaults.standard.set(newValue, forKey: showImagesKey) }
    }
}

private enum NewsSurfaceSize {
    static let widthKey  = "com.bttuserplugin.newssearch.surfaceWidth"
    static let heightKey = "com.bttuserplugin.newssearch.surfaceHeight"

    static let defaultSize  = CGSize(width: 820, height: 600)
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

class NewsSearchPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    static func launcherPluginName() -> String { "News Search" }
    static func launcherPluginDescription() -> String { "Search top news articles from the launcher." }
    static func launcherPluginIcon() -> String { "newspaper.fill" }

    // MARK: - Top-level launcher result
    //
    // Shows "Search news for \"<query>\"" once the user starts typing.
    // Activating it opens the rich SwiftUI surface (Jira-style) that
    // renders the article list with optional thumbnails.

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let query = context.query?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !query.isEmpty else { return nil }

        let r = BTTLauncherPluginResult()
        // Embed the query in the identifier so the surface factory can pick it up.
        r.itemIdentifier    = "news-search:\(query)"
        r.title             = "Search news for \"\(query)\""
        r.subtitle          = "Fetch top news articles from the web"
        r.systemImageName   = "newspaper.fill"
        r.trailingHint      = "News"
        r.surfaceIdentifier = "news-main"
        r.keywords          = ["news", "headlines", query]
        return [r]
    }

    // MARK: - Surface factory

    func launcherSurface(forItemIdentifier itemIdentifier: String,
                         surfaceIdentifier: String?,
                         context: BTTLauncherPluginContext) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard surfaceIdentifier == "news-main" else { return nil }
        // Pull the initial query out of the identifier or fall back to the
        // launcher's live query.
        let prefix = "news-search:"
        let initialQuery: String
        if itemIdentifier.hasPrefix(prefix) {
            initialQuery = String(itemIdentifier.dropFirst(prefix.count))
        } else {
            initialQuery = context.query?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        return NewsMainSurface(initialQuery: initialQuery)
    }

    func launcherResultSelected(_ result: BTTLauncherPluginResult,
                                context: BTTLauncherPluginContext) {
        // No-op; surface handles its own actions.
    }
}

// MARK: - Article model

struct NewsArticleItem: Identifiable, Hashable {
    let id: String           // stable id derived from URL
    let title: String
    let snippet: String
    let url: String
    let sourceName: String
    let publishedAt: Date?

    static func ==(lhs: NewsArticleItem, rhs: NewsArticleItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - View model

final class NewsViewModel: ObservableObject {
    @Published var query: String
    @Published private(set) var articles: [NewsArticleItem] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String? = nil
    @Published var selectedArticleId: String? = nil

    /// Per-article image URL cache (populated lazily when "Show images" is on).
    @Published private(set) var imageURLs: [String: URL] = [:]

    @Published var showImages: Bool {
        didSet {
            guard oldValue != showImages else { return }
            NewsPrefs.showImages = showImages
            // Refresh feed so the user immediately sees / hides thumbnails.
            performSearch(force: true)
        }
    }

    var onAfterOpen: (() -> Void)?

    private var debounceTask: DispatchWorkItem?
    private var inflightToken: UUID = UUID()

    init(initialQuery: String) {
        self.query = initialQuery
        self.showImages = NewsPrefs.showImages
        if !initialQuery.isEmpty {
            // First load happens after init() completes (so onAfterOpen etc.
            // can be wired up first).
            DispatchQueue.main.async { [weak self] in
                self?.performSearch(force: true)
            }
        }
    }

    // MARK: External hooks

    /// Called by the surface whenever the launcher's external search field changes.
    /// When `fromLauncher` is true, an empty incoming query is ignored — BTT clears
    /// its search field as the surface opens, and we want to keep the query we
    /// were seeded with from the launcher prompt.
    func updateQuery(_ q: String, fromLauncher: Bool = false) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if fromLauncher && trimmed.isEmpty { return }
        guard trimmed != query else { return }
        query = trimmed
        debouncedSearch()
    }

    func openSelected() {
        guard let id = selectedArticleId,
              let article = articles.first(where: { $0.id == id }) else { return }
        open(article)
    }

    func open(_ article: NewsArticleItem) {
        guard let url = URL(string: article.url) else { return }
        NSWorkspace.shared.open(url)
        onAfterOpen?()
    }

    func navigateUp() {
        guard !articles.isEmpty else { return }
        if let id = selectedArticleId, let idx = articles.firstIndex(where: { $0.id == id }) {
            selectedArticleId = articles[max(0, idx - 1)].id
        } else {
            selectedArticleId = articles.last?.id
        }
    }

    func navigateDown() {
        guard !articles.isEmpty else { return }
        if let id = selectedArticleId, let idx = articles.firstIndex(where: { $0.id == id }) {
            selectedArticleId = articles[min(articles.count - 1, idx + 1)].id
        } else {
            selectedArticleId = articles.first?.id
        }
    }

    // MARK: Search

    private func debouncedSearch() {
        debounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.performSearch(force: false) }
        debounceTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    func performSearch(force: Bool) {
        let q = query
        guard !q.isEmpty else {
            articles = []
            errorMessage = nil
            isLoading = false
            selectedArticleId = nil
            imageURLs = [:]
            return
        }

        let token = UUID()
        inflightToken = token
        isLoading = true
        errorMessage = nil

        GoogleNewsRSSFetcher.fetch(query: q, max: 25) { [weak self] articles, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.inflightToken == token else { return }   // stale response
                self.isLoading = false
                if let error {
                    self.errorMessage = error
                    self.articles = []
                    self.imageURLs = [:]
                    self.selectedArticleId = nil
                    return
                }
                self.articles = articles
                self.selectedArticleId = articles.first?.id
                self.imageURLs = [:]
                if self.showImages {
                    self.populateImageURLs(for: articles)
                }
            }
        }
    }

    private func populateImageURLs(for articles: [NewsArticleItem]) {
        var dict: [String: URL] = [:]
        for article in articles {
            let (primary, _) = SourceLogoResolver.imageURLs(for: article.sourceName)
            if let primary { dict[article.id] = primary }
        }
        imageURLs = dict
    }
}

// MARK: - Surface

final class NewsMainSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?

    private let vm: NewsViewModel

    init(initialQuery: String) {
        self.vm = NewsViewModel(initialQuery: initialQuery)
    }

    func makeLauncherSurfaceView() -> NSView {
        vm.onAfterOpen = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.requestLauncherSurfaceClose()
            }
        }

        let hosting = FocusableNewsHostingView(rootView: NewsMainView(vm: vm))
        hosting.onMoveUp        = { [weak vm = vm] in DispatchQueue.main.async { vm?.navigateUp() } }
        hosting.onMoveDown      = { [weak vm = vm] in DispatchQueue.main.async { vm?.navigateDown() } }
        hosting.onSelectCurrent = { [weak vm = vm] in DispatchQueue.main.async { vm?.openSelected() } }
        hosting.onSizeChanged   = { size in NewsSurfaceSize.save(size) }
        return hosting
    }

    func launcherSurfacePreferredContentSize() -> CGSize { NewsSurfaceSize.load() }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }
    func launcherSurfacePlaceholderText() -> String? { "Search news…" }
    func launcherSurfaceFooterHint() -> String? { "↑/↓ Navigate  ·  Return Open  ·  Esc Back" }

    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return true }
        switch event.keyCode {
        case 125, 126, 36, 76, 123, 124: return false   // ↓ ↑ Return Enter ← →
        default: return true
        }
    }

    func launcherSurfaceQueryDidChange(_ query: String?) {
        let q = query ?? ""
        DispatchQueue.main.async { [weak vm = vm] in vm?.updateQuery(q, fromLauncher: true) }
    }

    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand)
        -> BTTLauncherPluginSurfaceCommandResult?
    {
        let result = BTTLauncherPluginSurfaceCommandResult()
        switch command {
        case .moveUp:
            DispatchQueue.main.async { [weak vm = vm] in vm?.navigateUp() }
            result.handled = true
            return result
        case .moveDown:
            DispatchQueue.main.async { [weak vm = vm] in vm?.navigateDown() }
            result.handled = true
            return result
        default:
            return nil
        }
    }

    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 36 || event.keyCode == 76 {
            DispatchQueue.main.async { [weak vm = vm] in vm?.openSelected() }
            return true
        }
        return false
    }
}

// MARK: - Focus-aware hosting view (mirrors Jira's pattern)

private final class FocusableNewsHostingView<Root: View>: NSHostingView<Root> {
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?
    var onSelectCurrent: (() -> Void)?
    var onSizeChanged: ((CGSize) -> Void)?
    private var eventMonitor: Any?
    private var resizeObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
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
            switch event.keyCode {
            case 125: self.onMoveDown?();      return nil
            case 126: self.onMoveUp?();        return nil
            case 36, 76: self.onSelectCurrent?(); return nil
            default:
                if let fr = self.window?.firstResponder, fr is NSTextView { return event }
                if self.redirectTypedCharacterToLauncherSearch(event) { return nil }
                return event
            }
        }
    }

    private func redirectTypedCharacterToLauncherSearch(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) { return false }
        guard let chars = event.charactersIgnoringModifiers,
              !chars.isEmpty,
              let scalar = chars.unicodeScalars.first,
              CharacterSet.alphanumerics.union(.punctuationCharacters)
                  .union(.symbols).union(.whitespaces).contains(scalar)
        else { return false }
        guard let window, let searchField = findSearchField(in: window.contentView) else { return false }
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.insertText(event.characters ?? chars)
        } else {
            searchField.stringValue.append(event.characters ?? chars)
        }
        return true
    }

    private func findSearchField(in root: NSView?) -> NSTextField? {
        guard let root else { return nil }
        if root === self { return nil }
        if let tf = root as? NSTextField, tf.isEditable, !tf.isHidden, !contains(view: tf) { return tf }
        for sub in root.subviews {
            if sub === self { continue }
            if let f = findSearchField(in: sub) { return f }
        }
        return nil
    }

    private func contains(view: NSView) -> Bool {
        var v: NSView? = view
        while let c = v {
            if c === self { return true }
            v = c.superview
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
        if let t = resizeObserver { NotificationCenter.default.removeObserver(t) }
        resizeObserver = nil
    }

    deinit { removeMonitor(); removeResizeObserver() }
}

// MARK: - SwiftUI views

struct NewsMainView: View {
    @ObservedObject var vm: NewsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "newspaper.fill")
                .foregroundColor(.accentColor)
            Text("News")
                .font(.system(size: 14, weight: .semibold))

            if !vm.query.isEmpty {
                Text("·").foregroundColor(.secondary)
                Text("\u{201C}\(vm.query)\u{201D}")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 12)

            if vm.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle(isOn: $vm.showImages) {
                HStack(spacing: 4) {
                    Image(systemName: vm.showImages ? "photo.fill" : "photo")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Images")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Show article thumbnails")
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.query.isEmpty {
            placeholder(icon: "magnifyingglass",
                        title: "Start typing to search",
                        subtitle: "Use the launcher search box to look up top news.")
        } else if let err = vm.errorMessage, vm.articles.isEmpty {
            placeholder(icon: "exclamationmark.triangle.fill",
                        title: "Failed to load news",
                        subtitle: err)
        } else if vm.articles.isEmpty && !vm.isLoading {
            placeholder(icon: "newspaper",
                        title: "No results",
                        subtitle: "Try a different search term.")
        } else {
            articleList
        }
    }

    private var articleList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(Array(vm.articles.enumerated()), id: \.element.id) { idx, article in
                        NewsRowView(
                            article: article,
                            index: idx,
                            imageURL: vm.showImages ? vm.imageURLs[article.id] : nil,
                            showImage: vm.showImages,
                            isSelected: vm.selectedArticleId == article.id
                        ) {
                            vm.selectedArticleId = article.id
                            vm.open(article)
                        }
                        .id(article.id)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: vm.selectedArticleId) { newID in
                if let id = newID {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(.secondary.opacity(0.6))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

struct NewsRowView: View {
    let article: NewsArticleItem
    let index: Int
    let imageURL: URL?
    let showImage: Bool
    let isSelected: Bool
    let onOpen: () -> Void

    @State private var hovered = false

    private var accent: Color {
        // Subtle hue rotation for visual variety across rows.
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green]
        return palette[index % palette.count]
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail

                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !article.snippet.isEmpty {
                        Text(article.snippet)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 6) {
                        if !article.sourceName.isEmpty {
                            Text(article.sourceName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(accent.opacity(0.15))
                                )
                        }
                        if let published = article.publishedAt {
                            Text(Self.relativeFormatter.localizedString(for: published, relativeTo: Date()))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
    }

    private var rowFill: Color {
        if isSelected { return accent.opacity(0.14) }
        if hovered    { return Color.primary.opacity(0.06) }
        return Color.clear
    }

    @ViewBuilder
    private var thumbnail: some View {
        if showImage {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(accent.opacity(0.12))
                if let imageURL {
                    LogoImage(
                        primary: imageURL,
                        fallback: SourceLogoResolver.imageURLs(for: article.sourceName).fallback,
                        accent: accent
                    )
                    .frame(width: 64, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "newspaper")
                        .font(.system(size: 18))
                        .foregroundColor(accent.opacity(0.8))
                }
            }
            .frame(width: 64, height: 48)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(accent.opacity(0.18))
                .frame(width: 3)
                .padding(.vertical, 2)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// AsyncImage that tries a primary URL and on failure swaps to a fallback.
private struct LogoImage: View {
    let primary: URL
    let fallback: URL?
    let accent: Color

    @State private var primaryFailed = false

    var body: some View {
        AsyncImage(url: primaryFailed ? fallback : primary) { phase in
            switch phase {
            case .empty:
                ProgressView().controlSize(.small)
            case .success(let image):
                image.resizable().scaledToFit().padding(6)
            case .failure:
                if !primaryFailed, fallback != nil {
                    ProgressView()
                        .controlSize(.small)
                        .onAppear { primaryFailed = true }
                } else {
                    Image(systemName: "newspaper")
                        .font(.system(size: 18))
                        .foregroundColor(accent.opacity(0.8))
                }
            @unknown default:
                EmptyView()
            }
        }
    }
}

// MARK: - Google News RSS fetcher / parser

enum GoogleNewsRSSFetcher {
    static func fetch(
        query: String,
        max: Int,
        completion: @escaping ([NewsArticleItem], String?) -> Void
    ) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://news.google.com/rss/search?q=\(encoded)&hl=en-US&gl=US&ceid=US:en")
        else {
            completion([], "Invalid query")
            return
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error {
                completion([], error.localizedDescription)
                return
            }
            guard let data else {
                completion([], "Empty response")
                return
            }
            let articles = GoogleNewsRSSParser.parse(data: data, max: max)
            completion(articles, nil)
        }.resume()
    }
}

final class GoogleNewsRSSParser: NSObject, XMLParserDelegate {
    private var articles: [NewsArticleItem] = []
    private let max: Int

    private var inItem = false
    private var buf = ""

    private var iTitle = ""
    private var iLink = ""
    private var iDesc = ""
    private var iSource = ""
    private var iPubDate = ""

    private init(max: Int) { self.max = max }

    static func parse(data: Data, max: Int) -> [NewsArticleItem] {
        let p = GoogleNewsRSSParser(max: max)
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.articles
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        buf = ""
        if elementName == "item" {
            inItem = true
            iTitle = ""; iLink = ""; iDesc = ""; iSource = ""; iPubDate = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem { buf += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inItem, let s = String(data: CDATABlock, encoding: .utf8) { buf += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard inItem else { return }
        let v = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title":       iTitle = v
        case "link":        if iLink.isEmpty { iLink = v }
        case "description": iDesc = stripHTML(v)
        case "source":      iSource = v
        case "pubDate":     iPubDate = v
        case "item":        commit(); inItem = false
        default:            break
        }
    }

    private func commit() {
        guard articles.count < max, !iTitle.isEmpty, !iLink.isEmpty else { return }

        // Google News titles often end with " - Source Name" — strip it.
        var title = iTitle
        var source = iSource
        if source.isEmpty, let r = title.range(of: " - ", options: .backwards) {
            source = String(title[r.upperBound...])
            title  = String(title[..<r.lowerBound])
        }

        let snippet: String
        if !iDesc.isEmpty {
            let t = String(iDesc.prefix(160))
            snippet = t + (iDesc.count > 160 ? "…" : "")
        } else {
            snippet = ""
        }

        let date: Date? = {
            guard !iPubDate.isEmpty else { return nil }
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return df.date(from: iPubDate)
        }()

        articles.append(NewsArticleItem(
            id: iLink,
            title: title,
            snippet: snippet,
            url: iLink,
            sourceName: source,
            publishedAt: date
        ))
    }

    private func stripHTML(_ s: String) -> String {
        let stripped = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return Self.decodeEntities(stripped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&rsquo;", "\u{2019}"),
            ("&lsquo;", "\u{2018}"), ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
        ]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities: &#NNN; and &#xHH;
        out = out.replacingOccurrences(
            of: "&#x([0-9a-fA-F]+);",
            with: "&#x$1;",
            options: .regularExpression
        )
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);", options: []) {
            let ns = out as NSString
            var result = ""
            var cursor = 0
            let matches = regex.matches(in: out, options: [], range: NSRange(location: 0, length: ns.length))
            for m in matches {
                let full = m.range
                result += ns.substring(with: NSRange(location: cursor, length: full.location - cursor))
                let isHex = ns.substring(with: m.range(at: 1)) == "x"
                let num   = ns.substring(with: m.range(at: 2))
                if let scalar = UInt32(num, radix: isHex ? 16 : 10),
                   let u = Unicode.Scalar(scalar) {
                    result += String(Character(u))
                }
                cursor = full.location + full.length
            }
            result += ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            out = result
        }
        return out
    }
}

// MARK: - Source logo resolver
//
// Google News RSS gives JS-redirect URLs that can't be resolved without
// running JavaScript, so we can't reliably scrape `og:image` from the actual
// article. Instead, we map the article's source name to a publisher domain
// and use Clearbit's free logo CDN for a high-quality per-source image.
// The Image view falls back to a Google favicon if Clearbit 404s, and to
// a system icon if both fail.

enum SourceLogoResolver {
    /// Known source-name → primary domain overrides.
    /// Anything not listed falls back to a name-based heuristic.
    private static let overrides: [String: String] = [
        "the new york times":        "nytimes.com",
        "ny times":                  "nytimes.com",
        "nyt":                       "nytimes.com",
        "the wall street journal":   "wsj.com",
        "the washington post":       "washingtonpost.com",
        "the guardian":              "theguardian.com",
        "the economist":             "economist.com",
        "the times of india":        "timesofindia.indiatimes.com",
        "times of india":            "timesofindia.indiatimes.com",
        "the hindu":                 "thehindu.com",
        "the indian express":        "indianexpress.com",
        "the new indian express":    "newindianexpress.com",
        "ndtv":                      "ndtv.com",
        "ndtv profit":               "ndtvprofit.com",
        "news on air":               "newsonair.gov.in",
        "all india radio":           "newsonair.gov.in",
        "al jazeera":                "aljazeera.com",
        "bbc":                       "bbc.com",
        "bbc news":                  "bbc.com",
        "cnn":                       "cnn.com",
        "cnbc":                      "cnbc.com",
        "cnbc tv18":                 "cnbctv18.com",
        "reuters":                   "reuters.com",
        "bloomberg":                 "bloomberg.com",
        "the verge":                 "theverge.com",
        "ars technica":              "arstechnica.com",
        "techcrunch":                "techcrunch.com",
        "engadget":                  "engadget.com",
        "wired":                     "wired.com",
        "the atlantic":              "theatlantic.com",
        "associated press":          "apnews.com",
        "ap news":                   "apnews.com",
        "ap":                        "apnews.com",
        "dw":                        "dw.com",
        "dw.com":                    "dw.com",
        "dw news":                   "dw.com",
        "yahoo":                     "yahoo.com",
        "yahoo news":                "news.yahoo.com",
        "yahoo finance":             "finance.yahoo.com",
        "fox news":                  "foxnews.com",
        "abc news":                  "abcnews.go.com",
        "cbs news":                  "cbsnews.com",
        "nbc news":                  "nbcnews.com",
        "msnbc":                     "msnbc.com",
        "usa today":                 "usatoday.com",
        "politico":                  "politico.com",
        "axios":                     "axios.com",
        "the print":                 "theprint.in",
        "moneycontrol":              "moneycontrol.com",
        "livemint":                  "livemint.com",
        "mint":                      "livemint.com",
        "business standard":         "business-standard.com",
        "the economic times":        "economictimes.indiatimes.com",
        "economic times":            "economictimes.indiatimes.com",
        "hindustan times":           "hindustantimes.com",
        "india today":               "indiatoday.in",
        "firstpost":                 "firstpost.com",
        "news18":                    "news18.com",
        "wion":                      "wionews.com",
        "scroll":                    "scroll.in",
        "the wire":                  "thewire.in",
        "rediff":                    "rediff.com",
        "deccan herald":             "deccanherald.com",
        "deccan chronicle":          "deccanchronicle.com",
        "the telegraph":             "telegraphindia.com",
        "telegraph india":           "telegraphindia.com",
    ]

    /// Returns a Clearbit logo URL for the given source name, plus a Google
    /// favicon URL as a fallback (used by the View's AsyncImage failure phase).
    static func imageURLs(for sourceName: String) -> (primary: URL?, fallback: URL?) {
        guard let domain = domain(for: sourceName) else { return (nil, nil) }
        let primary  = URL(string: "https://logo.clearbit.com/\(domain)")
        let fallback = URL(string: "https://www.google.com/s2/favicons?domain=\(domain)&sz=128")
        return (primary, fallback)
    }

    static func domain(for sourceName: String) -> String? {
        let cleaned = sourceName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !cleaned.isEmpty else { return nil }

        if let mapped = overrides[cleaned] { return mapped }

        // If the source name already looks like a domain (contains '.'),
        // strip leading "www." and use it.
        if cleaned.contains(".") {
            return cleaned.hasPrefix("www.") ? String(cleaned.dropFirst(4)) : cleaned
        }

        // Heuristic: drop leading "the ", remove punctuation, collapse spaces,
        // append .com.
        var s = cleaned
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: " -"))
        let filtered = String(s.unicodeScalars.filter { allowed.contains($0) })
        let compact = filtered
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard !compact.isEmpty else { return nil }
        return "\(compact).com"
    }
}
