// BTT-Plugin-Name: Stock Prices
// BTT-Plugin-Identifier: com.bttuserplugin.stockprices
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: chart.line.uptrend.xyaxis
// BTT-AI-Managed: true

import AppKit
import SwiftUI

// MARK: - Model

struct StockQuote {
    let symbol: String
    let name: String
    let price: Double
    let change: Double
    let changePercent: Double
    let timestamp: Date
    let historicalPrices: [Double]   // last ~5 trading days of closes

    var isPositive: Bool { change >= 0 }
    var priceString: String { String(format: "$%.2f", price) }
    var changeString: String {
        let sign = isPositive ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))  (\(sign)\(String(format: "%.2f", changePercent))%)"
    }
}

// MARK: - Plugin

class StockPricesPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    /// Shared across the launcher result list and the surface views, so
    /// both see the same tracked symbols and cached quotes.
    private let store = StockWatchlistStore()
    private var didKickOffInitialRefresh = false

    static func launcherPluginName() -> String { "Stocks" }
    static func launcherPluginDescription() -> String {
        "Track stock prices and view detailed charts."
    }
    static func launcherPluginIcon() -> String { "chart.line.uptrend.xyaxis" }

    /// Always shows a root "Stocks" entry that opens the watchlist surface.
    /// When the user types a symbol prefix (e.g. "AA"), tracked symbols
    /// matching that prefix are surfaced as direct results so the user can
    /// jump straight into a stock's detail view from the main launcher.
    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        // Lazily refresh quotes the first time the plugin is queried so that
        // direct launcher results have prices to show.
        if !didKickOffInitialRefresh {
            didKickOffInitialRefresh = true
            DispatchQueue.main.async { [weak self] in
                self?.store.refreshAll()
            }
        }

        var results: [BTTLauncherPluginResult] = []

        // Root entry — always present.
        let root = BTTLauncherPluginResult()
        root.itemIdentifier = "stocks-root"
        root.title = "Stocks"
        root.subtitle = "Track stock prices and view detailed charts"
        root.systemImageName = "chart.line.uptrend.xyaxis"
        root.surfaceIdentifier = "stocks-root"
        root.trailingHint = "↩"
        root.keywords = ["stocks", "stock", "ticker", "watchlist", "prices"]
        results.append(root)

        // Per-symbol direct entries when the user is typing.
        let query = (context.query ?? "")
            .uppercased()
            .trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            let snapshot = store.threadSafeSnapshot()
            for sym in snapshot.symbols where sym.hasPrefix(query) {
                let r = BTTLauncherPluginResult()
                r.itemIdentifier = "stocks-detail-\(sym)"
                r.surfaceIdentifier = "stocks-detail-\(sym)"
                r.keywords = [sym]

                if let q = snapshot.quotes[sym] {
                    r.title = "\(sym)   \(q.priceString)"
                    r.subtitle = "\(q.name)  ·  \(q.changeString)"
                    r.systemImageName = q.isPositive
                        ? "arrow.up.right.circle.fill"
                        : "arrow.down.left.circle.fill"
                    r.trailingHint = q.isPositive ? "▲" : "▼"
                } else {
                    r.title = sym
                    r.subtitle = "Loading…"
                    r.systemImageName = "chart.bar.fill"
                    r.trailingHint = ""
                }

                results.append(r)
            }
        }

        return results
    }

    func launcherSurface(
        forItemIdentifier itemIdentifier: String,
        surfaceIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> (any BTTLauncherPluginSurfaceInterface)? {
        let detailPrefix = "stocks-detail-"
        let initialSymbol: String?
        if itemIdentifier.hasPrefix(detailPrefix) {
            initialSymbol = String(itemIdentifier.dropFirst(detailPrefix.count))
        } else {
            initialSymbol = nil
        }
        return StocksRootSurface(store: store, initialDetailSymbol: initialSymbol)
    }
}

// MARK: - Quote fetch (free helper, used by both watchlist + detail views)

