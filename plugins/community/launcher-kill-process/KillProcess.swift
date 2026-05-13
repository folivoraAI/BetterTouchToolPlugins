// BTT-Plugin-Name: Kill Process
// BTT-Plugin-Identifier: com.bttuserplugin.killprocess
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: xmark.circle.fill
// BTT-AI-Managed: true

import AppKit
import SwiftUI
import Darwin

// MARK: - Size Persistence

private struct KillProcessSurfaceSize {
    static let key = "com.bttuserplugin.killprocess.surfaceSize"
    static let defaultSize = CGSize(width: 640, height: 460)

    static func save(_ size: CGSize) {
        UserDefaults.standard.set(NSStringFromSize(NSSizeFromCGSize(size)), forKey: key)
    }

    static func load() -> CGSize {
        guard let str = UserDefaults.standard.string(forKey: key) else { return defaultSize }
        let s = NSSizeFromString(str)
        guard s.width > 100, s.height > 100 else { return defaultSize }
        return CGSize(width: s.width, height: s.height)
    }
}

// MARK: - Data Model

struct ProcessEntry: Identifiable, Equatable {
    let id: String
    let pid: String
    let name: String
    let user: String
    let cpu: Double
    let mem: Double
}

// MARK: - Process Fetching

private func fetchProcesses() -> [ProcessEntry] {
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments  = ["ax", "-o", "pid=,pcpu=,pmem=,user=,comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError  = Pipe()
    do { try task.run() } catch { return [] }

    var outputData = Data()
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        sem.signal()
    }
    guard sem.wait(timeout: .now() + 5) == .success else { task.terminate(); return [] }
    task.waitUntilExit()

    var entries: [ProcessEntry] = []
    let raw = String(data: outputData, encoding: .utf8) ?? ""
    for line in raw.components(separatedBy: "\n") {
        var parts = line.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }
        guard parts.count >= 5 else { continue }
        let pid  = parts.removeFirst()
        let cpu  = Double(parts.removeFirst()) ?? 0
        let mem  = Double(parts.removeFirst()) ?? 0
        let user = parts.removeFirst()
        let comm = parts.joined(separator: " ")
        let name = URL(fileURLWithPath: comm).lastPathComponent
        guard Int32(pid) != nil, !name.isEmpty else { continue }
        entries.append(ProcessEntry(id: pid, pid: pid, name: name, user: user, cpu: cpu, mem: mem))
    }
    entries.sort { $0.cpu > $1.cpu }
    return entries
}

// MARK: - State

final class ProcessListState: ObservableObject {
    @Published var searchText: String = "" {
        didSet { if oldValue != searchText { selectedIndex = 0 } }
    }
    @Published var all: [ProcessEntry] = []
    @Published var selectedIndex: Int = 0
    @Published var isLoading: Bool = true

    /// Computed on every access — always reflects current `searchText` and `all`.
    /// Matches the process name only, case-insensitive.
    var filtered: [ProcessEntry] {
        let q = searchText.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) }
    }

    func load() {
        DispatchQueue.main.async { self.isLoading = true }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = fetchProcesses()
            DispatchQueue.main.async {
                guard let self else { return }
                self.all = entries
                self.isLoading = false
            }
        }
    }

    func remove(pid: String) {
        all.removeAll { $0.pid == pid }
        if selectedIndex >= filtered.count {
            selectedIndex = max(0, filtered.count - 1)
        }
    }

    var selectedProcess: ProcessEntry? {
        let list = filtered
        guard !list.isEmpty, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    func navigateUp() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
    }

    func navigateDown() {
        guard selectedIndex < filtered.count - 1 else { return }
        selectedIndex += 1
    }
}

// MARK: - Focus-aware Hosting View

private final class FocusableHostingView<Root: View>: NSHostingView<Root> {
    var onMoveUp:        (() -> Void)?
    var onMoveDown:      (() -> Void)?
    var onSelectCurrent: (() -> Void)?
    var onAltSelect:     (() -> Void)?    // ⌘T → graceful quit (SIGTERM)
    var onSizeChanged:   ((CGSize) -> Void)?
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
            // Navigation / action keys are intercepted first so the launcher's
            // search field can't swallow them.
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers?.lowercased() == "t" {
                self.onAltSelect?()
                return nil
            }
            switch event.keyCode {
            case 125: self.onMoveDown?();        return nil   // ↓
            case 126: self.onMoveUp?();          return nil   // ↑
            case 36, 76: self.onSelectCurrent?(); return nil  // Return / numpad Enter
            default:
                // Pass other keys through to the focused text field (if any).
                if let fr = self.window?.firstResponder, fr is NSTextView { return event }
                if self.redirectTypedCharacterToLauncherSearch(event) {
                    return nil
                }
                return event
            }
        }
    }

    /// If the event is a printable character (no ⌘/⌃/⌥) and the launcher's
    /// external search field can be found, focus it and forward the typed
    /// character into it. Returns `true` when the event was redirected.
    private func redirectTypedCharacterToLauncherSearch(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
        window.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.insertText(event.characters ?? chars)
        } else {
            searchField.stringValue.append(event.characters ?? chars)
        }
        return true
    }

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

// MARK: - SwiftUI Views

struct ProcessListView: View {
    @ObservedObject var state: ProcessListState

