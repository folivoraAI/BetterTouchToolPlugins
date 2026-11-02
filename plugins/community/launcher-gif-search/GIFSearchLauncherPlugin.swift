// BTT-Plugin-Name: GIF Search
// BTT-Plugin-Identifier: com.btt.ai.gifsearch.launcher
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: photo.stack

import AppKit
import SwiftUI
import Foundation

class GIFSearchLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?
    private var selectedService = GIFService.giphy.rawValue

    private enum IDs { static let open = "open-gif-search"; static let surface = "gif-search-surface" }

    static func launcherPluginName() -> String { "GIF Search" }
    static func launcherPluginDescription() -> String { "GIF search with providers, favorites and recents." }
    static func launcherPluginIcon() -> String { "photo.stack" }

    static func configurationFormItems() -> BTTPluginFormItem? {
        let group = BTTPluginFormItem(); group.formFieldType = BTTFormTypeFormGroup
        let service = BTTPluginFormItem(); service.formFieldType = BTTFormTypePopupButton
        service.formFieldID = "gifService"; service.formLabel1 = "Default GIF Service"
        service.formOptions = GIFService.allCases.map { $0.title }; service.defaultValue = GIFService.giphy.title; service.dataType = BTTFormDataString
        group.formOptions = [service]; return group
    }

    func didReceiveNewConfigurationValues(_ configurationValues: [AnyHashable: Any]?) {
        let raw = (configurationValues?["plugin_var_gifService"] ?? configurationValues?["gifService"]) as? String
        if let service = GIFService.from(raw) { selectedService = service.rawValue }
    }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let result = BTTLauncherPluginResult(); result.itemIdentifier = IDs.open
        result.title = "GIF Search"; result.subtitle = "Choose GIPHY, GIPHY Clips, Klipy, Finer Gifs Club, Favorites or Recent."
        result.systemImageName = "photo.stack"; result.surfaceIdentifier = IDs.surface; result.trailingHint = "Open"
        result.keywords = ["gif", "giphy", "clips", "klipy", "finer", "favorites", "recent"]
        result.searchMatchPriority = 80; return [result]
    }

    func launcherSurface(forItemIdentifier itemIdentifier: String, surfaceIdentifier: String?, context: BTTLauncherPluginContext) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard itemIdentifier == IDs.open, surfaceIdentifier == IDs.surface else { return nil }
        return GIFSearchSurface(initialQuery: context.query ?? "", service: GIFService(rawValue: selectedService) ?? .giphy)
    }
}

final class GIFSearchSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private let model: GIFSearchViewModel
    init(initialQuery: String, service: GIFService) { self.model = GIFSearchViewModel(initialQuery: initialQuery, service: service); super.init(); model.onRequestChromeUpdate = { [weak self] in self?.delegate?.requestLauncherSurfaceUpdate() } }
    func makeLauncherSurfaceView() -> NSView { NSHostingView(rootView: GIFSearchRootView(model: model)) }
    func launcherSurfaceDidAppear() { model.refresh() }
    func launcherSurfaceQueryDidChange(_ query: String?) { model.searchTextChanged(query ?? "") }
    func launcherSurfacePlaceholderText() -> String? { model.placeholder }
    func launcherSurfaceFooterHint() -> String? { "↑↓←→ select • Return copy • F favorite • ⌘C copy URL" }
    func launcherSurfaceStatusText() -> String? { nil }
    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 930, height: 610) }
    func launcherSurfaceMinimumContentSize() -> CGSize { CGSize(width: 700, height: 430) }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }
    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool { false }
    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        let r = BTTLauncherPluginSurfaceCommandResult(); r.handled = true; r.closeLauncher = false; r.goBack = false
        let raw = String(describing: command).lowercased()
        if raw.contains("left") { model.moveSelection(dx: -1, dy: 0) }
        else if raw.contains("right") { model.moveSelection(dx: 1, dy: 0) }
        else if raw.contains("up") { model.moveSelection(dx: 0, dy: -1) }
        else if raw.contains("down") { model.moveSelection(dx: 0, dy: 1) }
        else if raw.contains("return") || raw.contains("enter") || raw.contains("activate") { model.copySelectedGIFToPasteboard(); r.closeLauncher = true }
        else { r.handled = false }
        return r
    }
    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased()

        // Handle navigation here as well as in handleLauncherInputCommand because some
        // launcher surfaces deliver arrow/return keys as raw NSEvents.
        switch event.keyCode {
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
            model.copySelectedGIFToPasteboard()
            delegate?.requestLauncherSurfaceClose()
            return true
        default:
            break
        }

        if flags.contains(.command), ch == "c" { model.copySelectedURLToPasteboard(); delegate?.requestLauncherSurfaceClose(); return true }
        if ch == "f" { model.toggleFavoriteSelected(); return true }
        return false
    }
}