/// Fetches a single stock quote (price, name, prev close, daily history) from
/// Yahoo Finance. Used by `StockWatchlistStore` for list rows; the detail
/// view fetches its own range-specific chart separately.
func fetchStockQuote(symbol: String, completion: @escaping (StockQuote?) -> Void) {
    let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
    let urlStr = "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?interval=1h&range=5d"
    guard let url = URL(string: urlStr) else { completion(nil); return }

    var req = URLRequest(url: url)
    req.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
        forHTTPHeaderField: "User-Agent"
    )
    req.timeoutInterval = 10

    URLSession.shared.dataTask(with: req) { data, _, error in
        guard let data, error == nil else { completion(nil); return }
        do {
            guard
                let json  = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let chart = json["chart"] as? [String: Any],
                let arr   = chart["result"] as? [[String: Any]],
                let first = arr.first,
                let meta  = first["meta"] as? [String: Any]
            else { completion(nil); return }

            let price     = meta["regularMarketPrice"] as? Double ?? 0
            // `previousClose` is yesterday's official close. `chartPreviousClose`
            // is the close just before the requested chart range starts — for a
            // `range=5d` request that's ~5 trading days ago, which gives a wildly
            // wrong "today's change". Prefer `previousClose`; fall back only if
            // Yahoo omits it.
            let prevClose = (meta["previousClose"]      as? Double)
                         ?? (meta["chartPreviousClose"] as? Double)
                         ?? price
            let name      = (meta["longName"]  as? String)
                         ?? (meta["shortName"] as? String)
                         ?? symbol
            let change    = price - prevClose
            let pct       = prevClose != 0 ? (change / prevClose) * 100 : 0

            var historicalPrices: [Double] = []
            if let indicators = first["indicators"] as? [String: Any],
               let quoteArr = indicators["quote"] as? [[String: Any]],
               let q = quoteArr.first,
               let closes = q["close"] as? [Any] {
                historicalPrices = closes.compactMap { $0 as? Double }
            }
            if !historicalPrices.isEmpty {
                historicalPrices[historicalPrices.count - 1] = price
            } else {
                historicalPrices = [prevClose, price]
            }

            completion(StockQuote(
                symbol: symbol, name: name,
                price: price, change: change,
                changePercent: pct, timestamp: Date(),
                historicalPrices: historicalPrices
            ))
        } catch { completion(nil) }
    }.resume()
}

// MARK: - Chart Range

enum StockRange: String, CaseIterable, Equatable {
    case oneDay     = "1D"
    case fiveDay    = "5D"
    case oneMonth   = "1M"
    case threeMonth = "3M"
    case sixMonth   = "6M"
    case oneYear    = "1Y"
    case fiveYear   = "5Y"

    var rangeParam: String {
        switch self {
        case .oneDay:     return "1d"
        case .fiveDay:    return "5d"
        case .oneMonth:   return "1mo"
        case .threeMonth: return "3mo"
        case .sixMonth:   return "6mo"
        case .oneYear:    return "1y"
        case .fiveYear:   return "5y"
        }
    }

    /// Yahoo Finance interval — balances density vs. response size.
    var intervalParam: String {
        switch self {
        case .oneDay:     return "5m"   // ~78 pts  (5-min bars, 1 trading day)
        case .fiveDay:    return "1h"   // ~33 pts  (hourly, 5 trading days)
        case .oneMonth:   return "1d"   // ~21 pts
        case .threeMonth: return "1d"   // ~63 pts
        case .sixMonth:   return "1d"   // ~126 pts
        case .oneYear:    return "1d"   // ~252 pts
        case .fiveYear:   return "1wk"  // ~260 pts (weekly)
        }
    }

    var startLabel: String {
        switch self {
        case .oneDay:     return "Today"
        case .fiveDay:    return "5D ago"
        case .oneMonth:   return "1M ago"
        case .threeMonth: return "3M ago"
        case .sixMonth:   return "6M ago"
        case .oneYear:    return "1Y ago"
        case .fiveYear:   return "5Y ago"
        }
    }
}

// MARK: - Detail Surface

/// Persists the user's preferred detail-surface size across launches.
private enum StockSurfaceSize {
    static let widthKey  = "com.bttuserplugin.stocks.surfaceWidth"
    static let heightKey = "com.bttuserplugin.stocks.surfaceHeight"

    static let defaultSize = CGSize(width: 600, height: 500)
    static let minWidth:  CGFloat = 420
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

/// `NSHostingView` subclass that reports host-window size changes so the
/// surface can persist the user's resized dimensions.
private final class ResizableHostingView<Root: View>: NSHostingView<Root> {
    var onSizeChanged: ((CGSize) -> Void)?
    private var resizeObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            installResizeObserver(on: window)
        } else {
            removeResizeObserver()
        }
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

    deinit { removeResizeObserver() }
}