    var body: some View {
        // Compute filter locally inside body so it's recomputed on every
        // render — sidesteps any @Published timing weirdness.
        let filtered = state.filtered
        VStack(spacing: 0) {
            Group {
                if state.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading processes\u{2026}")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    Text(state.searchText.isEmpty ? "No processes found" : "No matching processes")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, proc in
                                    ProcessRow(proc: proc, isSelected: index == state.selectedIndex)
                                        .onTapGesture { state.selectedIndex = index }
                                        .id(proc.id)
                                }
                            }
                        }
                        .onChange(of: state.selectedIndex) { _, newIndex in
                            guard newIndex >= 0, newIndex < filtered.count else { return }
                            withAnimation(.easeInOut(duration: 0.12)) {
                                proxy.scrollTo(filtered[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProcessRow: View {
    let proc: ProcessEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: proc.cpu > 10 ? "flame.fill" : "cpu")
                .foregroundStyle(isSelected ? .white : (proc.cpu > 10 ? .orange : .secondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(proc.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                Text("PID \(proc.pid)  \u{00B7}  CPU \(String(format: "%.1f", proc.cpu))%  \u{00B7}  Mem \(String(format: "%.1f", proc.mem))%  \u{00B7}  \(proc.user)")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
            }

            Spacer()

            if isSelected {
                HStack(spacing: 6) {
                    Text("\u{21A9} Kill")
                    Text("\u{00B7}").opacity(0.5)
                    Text("\u{2318}T Quit")
                }
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Launcher Surface

final class ProcessListSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?

    private let state  = ProcessListState()
    private let killFn: (String, Int32) -> Bool

    init(killFn: @escaping (String, Int32) -> Bool) {
        self.killFn = killFn
    }

    func makeLauncherSurfaceView() -> NSView {
        let hostingView = FocusableHostingView(rootView: ProcessListView(state: state))
        hostingView.onMoveUp = { [weak state] in
            DispatchQueue.main.async { state?.navigateUp() }
        }
        hostingView.onMoveDown = { [weak state] in
            DispatchQueue.main.async { state?.navigateDown() }
        }
        hostingView.onSelectCurrent = { [weak self] in
            DispatchQueue.main.async { self?.performKill(signal: SIGKILL) }
        }
        hostingView.onAltSelect = { [weak self] in
            DispatchQueue.main.async { self?.performKill(signal: SIGTERM) }
        }
        hostingView.onSizeChanged = { KillProcessSurfaceSize.save($0) }
        return hostingView
    }

    func launcherSurfaceDidAppear() {
        state.load()
    }

    // BTT's launcher search field drives the filter — same pattern as Jira / GitHub.
    func launcherSurfaceQueryDidChange(_ query: String?) {
        let q = query ?? ""
        DispatchQueue.main.async { [weak self] in
            self?.state.searchText = q
        }
    }

    func launcherSurfacePlaceholderText() -> String? { "Filter by name, PID, or user\u{2026}" }
    func launcherSurfaceFooterHint() -> String? { "\u{21A9} Force kill  \u{00B7}  \u{2318}T Graceful quit  \u{00B7}  \u{2191}\u{2193} Navigate" }
    func launcherSurfacePreferredContentSize() -> CGSize { KillProcessSurfaceSize.load() }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }

    // Match the working Jira/GitHub pattern: BTT keeps handling navigation
    // keys (↑/↓/Return) so it can route them through handleLauncherInputCommand;
    // everything else — printable characters going to the search field — bypasses.
    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return true }
        switch event.keyCode {
        case 125, 126, 36, 76, 123, 124: return false   // ↓ ↑ Return Enter ← →
        default: return true
        }
    }

    // BTT routes arrow keys through this hook regardless of which view holds
    // focus — use it as the primary navigation path so the launcher's search
    // field can't swallow ↑/↓.
    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        let result = BTTLauncherPluginSurfaceCommandResult()
        switch command {
        case .moveUp:
            DispatchQueue.main.async { [weak self] in self?.state.navigateUp() }
            result.handled = true
            return result
        case .moveDown:
            DispatchQueue.main.async { [weak self] in self?.state.navigateDown() }
            result.handled = true
            return result
        default:
            return nil
        }
    }

    // MARK: Private

    private func performKill(signal: Int32) {
        guard let proc = state.selectedProcess else { return }
        guard killFn(proc.pid, signal) else { return }
        state.remove(pid: proc.pid)
    }
}

// MARK: - Plugin

class KillProcessPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    static func launcherPluginName()        -> String { "Kill Process" }
    static func launcherPluginDescription() -> String { "Find and kill any running process." }
    static func launcherPluginIcon()        -> String { "xmark.circle.fill" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier    = "kill-process-root"
        r.title             = "Kill Process"
        r.subtitle          = "Browse and kill running processes"
        r.systemImageName   = "xmark.circle.fill"
        r.surfaceIdentifier = "process-list"
        r.trailingHint      = "Browse"
        return [r]
    }

    func launcherSurface(
        forItemIdentifier itemIdentifier: String,
        surfaceIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard itemIdentifier == "kill-process-root",
              surfaceIdentifier == "process-list" else { return nil }
        return ProcessListSurface(killFn: { pidStr, sig in
            guard let pid = Int32(pidStr) else { return false }
            return Darwin.kill(pid_t(pid), sig) == 0
        })
    }
}