enum GIFService: String, CaseIterable, Codable {
    case giphy, giphyClips, klipy, finerGifs, favorites, recents
    var title: String { switch self { case .giphy: return "GIPHY GIFs"; case .giphyClips: return "GIPHY Clips"; case .klipy: return "Klipy"; case .finerGifs: return "Finer Gifs Club"; case .favorites: return "Favorites"; case .recents: return "Recent" } }
    var icon: String { switch self { case .favorites: return "star.fill"; case .recents: return "clock.arrow.circlepath"; case .finerGifs: return "rectangle.stack.fill"; case .klipy: return "sparkles.rectangle.stack"; default: return "photo.stack" } }
    static func from(_ raw: String?) -> GIFService? { guard let raw else { return nil }; return allCases.first { $0.title == raw || $0.rawValue == raw } }
    var isLocal: Bool { self == .favorites || self == .recents }
}

final class GIFStore {
    static let shared = GIFStore(); private let favKey = "BTTGIFSearchFavoritesV2"; private let recentKey = "BTTGIFSearchRecentV2"
    private func load(_ key: String) -> [GIFItem] { guard let data = UserDefaults.standard.data(forKey: key), let items = try? JSONDecoder().decode([GIFItem].self, from: data) else { return [] }; return items }
    private func save(_ items: [GIFItem], _ key: String) { if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) } }
    func favorites() -> [GIFItem] { load(favKey) }
    func recents() -> [GIFItem] { load(recentKey) }
    func isFavorite(_ item: GIFItem) -> Bool { favorites().contains { $0.id == item.id && $0.provider == item.provider } }
    func addRecent(_ item: GIFItem) { var a = recents().filter { !($0.id == item.id && $0.provider == item.provider) }; a.insert(item, at: 0); save(Array(a.prefix(80)), recentKey) }
    func toggleFavorite(_ item: GIFItem) -> Bool { var a = favorites(); if let i = a.firstIndex(where: { $0.id == item.id && $0.provider == item.provider }) { a.remove(at: i); save(a, favKey); return false } else { a.insert(item, at: 0); save(Array(a.prefix(200)), favKey); return true } }
}