final class StocksRootSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private let store: StockWatchlistStore
    private let nav: StocksNavigation

    init(store: StockWatchlistStore, initialDetailSymbol: String? = nil) {
        self.store = store
        self.nav = StocksNavigation()
        super.init()
        if let sym = initialDetailSymbol, store.symbols.contains(sym) {
            nav.detailSymbol = sym
            if let idx = store.symbols.firstIndex(of: sym) {
                nav.selectedIndex = idx
            }
        }
    }

    func makeLauncherSurfaceView() -> NSView {
        let view = ResizableHostingView(
            rootView: StocksRootView(store: store, nav: nav)
        )
        view.onSizeChanged = { size in StockSurfaceSize.save(size) }
        return view
    }

    func launcherSurfacePreferredContentSize() -> CGSize { StockSurfaceSize.load() }
    func launcherSurfaceMinimumContentSize() -> CGSize {
        CGSize(width: StockSurfaceSize.minWidth, height: StockSurfaceSize.minHeight)
    }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }
    func launcherSurfaceFooterHint() -> String? {
        nav.detailSymbol == nil ? "Press Esc to close" : "Press Esc to go back"
    }

    /// Handle launcher keyboard commands:
    /// - List view: ↑/↓ moves selection, Return opens detail, Esc → BTT default
    ///   (closes back to launcher main menu).
    /// - Detail view: Esc pops back to the watchlist.
    func handleLauncherInputCommand(
        _ command: BTTLauncherPluginInputCommand
    ) -> BTTLauncherPluginSurfaceCommandResult? {
        // Detail-view Esc → pop to list.
        if command == .goBackOrClose, nav.detailSymbol != nil {
            nav.detailSymbol = nil
            return Self.handled()
        }

        // List-view keyboard navigation.
        guard nav.detailSymbol == nil else { return nil }

        switch command {
        case .moveUp:
            let count = store.symbols.count
            guard count > 0 else { return Self.handled() }
            nav.selectedIndex = (nav.selectedIndex - 1 + count) % count
            return Self.handled()
        case .moveDown:
            let count = store.symbols.count
            guard count > 0 else { return Self.handled() }
            nav.selectedIndex = (nav.selectedIndex + 1) % count
            return Self.handled()
        case .activateSelection:
            let count = store.symbols.count
            guard nav.selectedIndex >= 0, nav.selectedIndex < count else {
                return Self.handled()
            }
            let sym = store.symbols[nav.selectedIndex]
            if store.quotes[sym] != nil {
                nav.detailSymbol = sym
            }
            return Self.handled()
        default:
            return nil
        }
    }

    private static func handled() -> BTTLauncherPluginSurfaceCommandResult {
        let result = BTTLauncherPluginSurfaceCommandResult()
        result.handled = true
        result.goBack = false
        result.closeLauncher = false
        return result
    }
}

/// Shared navigation/selection state across the surface and SwiftUI views.
/// Lifted out of the SwiftUI hierarchy so the hosting surface can mutate it
/// from outside (Esc handler, ↑/↓/Return key handlers).
final class StocksNavigation: ObservableObject {
    @Published var detailSymbol: String? = nil
    @Published var selectedIndex: Int = 0
}

// MARK: - Sparkline Chart

struct SparklineView: View {
    /// Optional values — trailing `nil`s mean "no data yet" (e.g. intraday
    /// 1D chart during a live trading session) and reserve x-axis space
    /// without drawing a line over them.
    let prices: [Double?]
    let isPositive: Bool
    /// When set, draws hour labels along the bottom of the chart at evenly
    /// spaced positions between `start` and `end` (e.g. for the 1D range).
    var timeAxis: (start: Date, end: Date)? = nil

    @State private var hoverIndex: Int? = nil

    private var lineColor: Color { isPositive ? Color.green : Color(red: 1.0, green: 0.3, blue: 0.3) }

    private var validValues: [Double] { prices.compactMap { $0 } }
    private var firstValidIndex: Int? { prices.firstIndex(where: { $0 != nil }) }
    private var lastValidIndex:  Int? { prices.lastIndex(where:  { $0 != nil }) }

    /// Compute the canvas-space point for data index `i` given view dimensions.
    private func makePoint(_ i: Int, width: CGFloat, height: CGFloat) -> CGPoint? {
        guard let v = prices[i] else { return nil }
        let vals  = validValues
        guard let minP = vals.min(), let maxP = vals.max() else { return nil }
        let range = (maxP - minP) == 0 ? 1.0 : (maxP - minP)
        let n     = prices.count
        let pad: CGFloat = 6
        let x = pad + (width  - pad * 2) * CGFloat(i) / CGFloat(max(n - 1, 1))
        let y = (height - pad) - (height - pad * 2) * CGFloat((v - minP) / range)
        return CGPoint(x: x, y: y)
    }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack(alignment: .topLeading) {

                // ── Sparkline canvas (also draws the hover indicator) ──
                Canvas { ctx, size in
                    let vals = validValues
                    guard vals.count >= 2,
                          let firstIdx = firstValidIndex,
                          let lastIdx  = lastValidIndex
                    else { return }

                    let minP  = vals.min()!
                    let maxP  = vals.max()!
                    let range = (maxP - minP) == 0 ? 1.0 : (maxP - minP)
                    let n     = prices.count
                    let pad: CGFloat = 6

                    func point(_ i: Int) -> CGPoint? {
                        guard let v = prices[i] else { return nil }
                        let x = pad + (size.width  - pad * 2) * CGFloat(i) / CGFloat(max(n - 1, 1))
                        let y = (size.height - pad) - (size.height - pad * 2)
                              * CGFloat((v - minP) / range)
                        return CGPoint(x: x, y: y)
                    }

                    // Collect only the valid points in [firstIdx...lastIdx].
                    // Interior nils are skipped (curve bridges over them)
                    // — only trailing nils (past lastIdx) represent
                    // "no data yet" for an in-progress trading session.
                    let validPts: [CGPoint] = (firstIdx...lastIdx).compactMap { point($0) }
                    guard validPts.count >= 2,
                          let firstPt = validPts.first,
                          let lastPt  = validPts.last
                    else { return }

                    // Smooth bezier curve through valid points
                    func curve(through pts: [CGPoint], appendingTo path: inout Path) {
                        path.move(to: pts[0])
                        for i in 1..<pts.count {
                            let prev = pts[i - 1]
                            let curr = pts[i]
                            let cp1  = CGPoint(x: (prev.x + curr.x) / 2, y: prev.y)
                            let cp2  = CGPoint(x: (prev.x + curr.x) / 2, y: curr.y)
                            path.addCurve(to: curr, control1: cp1, control2: cp2)
                        }
                    }

                    var linePath = Path()
                    curve(through: validPts, appendingTo: &linePath)

                    // Gradient fill: bottom-left → up → curve → down → close
                    var fillPath = Path()
                    fillPath.move(to: CGPoint(x: firstPt.x, y: size.height))
                    fillPath.addLine(to: firstPt)
                    for i in 1..<validPts.count {
                        let prev = validPts[i - 1]
                        let curr = validPts[i]
                        let cp1  = CGPoint(x: (prev.x + curr.x) / 2, y: prev.y)
                        let cp2  = CGPoint(x: (prev.x + curr.x) / 2, y: curr.y)
                        fillPath.addCurve(to: curr, control1: cp1, control2: cp2)
                    }
                    fillPath.addLine(to: CGPoint(x: lastPt.x, y: size.height))
                    fillPath.closeSubpath()

                    let fillColor = isPositive
                        ? Color.green.opacity(0.12)
                        : Color(red: 1.0, green: 0.3, blue: 0.3).opacity(0.12)
                    ctx.fill(fillPath, with: .color(fillColor))

                    // Stroke the line
                    ctx.stroke(
                        linePath,
                        with: .color(lineColor),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    )

                    // Glowing dot at last (current) valid price point
                    let last = lastPt
                    let outerRect = CGRect(x: last.x - 6,   y: last.y - 6,   width: 12, height: 12)
                    let innerRect = CGRect(x: last.x - 3.5, y: last.y - 3.5, width: 7,  height: 7)
                    ctx.fill(Path(ellipseIn: outerRect), with: .color(lineColor.opacity(0.25)))
                    ctx.fill(Path(ellipseIn: innerRect),  with: .color(lineColor))

                    // ── Hover: dashed crosshair + snapped dot ────────────
                    if let idx = hoverIndex,
                       prices.indices.contains(idx),
                       let pt = point(idx) {

                        // Vertical dashed crosshair
                        var crosshair = Path()
                        crosshair.move(to: CGPoint(x: pt.x, y: 0))
                        crosshair.addLine(to: CGPoint(x: pt.x, y: size.height))
                        ctx.stroke(crosshair, with: .color(lineColor.opacity(0.5)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                        // Dot at hovered data point
                        let dotOuter = CGRect(x: pt.x - 5, y: pt.y - 5, width: 10, height: 10)
                        let dotInner = CGRect(x: pt.x - 3, y: pt.y - 3, width: 6,  height: 6)
                        ctx.fill(Path(ellipseIn: dotOuter), with: .color(lineColor.opacity(0.3)))
                        ctx.fill(Path(ellipseIn: dotInner), with: .color(lineColor))
                    }
                }


                // ── Floating price label ─────────────────────────────────
                if let idx = hoverIndex,
                   prices.indices.contains(idx),
                   let v  = prices[idx],
                   let pt = makePoint(idx, width: w, height: h) {
                    let labelX = min(max(pt.x, 30), w - 30)
                    let labelY = max(pt.y - 22, 14)

                    Text(String(format: "$%.2f", v))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(NSColor.windowBackgroundColor))
                                .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 1)
                        )
                        .fixedSize()
                        .position(x: labelX, y: labelY)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    guard prices.count >= 2,
                          let firstIdx = firstValidIndex,
                          let lastIdx  = lastValidIndex
                    else { break }
                    let pad: CGFloat = 6
                    let rawIdx = (loc.x - pad) / (w - pad * 2) * CGFloat(prices.count - 1)
                    let clamped = max(firstIdx, min(lastIdx, Int(rawIdx.rounded())))
                    // snap to nearest valid index (skip any nil gaps)
                    hoverIndex = prices[clamped] != nil ? clamped : lastIdx
                case .ended:
                    hoverIndex = nil
                }
            }
        }
    }
}

// MARK: - Detail View

struct StockDetailView: View {
    let quote: StockQuote

    @State private var selectedRange: StockRange = .oneDay
    @State private var chartPrices:   [Double?]
    @State private var chartTimestamps: [Date] = []
    @State private var isFetchingChart = true
    @State private var tradingStart: Date? = nil
    @State private var tradingEnd:   Date? = nil

    init(quote: StockQuote) {
        self.quote = quote
        self._chartPrices = State(initialValue: [])
    }