final class GIFSearchViewModel: ObservableObject {
    @Published var sections: [GIFSection] = []; @Published var selectedFlatIndex = 0; @Published var isLoading = false
    @Published var message = "Loading…"; @Published var currentQuery: String; @Published var selectedService: GIFService; @Published var resultLimit: Int
    var onRequestChromeUpdate: (() -> Void)?; private var requestSerial = 0; private let columns = 5
    init(initialQuery: String, service: GIFService) { self.currentQuery = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines); self.selectedService = service; let saved = UserDefaults.standard.integer(forKey: "BTTGIFSearchResultLimit"); self.resultLimit = [24, 50, 100].contains(saved) ? saved : 24 }
    var placeholder: String { selectedService == .favorites ? "Search favorites" : selectedService == .recents ? "Search recent GIFs" : "Search for GIFs on \(selectedService.title)" }
    var statusText: String { if isLoading { return "Loading \(selectedService.title)…" }; let c = allItems().count; return c == 0 ? message : "\(c) GIFs • \(selectedService.title) • selected \(min(selectedFlatIndex+1,c))/\(c)" }
    func allItems() -> [GIFItem] { sections.flatMap { $0.items } }
    func refresh() { loadForCurrent() }
    func changeService(_ service: GIFService) { selectedService = service; sections = []; selectedFlatIndex = 0; loadForCurrent() }
    func changeResultLimit(_ limit: Int) { guard [24, 50, 100].contains(limit) else { return }; resultLimit = limit; UserDefaults.standard.set(limit, forKey: "BTTGIFSearchResultLimit"); sections = []; selectedFlatIndex = 0; loadForCurrent() }
    func searchTextChanged(_ q: String) { let t = q.trimmingCharacters(in: .whitespacesAndNewlines); if t == currentQuery, !sections.isEmpty { return }; currentQuery = t; loadForCurrent() }
    func moveSelection(dx: Int, dy: Int) { let total = allItems().count; guard total > 0 else { return }; let row = selectedFlatIndex / columns; let col = selectedFlatIndex % columns; selectedFlatIndex = max(0, min(total-1, ((row+dy)*columns)+col+dx)); onRequestChromeUpdate?() }
    func itemIsSelected(_ item: GIFItem) -> Bool { let items = allItems(); return selectedFlatIndex < items.count && items[selectedFlatIndex].stableID == item.stableID }
    func select(_ item: GIFItem) { if let i = allItems().firstIndex(where: { $0.stableID == item.stableID }) { selectedFlatIndex = i; onRequestChromeUpdate?() } }
    func isFavorite(_ item: GIFItem) -> Bool { GIFStore.shared.isFavorite(item) }
    func toggleFavoriteSelected() { guard let item = selectedItem() else { return }; let added = GIFStore.shared.toggleFavorite(item); message = added ? "Added to Favorites" : "Removed from Favorites"; if selectedService == .favorites { loadForCurrent() } else { objectWillChange.send(); onRequestChromeUpdate?() } }
    func copySelectedURLToPasteboard() { guard let item = selectedItem() else { return }; let pb = NSPasteboard.general; pb.clearContents(); pb.setString(item.originalURL.absoluteString, forType: .string); pb.setString(item.originalURL.absoluteString, forType: .URL); GIFStore.shared.addRecent(item) }
    func copySelectedGIFToPasteboard() { guard let item = selectedItem() else { return }; GIFStore.shared.addRecent(item); let url = item.downloadURL; let pb = NSPasteboard.general; pb.clearContents(); pb.setString(url.absoluteString, forType: .string); pb.setString(url.absoluteString, forType: .URL); Task.detached(priority: .userInitiated) { if let data = try? Data(contentsOf: url), !data.isEmpty { await MainActor.run { let pb = NSPasteboard.general; pb.clearContents(); let type = url.pathExtension.lowercased() == "mp4" ? NSPasteboard.PasteboardType("public.mpeg-4") : NSPasteboard.PasteboardType("com.compuserve.gif"); pb.setData(data, forType: type); pb.setString(url.absoluteString, forType: .string); pb.setString(url.absoluteString, forType: .URL) } } } }
    private func selectedItem() -> GIFItem? { let items = allItems(); return selectedFlatIndex >= 0 && selectedFlatIndex < items.count ? items[selectedFlatIndex] : nil }
    private func loadForCurrent() {
        let query = currentQuery; let service = selectedService; let limit = resultLimit; requestSerial += 1; let serial = requestSerial
        if service.isLocal { let base = service == .favorites ? GIFStore.shared.favorites() : GIFStore.shared.recents(); let filtered = query.isEmpty ? base : base.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.provider.localizedCaseInsensitiveContains(query) }; sections = [GIFSection(title: service.title, items: filtered)]; selectedFlatIndex = 0; objectWillChange.send(); message = filtered.isEmpty ? (service == .favorites ? "No favorites yet. Select a GIF and press F." : "No recent copies yet.") : "Ready"; onRequestChromeUpdate?(); return }
        isLoading = true; message = query.isEmpty ? "Loading trending from \(service.title)…" : "Searching \(service.title) for “\(query)”…"; onRequestChromeUpdate?()
        Task.detached(priority: .userInitiated) { let outcome = await GIFSearchViewModel.request(service: service, query: query, limit: limit); await MainActor.run { guard serial == self.requestSerial else { return }; self.isLoading = false; self.sections = outcome.items.isEmpty ? [] : [GIFSection(title: query.isEmpty ? "Trending • \(service.title)" : "Results • \(service.title)", items: outcome.items)]; self.selectedFlatIndex = 0; self.message = outcome.items.isEmpty ? outcome.message : "Ready"; self.objectWillChange.send(); self.onRequestChromeUpdate?() } }
    }
    private static func request(service: GIFService, query: String, limit: Int) async -> GIFOutcome { switch service { case .giphy: return await requestGiphy(query: query, clips: false, limit: limit); case .giphyClips: return await requestGiphy(query: query, clips: true, limit: limit); case .klipy: return await requestKlipy(query: query, limit: limit); case .finerGifs: return await requestFiner(query: query, limit: limit); case .favorites, .recents: return GIFOutcome(items: [], message: "Local") } }
    private static func configured(_ url: URL) -> URLRequest { var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15); r.setValue("Mozilla/5.0 BetterTouchTool GIF Search", forHTTPHeaderField: "User-Agent"); r.setValue("application/json", forHTTPHeaderField: "Accept"); return r }
    private static func getJSON(_ url: URL) async throws -> Any { let (data, response) = try await URLSession.shared.data(for: configured(url)); if let h = response as? HTTPURLResponse, !(200...299).contains(h.statusCode) { throw NSError(domain: "GIFSearch", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(h.statusCode) from \(url.host ?? "provider")"]) }; return try JSONSerialization.jsonObject(with: data) }
    private static func requestGiphy(query: String, clips: Bool, limit: Int) async -> GIFOutcome { var c = URLComponents(string: "https://gif-search.raycast.com/api/giphy")!; var q = [URLQueryItem(name:"limit", value:String(limit)), URLQueryItem(name:"offset", value:"0"), URLQueryItem(name:"lang", value:"en")]; if clips { q.append(URLQueryItem(name:"type", value:"videos")) }; if !query.isEmpty { q.append(URLQueryItem(name:"q", value:query)) }; c.queryItems = q; do { guard let url = c.url, let root = try await getJSON(url) as? [String:Any], let data = root["data"] as? [[String:Any]] else { return GIFOutcome(items: [], message: "Bad GIPHY response") }; return GIFOutcome(items: data.compactMap { mapGiphy($0, clips: clips) }, message: "No GIPHY results") } catch { return GIFOutcome(items: [], message: "GIPHY error: \(error.localizedDescription)") } }
    private static func mapGiphy(_ d: [String:Any], clips: Bool) -> GIFItem? { guard let id = d["id"] as? String, let images = d["images"] as? [String:Any], let original = images["original"] as? [String:Any], let gif = original["url"] as? String, let gifURL = URL(string: gif) else { return nil }; let title = (d["title"] as? String) ?? (d["slug"] as? String) ?? "GIF"; let preview = ((images["preview_gif"] as? [String:Any])?["url"] as? String) ?? ((images["fixed_height_small"] as? [String:Any])?["url"] as? String) ?? gif; var download = gif; if clips, let video = d["video"] as? [String:Any], let assets = video["assets"] as? [String:Any] { download = ((assets["1080p"] as? [String:Any])?["url"] as? String) ?? ((assets["720p"] as? [String:Any])?["url"] as? String) ?? ((assets["360p"] as? [String:Any])?["url"] as? String) ?? gif }; guard let p = URL(string: preview), let dl = URL(string: download) else { return nil }; return GIFItem(id: id, title: title, provider: clips ? GIFService.giphyClips.title : GIFService.giphy.title, previewURL: p, originalURL: gifURL, downloadURL: dl) }
    private static func requestKlipy(query: String, limit: Int) async -> GIFOutcome { var c = URLComponents(string: "https://gif-search.raycast.com/api/klipy")!; var q = [URLQueryItem(name:"locale", value:"en"), URLQueryItem(name:"media_filter", value:"gif,nanogif,tinygif"), URLQueryItem(name:"limit", value:String(limit))]; if !query.isEmpty { q.append(URLQueryItem(name:"q", value:query)) }; c.queryItems = q; do { guard let url = c.url, let root = try await getJSON(url) as? [String:Any], let arr = root["results"] as? [[String:Any]] else { return GIFOutcome(items: [], message: "Bad Klipy response") }; return GIFOutcome(items: arr.compactMap(mapKlipy), message: "No Klipy results") } catch { return GIFOutcome(items: [], message: "Klipy error: \(error.localizedDescription)") } }
    private static func mapKlipy(_ d: [String:Any]) -> GIFItem? { guard let id = d["id"] as? String, let media = d["media_formats"] as? [String:Any], let gif = media["gif"] as? [String:Any], let gifS = gif["url"] as? String, let gifURL = URL(string: gifS) else { return nil }; let tiny = ((media["nanogif"] as? [String:Any])?["url"] as? String) ?? ((media["tinygif"] as? [String:Any])?["url"] as? String) ?? gifS; guard let p = URL(string: tiny) else { return nil }; let title = (d["title"] as? String) ?? (d["content_description"] as? String) ?? "GIF"; return GIFItem(id: id, title: title, provider: GIFService.klipy.title, previewURL: p, originalURL: gifURL, downloadURL: gifURL) }
    private static func requestFiner(query: String, limit: Int) async -> GIFOutcome { if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return GIFOutcome(items: [], message: "Finer Gifs Club needs a search term.") }; var c = URLComponents(string: "https://api.thefinergifs.club/search")!; c.queryItems = [URLQueryItem(name:"q", value:query), URLQueryItem(name:"q.parser", value:"simple"), URLQueryItem(name:"sort", value:"_score desc"), URLQueryItem(name:"size", value:String(limit))]; do { guard let url = c.url, let root = try await getJSON(url) as? [String:Any], let arr = root["results"] as? [[String:Any]] else { return GIFOutcome(items: [], message: "Bad Finer Gifs response") }; return GIFOutcome(items: arr.compactMap(mapFiner), message: "No Finer Gifs Club results") } catch { return GIFOutcome(items: [], message: "Finer Gifs error: \(error.localizedDescription)") } }
    private static func mapFiner(_ d: [String:Any]) -> GIFItem? { guard let fields = d["fields"] as? [String:Any], let id = fields["fileid"] as? String else { return nil }; let text = (fields["text"] as? String) ?? (fields["name"] as? String) ?? "GIF"; let url = URL(string: "https://media.thefinergifs.club/\(id).gif")!; return GIFItem(id: id, title: text, provider: GIFService.finerGifs.title, previewURL: url, originalURL: url, downloadURL: url) }
}

struct GIFOutcome { let items: [GIFItem]; let message: String }
struct GIFSection: Identifiable { let id = UUID(); let title: String; let items: [GIFItem] }
struct GIFItem: Identifiable, Hashable, Codable { let id: String; let title: String; let provider: String; let previewURL: URL; let originalURL: URL; let downloadURL: URL; var stableID: String { provider + ":" + id } }

struct GIFSearchRootView: View {
    @ObservedObject var model: GIFSearchViewModel
    private let columns = Array(repeating: GridItem(.fixed(160), spacing: 14), count: 5)
    var body: some View { ZStack { Color.clear; VStack(spacing: 0) { topBar; grid }.overlay { if model.isLoading { loading } } } }
    private var topBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: model.selectedService.icon)
                    .foregroundStyle(.secondary)
                Picker("Service", selection: Binding(get: { model.selectedService }, set: { model.changeService($0) })) {
                    ForEach(GIFService.allCases, id: \.self) { service in
                        Label(service.title, systemImage: service.icon).tag(service)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 205)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())

            HStack(spacing: 8) {
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(.secondary)
                Picker("Results", selection: Binding(get: { model.resultLimit }, set: { model.changeResultLimit($0) })) {
                    Text("24").tag(24)
                    Text("50").tag(50)
                    Text("100").tag(100)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 72)
                Text("GIFs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())

            Spacer(minLength: 12)

            Label(model.statusText, systemImage: model.isLoading ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
    private var grid: some View { ScrollViewReader { proxy in ScrollView { VStack(alignment: .leading, spacing: 22) { if model.sections.isEmpty && !model.isLoading { emptyView }; ForEach(model.sections) { section in VStack(alignment: .leading, spacing: 10) { Text(section.title).font(.headline).foregroundStyle(.secondary); LazyVGrid(columns: columns, alignment: .leading, spacing: 20) { ForEach(section.items) { item in GIFCard(item: item, selected: model.itemIsSelected(item), favorite: model.isFavorite(item)).id(item.stableID).onTapGesture { model.select(item) } } } } } }.padding(.horizontal, 28).padding(.vertical, 12) }.onChange(of: model.selectedFlatIndex) { _ in let items = model.allItems(); if model.selectedFlatIndex < items.count { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(items[model.selectedFlatIndex].stableID, anchor: .center) } } } } }
    private var loading: some View { VStack(spacing: 10) { ProgressView(); Text(model.message).foregroundStyle(.secondary) }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
    private var emptyView: some View { VStack(spacing: 8) { Image(systemName: model.selectedService.icon).font(.largeTitle).foregroundStyle(.secondary); Text(model.message).font(.title3.weight(.semibold)); Text("Use the dropdown: GIPHY GIFs, GIPHY Clips, Klipy, Finer Gifs Club, Favorites, Recent.").foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, minHeight: 340) }
}

struct GIFCard: View { let item: GIFItem; let selected: Bool; let favorite: Bool
    var body: some View { VStack(alignment: .leading, spacing: 7) { ZStack(alignment: .topTrailing) { AnimatedGIFPreview(url: item.previewURL).frame(width: 160, height: 120).background(Color.clear).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)).shadow(color: selected ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.08), radius: selected ? 8 : 3, x: 0, y: 2); if favorite { Image(systemName: "star.fill").foregroundStyle(.yellow).padding(7).shadow(radius: 2) } }; Text(item.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1).frame(width: 160, alignment: .leading); Text(item.provider).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 160, alignment: .leading) }.contentShape(Rectangle()) }
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
        private var task: URLSessionDataTask?

        func load(url: URL, into imageView: NSImageView) {
            if currentURL == url { return }
            currentURL = url
            task?.cancel()
            task = URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard self.currentURL == url else { return }
                    imageView.image = image
                    imageView.animates = true
                }
            }
            task?.resume()
        }

        deinit { task?.cancel() }
    }
}

struct VisualEffectBackground: NSViewRepresentable { func makeNSView(context: Context) -> NSVisualEffectView { let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .withinWindow; v.state = .active; return v }; func updateNSView(_ nsView: NSVisualEffectView, context: Context) {} }