    // ── Range-aware change ────────────────────────────────────────
    // Change/Change% are computed against the first point of the currently
    // selected range so they reflect what the chart is showing.
    // Prev Close is intentionally NOT range-aware — it always reports the
    // previous trading day's close from the initial quote fetch.
    private var validChartPrices: [Double] { chartPrices.compactMap { $0 } }
    private var rangeBaseline: Double? {
        // 1D should mirror the watchlist row, which compares against the
        // previous trading day's close (Yahoo's `quote.change`). For longer
        // ranges, compare against the first sample of the selected range so
        // the headline reflects what the chart visually shows.
        if selectedRange == .oneDay { return nil }
        return validChartPrices.count >= 2 ? validChartPrices.first : nil
    }
    private var rangeChange: Double {
        guard let base = rangeBaseline else { return quote.change }
        return quote.price - base
    }
    private var rangeChangePercent: Double {
        guard let base = rangeBaseline, base != 0 else { return quote.changePercent }
        return (rangeChange / base) * 100
    }
    private var rangeIsPositive: Bool { rangeChange >= 0 }
    private var prevTradingDayClose: Double { quote.price - quote.change }

    /// X-axis tick labels for the current chart range.
    /// Returns x-fractions in `[0, 1]` aligned with the sparkline's coordinate
    /// system, plus a human label (e.g. "10 am", "7 May", "Feb 2026").
    private var axisLabels: [(x: CGFloat, text: String)] {
        switch selectedRange {
        case .oneDay:
            // Hour ticks across the regular trading session.
            guard let start = tradingStart, let end = tradingEnd, end > start
            else { return [] }
            let total = end.timeIntervalSince(start)
            let cal   = Calendar.current
            var comps = cal.dateComponents([.year, .month, .day, .hour], from: start)
            comps.hour = (comps.hour ?? 0) + 1
            comps.minute = 0; comps.second = 0
            guard var tick = cal.date(from: comps) else { return [] }
            let fmt = DateFormatter(); fmt.dateFormat = "h a"
            var out: [(CGFloat, String)] = []
            while tick < end {
                let frac = CGFloat(tick.timeIntervalSince(start) / total)
                out.append((frac, fmt.string(from: tick).lowercased()))
                tick = cal.date(byAdding: .hour, value: 1, to: tick) ?? end
            }
            return out

        case .fiveDay, .oneMonth, .threeMonth:
            // Date ticks ("7 May", "16 Apr", "24 Apr", …)
            return dateTicks(format: "d MMM", targetCount: selectedRange == .fiveDay ? 4 : 4)

        case .sixMonth, .oneYear:
            // Month ticks ("Feb 2026")
            return monthTicks(format: "MMM yyyy", targetCount: selectedRange == .sixMonth ? 1 : 3)

        case .fiveYear:
            // Year ticks ("2026")
            return monthTicks(format: "yyyy", targetCount: 4)
        }
    }

    /// Pick roughly `targetCount` evenly spaced data points (skipping nils)
    /// and turn them into x-fraction + formatted-date pairs.
    private func dateTicks(format: String, targetCount: Int) -> [(CGFloat, String)] {
        guard chartTimestamps.count == chartPrices.count,
              chartTimestamps.count >= 2
        else { return [] }
        let validIdx = chartPrices.indices.filter { chartPrices[$0] != nil }
        guard validIdx.count >= 2 else { return [] }

        let fmt = DateFormatter(); fmt.dateFormat = format
        let n   = chartTimestamps.count
        let step = max(1, validIdx.count / targetCount)
        var picked: [Int] = []
        var i = validIdx.first!
        while i <= validIdx.last! {
            if chartPrices[i] != nil { picked.append(i) }
            i += step
        }
        return picked.map { idx in
            (CGFloat(idx) / CGFloat(max(n - 1, 1)),
             fmt.string(from: chartTimestamps[idx]))
        }
    }

    /// Like `dateTicks` but snaps to month-start positions so labels read
    /// e.g. "Feb 2026", "May 2026".
    private func monthTicks(format: String, targetCount: Int) -> [(CGFloat, String)] {
        guard chartTimestamps.count == chartPrices.count,
              chartTimestamps.count >= 2
        else { return [] }
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = format
        let n = chartTimestamps.count

        // Group indices by month-start (or year-start for 5Y) and pick the
        // first index of each group.
        var seen = Set<String>()
        var firstOfGroup: [Int] = []
        for i in 0..<n {
            let date = chartTimestamps[i]
            let key: String
            if format.contains("MMM") {
                let c = cal.dateComponents([.year, .month], from: date)
                key = "\(c.year ?? 0)-\(c.month ?? 0)"
            } else {
                key = "\(cal.component(.year, from: date))"
            }
            if !seen.contains(key) {
                seen.insert(key)
                firstOfGroup.append(i)
            }
        }
        // Drop the very first group if it's right at the start (avoids a label
        // squished against the left edge), and downsample to ~targetCount.
        if firstOfGroup.count > targetCount + 1 {
            let stride = max(1, firstOfGroup.count / targetCount)
            firstOfGroup = firstOfGroup.enumerated()
                .compactMap { (off, idx) in off % stride == 0 ? idx : nil }
        }
        return firstOfGroup.map { idx in
            (CGFloat(idx) / CGFloat(max(n - 1, 1)),
             fmt.string(from: chartTimestamps[idx]))
        }
    }

    private var accentColor: Color {
        rangeIsPositive ? .green : Color(red: 1.0, green: 0.3, blue: 0.3)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(quote.symbol)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(quote.name)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(quote.priceString)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    // Pill badge
                    HStack(spacing: 3) {
                        Image(systemName: rangeIsPositive ? "arrow.up.right" : "arrow.down.left")
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%+.2f  (%+.2f%%)", rangeChange, rangeChangePercent))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.13))
                    .clipShape(Capsule())
                }
            }
            .padding(.bottom, 14)

            // ── Range Selector (above chart) ─────────────────────────
            HStack(spacing: 2) {
                ForEach(StockRange.allCases, id: \.self) { range in
                    Button(action: { selectedRange = range }) {
                        Text(range.rawValue)
                            .font(.system(size: 11,
                                          weight: selectedRange == range ? .semibold : .regular))
                            .foregroundColor(selectedRange == range ? accentColor : .secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedRange == range
                                          ? accentColor.opacity(0.12)
                                          : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.bottom, 8)

            // ── Sparkline + x-axis labels ────────────────────────────
            VStack(spacing: 0) {
                ZStack {
                    if validChartPrices.count >= 2 {
                        SparklineView(prices: chartPrices, isPositive: rangeIsPositive)
                            .opacity(isFetchingChart ? 0.4 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: isFetchingChart)
                    } else {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .frame(height: 110)

                // Reserve the axis row unconditionally so range changes
                // don't cause a layout shift (= visible UI flicker).
                GeometryReader { proxy in
                    let pad: CGFloat = 6
                    ForEach(Array(axisLabels.enumerated()), id: \.offset) { _, item in
                        let x = pad + (proxy.size.width - pad * 2) * item.x
                        Text(item.text)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundColor(Color.secondary.opacity(0.7))
                            .fixedSize()
                            .position(x: x, y: 8)
                    }
                }
                .frame(height: 16)
            }
            .padding(.bottom, 14)

            Divider()
                .padding(.bottom, 12)

            // ── Stats row ────────────────────────────────────────────
            HStack(spacing: 0) {
                StatTile(label: "Change",    value: String(format: "%+.2f",   rangeChange),        isAccent: true, pos: rangeIsPositive)
                Spacer()
                StatTile(label: "Change %",  value: String(format: "%+.2f%%", rangeChangePercent), isAccent: true, pos: rangeIsPositive)
                Spacer()
                StatTile(label: "Prev Close", value: String(format: "$%.2f", prevTradingDayClose), isAccent: false, pos: true)
                Spacer()
                StatTile(label: "Price",     value: quote.priceString,                               isAccent: false, pos: true)
            }
        }
        .padding(20)
        // fires immediately on appear, and again whenever selectedRange changes;
        // automatically cancels in-flight request if the user switches range quickly
        .task(id: selectedRange) {
            await fetchChart(for: selectedRange)
        }
    }

    // MARK: - Chart Fetch

    private func fetchChart(for range: StockRange) async {
        await MainActor.run { isFetchingChart = true }

        let symbol  = quote.symbol
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let urlStr  = "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)"
                    + "?interval=\(range.intervalParam)&range=\(range.rangeParam)"
        guard let url = URL(string: urlStr) else {
            await MainActor.run { isFetchingChart = false }
            return
        }

        var req = URLRequest(url: url)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            var prices: [Double?] = []
            var tradingDayStart: TimeInterval? = nil
            var tradingDayEnd:   TimeInterval? = nil
            var timestamps: [TimeInterval] = []
            if let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let chart  = json["chart"]        as? [String: Any],
               let arr    = chart["result"]       as? [[String: Any]],
               let first  = arr.first,
               let indic  = first["indicators"]  as? [String: Any],
               let qArr   = indic["quote"]        as? [[String: Any]],
               let q      = qArr.first,
               let closes = q["close"]            as? [Any] {
                // Preserve trailing NSNull entries — they reserve x-axis space
                // for the remainder of an in-progress 1D trading session.
                prices = closes.map { $0 as? Double }
                if let ts = first["timestamp"] as? [Any] {
                    timestamps = ts.compactMap {
                        if let i = $0 as? Int    { return TimeInterval(i) }
                        if let d = $0 as? Double { return d }
                        return nil
                    }
                }
                if let meta = first["meta"] as? [String: Any],
                   let period = (meta["currentTradingPeriod"] as? [String: Any])?["regular"]
                              as? [String: Any] {
                    if let s = period["start"] as? Int    { tradingDayStart = TimeInterval(s) }
                    if let s = period["start"] as? Double { tradingDayStart = s }
                    if let e = period["end"]   as? Int    { tradingDayEnd   = TimeInterval(e) }
                    if let e = period["end"]   as? Double { tradingDayEnd   = e }
                }
            }

            // ── 1D padding: Yahoo only returns bars up to "now" during a
            // live trading session. Pad with trailing nils so the x-axis
            // spans the full regular trading day (matches Google Finance).
            if range == .oneDay,
               let start = tradingDayStart,
               let end   = tradingDayEnd,
               end > start,
               !prices.isEmpty,
               timestamps.count == prices.count {
                let interval: TimeInterval = 5 * 60  // matches intervalParam "5m"
                let totalSlots = max(prices.count,
                                     Int(((end - start) / interval).rounded(.up)))
                if totalSlots > prices.count {
                    prices.append(contentsOf:
                        Array<Double?>(repeating: nil, count: totalSlots - prices.count))
                }
            }

            await MainActor.run {
                if prices.contains(where: { $0 != nil }) { chartPrices = prices }
                chartTimestamps = timestamps.map { Date(timeIntervalSince1970: $0) }
                if range == .oneDay, let s = tradingDayStart, let e = tradingDayEnd {
                    tradingStart = Date(timeIntervalSince1970: s)
                    tradingEnd   = Date(timeIntervalSince1970: e)
                } else {
                    tradingStart = nil
                    tradingEnd   = nil
                }
                isFetchingChart = false
            }
        } catch {
            await MainActor.run { isFetchingChart = false }
        }
    }
}

struct StatTile: View {
    let label: String
    let value: String
    let isAccent: Bool
    let pos: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            Text(value)
                .font(.system(size: 14, design: .rounded).weight(.semibold))
                .foregroundColor(isAccent ? (pos ? .green : Color(red: 1.0, green: 0.3, blue: 0.3)) : .primary)
        }
    }
}

// MARK: - Watchlist Store

private let watchlistDefaultsKey = "com.bttuserplugin.stocks.watchlist"
private let defaultWatchlist: [String] =
    ["ADBE", "AAPL", "GOOGL", "MSFT", "AMZN", "NVDA", "TSLA", "META"]

/// User-managed list of tracked symbols + their cached quotes. Persists
/// the symbol list to `UserDefaults` so additions/deletions survive
/// across launches. All mutations are expected on the main thread
/// (SwiftUI callbacks); background fetch results are hopped to main
/// before publishing.
final class StockWatchlistStore: ObservableObject {
    @Published private(set) var symbols: [String]
    @Published private(set) var quotes: [String: StockQuote] = [:]
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastFetch: Date? = nil
    @Published private(set) var loadingSymbols: Set<String> = []

    /// Lock-protected mirror of `symbols`/`quotes` so background callers
    /// (e.g. `launcherResults` invoked off the main queue) can read a
    /// consistent snapshot without touching `@Published` storage.
    private var snapshotSymbols: [String]
    private var snapshotQuotes: [String: StockQuote] = [:]
    private let snapshotLock = NSLock()

    init() {
        let initial: [String]
        if let saved = UserDefaults.standard.stringArray(forKey: watchlistDefaultsKey),
           !saved.isEmpty {
            initial = saved.map { $0.uppercased() }
        } else {
            initial = defaultWatchlist
        }
        self.symbols = initial
        self.snapshotSymbols = initial
    }

    /// Thread-safe read of the current symbols + quotes. Safe to call from
    /// any queue (including BTT's launcher-results background thread).
    func threadSafeSnapshot() -> (symbols: [String], quotes: [String: StockQuote]) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return (snapshotSymbols, snapshotQuotes)
    }

    private func writeSnapshot(_ block: () -> Void) {
        snapshotLock.lock()
        block()
        snapshotLock.unlock()
    }

    // MARK: Mutations

    /// Append a new symbol to the watchlist (no-op if duplicate or empty).
    /// Returns true if the symbol was actually added.
    @discardableResult
    func add(_ raw: String) -> Bool {
        let sym = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty, !symbols.contains(sym) else { return false }
        symbols.append(sym)
        writeSnapshot { snapshotSymbols.append(sym) }
        persist()
        fetchOne(sym)
        return true
    }

    func remove(_ symbol: String) {
        symbols.removeAll { $0 == symbol }
        quotes.removeValue(forKey: symbol)
        writeSnapshot {
            snapshotSymbols.removeAll { $0 == symbol }
            snapshotQuotes.removeValue(forKey: symbol)
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(symbols, forKey: watchlistDefaultsKey)
    }

    // MARK: Fetching

    /// Refresh quotes for every tracked symbol in parallel.
    func refreshAll() {
        guard !isLoading else { return }
        let symbolsToFetch = symbols
        guard !symbolsToFetch.isEmpty else {
            lastFetch = Date()
            return
        }
        isLoading = true
        var pending = symbolsToFetch.count
        for sym in symbolsToFetch {
            fetchStockQuote(symbol: sym) { [weak self] q in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let q = q {
                        self.quotes[sym] = q
                        self.writeSnapshot { self.snapshotQuotes[sym] = q }
                    }
                    pending -= 1
                    if pending == 0 {
                        self.lastFetch = Date()
                        self.isLoading = false
                    }
                }
            }
        }
    }

    /// Refresh a single symbol's quote (used right after adding it).
    func fetchOne(_ symbol: String) {
        loadingSymbols.insert(symbol)
        fetchStockQuote(symbol: symbol) { [weak self] q in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingSymbols.remove(symbol)
                if let q = q {
                    self.quotes[symbol] = q
                    self.writeSnapshot { self.snapshotQuotes[symbol] = q }
                }
            }
        }
    }
}

// MARK: - Stocks Root View (list + detail)

/// Top-level view shown by `StocksRootSurface`. Hosts both the watchlist and
/// the per-symbol detail view; navigation between the two is internal state
/// because BTT has no surface-stack API.
struct StocksRootView: View {
    @ObservedObject var store: StockWatchlistStore
    @ObservedObject var nav: StocksNavigation
    @State private var isAdding: Bool = false
    @State private var addText: String = ""
    @State private var addError: String? = nil
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        Group {
            if let sym = nav.detailSymbol, let q = store.quotes[sym] {
                StockDetailView(quote: q)
            } else {
                listView
            }
        }
        .onAppear {
            // Auto-refresh every time the surface is opened from the launcher.
            // `refreshAll()` already no-ops while a refresh is in flight.
            store.refreshAll()
        }
    }

    // MARK: Watchlist list

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(spacing: 10) {
                Text("Stocks")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                if let lf = store.lastFetch {
                    let fmt: DateFormatter = {
                        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
                    }()
                    Text("Updated \(fmt.string(from: lf))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: { store.refreshAll() }) {
                    Image(systemName: store.isLoading ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh all")
                .disabled(store.isLoading)

                Button(action: toggleAdd) {
                    Image(systemName: isAdding ? "xmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isAdding ? "Cancel" : "Add stock")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Inline add row
            if isAdding {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("Symbol (e.g. AAPL)", text: $addText)
                            .textFieldStyle(.roundedBorder)
                            .focused($addFieldFocused)
                            .onSubmit { commitAdd() }
                            .onChange(of: addText) { _ in addError = nil }
                        Button("Add") { commitAdd() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(addText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let err = addError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Divider()

            // Watchlist
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.symbols.enumerated()), id: \.element) { idx, sym in
                            StockRowView(
                                symbol: sym,
                                quote: store.quotes[sym],
                                isLoading: store.loadingSymbols.contains(sym)
                                    || (store.quotes[sym] == nil && store.isLoading),
                                isSelected: idx == nav.selectedIndex,
                                onSelect: {
                                    nav.selectedIndex = idx
                                    if store.quotes[sym] != nil { nav.detailSymbol = sym }
                                },
                                onDelete: { store.remove(sym) }
                            )
                            .id(sym)
                            Divider()
                        }
                        if store.symbols.isEmpty {
                            Text("No stocks tracked yet. Click + to add one.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(40)
                        }
                    }
                }
                // Keep keyboard-selected row visible.
                .onChange(of: nav.selectedIndex) { newIdx in
                    guard newIdx >= 0, newIdx < store.symbols.count else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(store.symbols[newIdx], anchor: .center)
                    }
                }
                // Clamp selection if list shrinks (e.g. after delete).
                .onChange(of: store.symbols.count) { newCount in
                    if newCount == 0 {
                        nav.selectedIndex = 0
                    } else if nav.selectedIndex >= newCount {
                        nav.selectedIndex = newCount - 1
                    }
                }
            }
        }
    }

    private func toggleAdd() {
        isAdding.toggle()
        addText = ""
        addError = nil
        if isAdding {
            // Defer focus so the field exists when we set focus.
            DispatchQueue.main.async { addFieldFocused = true }
        }
    }

    private func commitAdd() {
        let sym = addText.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sym.isEmpty else { return }
        if store.symbols.contains(sym) {
            addError = "\(sym) is already in your watchlist."
            return
        }
        _ = store.add(sym)
        addText = ""
        addError = nil
        isAdding = false
    }
}

// MARK: - Stock Row

struct StockRowView: View {
    let symbol: String
    let quote: StockQuote?
    let isLoading: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var accent: Color {
        guard let q = quote else { return .secondary }
        return q.isPositive ? .green : Color(red: 1.0, green: 0.3, blue: 0.3)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovered  { return Color.primary.opacity(0.06) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundColor(accent)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(symbol)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(quote?.name ?? (isLoading ? "Loading…" : "Price unavailable"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let q = quote {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(q.priceString)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(String(format: "%+.2f%%", q.changePercent))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accent)
                }
            } else if isLoading {
                ProgressView().scaleEffect(0.5)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .opacity(isHovered || isSelected ? 1 : 0)
            }
            .buttonStyle(.plain)
            .help("Remove from watchlist")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
    }

    private var iconName: String {
        guard let q = quote else { return "circle.dashed" }
        return q.isPositive ? "arrow.up.right.circle.fill"
                            : "arrow.down.left.circle.fill"
    }
}
