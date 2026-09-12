// BTT-Plugin-Name: Internet Speed Test
// BTT-Plugin-Identifier: com.btt.ai.speedtest.launcher
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: speedometer

import AppKit
import SwiftUI
import Foundation

class SpeedTestLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let runTest = "run-speed-test"
        static let surface = "speed-test-surface"
    }

    static func launcherPluginName() -> String { "Internet Speed Test" }
    static func launcherPluginDescription() -> String { "Run a native macOS networkQuality speed test inside BTT Launcher." }
    static func launcherPluginIcon() -> String { "speedometer" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let query = (context.query ?? "").lowercased()
        if !query.isEmpty {
            let searchable = "speed test internet network bandwidth download upload ping"
            if !searchable.contains(query) && !"internet speed test".contains(query) {
                return nil
            }
        }

        let result = BTTLauncherPluginResult()
        result.itemIdentifier = IDs.runTest
        result.title = "Test Internet Speed"
        result.subtitle = "Measures download, upload, responsiveness, and latency using macOS networkQuality."
        result.systemImageName = "speedometer"
        result.surfaceIdentifier = IDs.surface
        result.trailingHint = "Run"
        result.keywords = ["speed", "speedtest", "internet", "network", "bandwidth", "download", "upload", "ping"]
        result.searchMatchPriority = 80

        let command = BTTLauncherPluginCommand()
        command.commandIdentifier = "open"
        command.title = "Run Speed Test"
        command.subtitle = "Open the detailed speed test panel."
        command.systemImageName = "play.circle"
        command.surfaceIdentifier = IDs.surface
        command.closesLauncherOnSuccess = false
        result.commands = [command]

        return [result]
    }

    func launcherSurface(
        forItemIdentifier itemIdentifier: String,
        surfaceIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard itemIdentifier == IDs.runTest, surfaceIdentifier == IDs.surface else { return nil }
        return SpeedTestSurface()
    }
}

final class SpeedTestSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private let model = SpeedTestModel()

    func makeLauncherSurfaceView() -> NSView {
        NSHostingView(rootView: SpeedTestView(model: model))
    }

    func launcherSurfaceDidAppear() {
        model.startTest()
    }

    func launcherSurfaceWillDisappear() {
        model.cancel()
    }

    func launcherSurfacePreferredContentSize() -> CGSize {
        CGSize(width: 790, height: 500)
    }

    func launcherSurfaceMinimumContentSize() -> CGSize {
        CGSize(width: 790, height: 500)
    }

    func launcherSurfacePlaceholderText() -> String? {
        "Internet Speed Test"
    }

    func launcherSurfaceFooterHint() -> String? {
        nil
    }

    func launcherSurfaceStatusText() -> String? {
        nil
    }

    func launcherSurfaceKeepsLauncherPinned() -> Bool { true }

    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        return nil
    }
}

final class SpeedTestModel: ObservableObject, @unchecked Sendable {
    @Published var status: String = "Ready"
    @Published var isRunning: Bool = false
    @Published var download: String = "—"
    @Published var upload: String = "—"
    @Published var latency: String = "—"
    @Published var responsiveness: String = "—"
    @Published var rawOutput: String = ""
    @Published var errorMessage: String? = nil
    @Published var finished: Bool = false
    @Published var downloadMbps: Double = 0
    @Published var uploadMbps: Double = 0
    @Published var latencyMs: Double = 0
    @Published var responsivenessValue: Double = 0
    @Published var endpoint: String = "—"
    @Published var interfaceName: String = "—"
    @Published var transferred: String = "—"
    @Published var liveDownloadMbps: Double = 0
    @Published var liveUploadMbps: Double = 0
    @Published var peakDownloadMbps: Double = 0
    @Published var peakUploadMbps: Double = 0
    @Published var downloadSamples: [Double] = Array(repeating: 0, count: 18)
    @Published var uploadSamples: [Double] = Array(repeating: 0, count: 18)

    private var process: Process?
    private var sampleTimer: Timer?
    private var lastSample: (time: Date, rx: Double, tx: Double)?

    func startTest() {
        guard !isRunning else { return }
        reset()

        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: "/usr/bin/networkQuality")
        process.arguments = ["-c"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.appendOutput(chunk)
            }
        }

        do {
            isRunning = true
            status = "Running"
            startSamplingNetworkThroughput()
            try process.run()
            DispatchQueue.global(qos: .utility).async { [weak self, weak process] in
                process?.waitUntilExit()
                let code = process?.terminationStatus ?? -1
                DispatchQueue.main.async {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    self?.complete(code: code)
                }
            }
        } catch {
            isRunning = false
            finished = true
            status = "Failed"
            errorMessage = "Could not start /usr/bin/networkQuality: \(error.localizedDescription)"
        }
    }

    func cancel() {
        stopSamplingNetworkThroughput()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    private func reset() {
        status = "Starting"
        isRunning = false
        download = "—"
        upload = "—"
        latency = "—"
        responsiveness = "—"
        rawOutput = ""
        errorMessage = nil
        finished = false
        downloadMbps = 0
        uploadMbps = 0
        latencyMs = 0
        responsivenessValue = 0
        endpoint = "—"
        interfaceName = "—"
        transferred = "—"
        liveDownloadMbps = 0
        liveUploadMbps = 0
        peakDownloadMbps = 0
        peakUploadMbps = 0
        downloadSamples = Array(repeating: 0, count: 18)
        uploadSamples = Array(repeating: 0, count: 18)
        lastSample = nil
        stopSamplingNetworkThroughput()
    }

    private func appendOutput(_ chunk: String) {
        rawOutput += chunk
        parse(rawOutput)
    }

    private func complete(code: Int32) {
        isRunning = false
        finished = true
        stopSamplingNetworkThroughput()
        parse(rawOutput)
        if code == 0 {
            status = "Finished"
        } else if errorMessage == nil {
            status = "Failed"
            errorMessage = "networkQuality exited with status \(code)."
        }
    }

    private func parse(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.hasPrefix("{"), let data = trimmedText.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parseJSON(object)
            return
        }

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("download capacity:") {
                download = value(afterColonIn: trimmed)
            } else if lower.hasPrefix("upload capacity:") {
                upload = value(afterColonIn: trimmed)
            } else if lower.hasPrefix("responsiveness:") {
                responsiveness = value(afterColonIn: trimmed)
            } else if lower.contains("idle latency:") {
                latency = parseLatency(from: trimmed) ?? latency
            } else if lower.contains("error") || lower.contains("failed") {
                if errorMessage == nil { errorMessage = trimmed }
            }
        }
    }

    private func parseJSON(_ json: [String: Any]) {
        if let value = number(json["dl_throughput"]) {
            downloadMbps = value / 1_000_000
            peakDownloadMbps = max(peakDownloadMbps, downloadMbps)
            appendSample(downloadMbps, to: &downloadSamples)
            download = formatBitsPerSecond(value)
        }
        if let value = number(json["ul_throughput"]) {
            uploadMbps = value / 1_000_000
            peakUploadMbps = max(peakUploadMbps, uploadMbps)
            appendSample(uploadMbps, to: &uploadSamples)
            upload = formatBitsPerSecond(value)
        }
        if let value = number(json["base_rtt"]) {
            latencyMs = value
            latency = String(format: "%.1f ms", value)
        }
        if let value = number(json["responsiveness"]) {
            responsivenessValue = value
            responsiveness = String(format: "%.1f RPM", value)
        }
        if let value = json["test_endpoint"] as? String { endpoint = value }
        if let value = json["interface_name"] as? String { interfaceName = value }
        let dlBytes = number(json["dl_bytes_transferred"]) ?? 0
        let ulBytes = number(json["ul_bytes_transferred"]) ?? 0
        if dlBytes > 0 || ulBytes > 0 {
            transferred = "↓ \(formatBytes(dlBytes))  ↑ \(formatBytes(ulBytes))"
        }
    }

    private func startSamplingNetworkThroughput() {
        stopSamplingNetworkThroughput()
        lastSample = readInterfaceCounters()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sampleNetworkThroughput()
        }
        sampleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSamplingNetworkThroughput() {
        sampleTimer?.invalidate()
        sampleTimer = nil
    }

    private func sampleNetworkThroughput() {
        guard isRunning, let current = readInterfaceCounters() else { return }
        defer { lastSample = current }
        guard let previous = lastSample else { return }
        let seconds = max(current.time.timeIntervalSince(previous.time), 0.25)
        let rxBits = max(current.rx - previous.rx, 0) * 8
        let txBits = max(current.tx - previous.tx, 0) * 8
        liveDownloadMbps = rxBits / seconds / 1_000_000
        liveUploadMbps = txBits / seconds / 1_000_000
        peakDownloadMbps = max(peakDownloadMbps, liveDownloadMbps)
        peakUploadMbps = max(peakUploadMbps, liveUploadMbps)
        appendSample(liveDownloadMbps, to: &downloadSamples)
        appendSample(liveUploadMbps, to: &uploadSamples)
        if liveDownloadMbps > 0.05 { download = String(format: "%.2f Mbps", liveDownloadMbps) }
        if liveUploadMbps > 0.05 { upload = String(format: "%.2f Mbps", liveUploadMbps) }
    }

    private func appendSample(_ value: Double, to samples: inout [Double]) {
        samples.append(value)
        if samples.count > 18 { samples.removeFirst(samples.count - 18) }
    }

    private func readInterfaceCounters() -> (time: Date, rx: Double, tx: Double)? {
        let interface = interfaceName == "—" ? "en0" : interfaceName
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ib", "-I", interface]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            return parseNetstatCounters(output)
        } catch {
            return nil
        }
    }

    private func parseNetstatCounters(_ output: String) -> (time: Date, rx: Double, tx: Double)? {
        let lines = output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return nil }
        let headerParts = header.split { $0 == " " || $0 == "\t" }.map(String.init)
        guard let rxIndex = headerParts.firstIndex(of: "Ibytes"),
              let txIndex = headerParts.firstIndex(of: "Obytes") else { return nil }
        for line in lines.dropFirst().reversed() {
            let parts = line.split { $0 == " " || $0 == "\t" }.map(String.init)
            if parts.count > max(rxIndex, txIndex), let rx = Double(parts[rxIndex]), let tx = Double(parts[txIndex]) {
                return (Date(), rx, tx)
            }
        }
        return nil
    }

    private func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private func formatBytes(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB", bytes / 1_000) }
        return String(format: "%.0f B", bytes)
    }

    private func formatBitsPerSecond(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000_000 {
            return String(format: "%.2f Gbps", bitsPerSecond / 1_000_000_000)
        } else if bitsPerSecond >= 1_000_000 {
            return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
        } else if bitsPerSecond >= 1_000 {
            return String(format: "%.1f Kbps", bitsPerSecond / 1_000)
        }
        return String(format: "%.0f bps", bitsPerSecond)
    }

    private func value(afterColonIn line: String) -> String {
        guard let range = line.range(of: ":") else { return line }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseLatency(from line: String) -> String? {
        guard let range = line.range(of: "Idle Latency:", options: [.caseInsensitive]) else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SpeedTestView: View {
    @ObservedObject var model: SpeedTestModel

    private var displayDownloadMbps: Double { model.isRunning ? model.liveDownloadMbps : max(model.downloadMbps, model.liveDownloadMbps) }
    private var displayUploadMbps: Double { model.isRunning ? model.liveUploadMbps : max(model.uploadMbps, model.liveUploadMbps) }
    private var displayDownload: String { rateString(displayDownloadMbps) }
    private var displayUpload: String { rateString(displayUploadMbps) }
    private var downloadProgress: Double { min(max(displayDownloadMbps / 100.0, 0), 1) }
    private var uploadProgress: Double { min(max(displayUploadMbps / 50.0, 0), 1) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 14) {
                HStack(spacing: 34) {
                    GaugeDial(title: "Download", value: displayDownload, progress: downloadProgress, color: .blue, isRunning: model.isRunning)
                    GaugeDial(title: "Upload", value: displayUpload, progress: uploadProgress, color: .purple, isRunning: model.isRunning)
                }
                graphRow
                bottomStats
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.callout)
                }

            }
            .frame(width: 510, height: 420, alignment: .top)

            ScrollView(.vertical, showsIndicators: true) {
                sidePanel
                    .frame(width: 210, alignment: .top)
            }
            .frame(width: 224, height: 420, alignment: .top)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: 770, height: 470, alignment: .topLeading)
        .background(Color.clear)
    }

    private var graphRow: some View {
        HStack(spacing: 14) {
            MiniGraph(title: "Download over time", value: displayDownload, peak: rateString(model.peakDownloadMbps), samples: model.downloadSamples, color: .blue, active: model.isRunning)
            MiniGraph(title: "Upload over time", value: displayUpload, peak: rateString(model.peakUploadMbps), samples: model.uploadSamples, color: .purple, active: model.isRunning)
        }
    }

    private var bottomStats: some View {
        HStack(spacing: 10) {
            SmallStat(title: "Ping", value: model.latency, color: .yellow, icon: "circle.fill")
            SmallStat(title: "Download", value: displayDownload, color: .blue, icon: "arrow.down.circle.fill")
            SmallStat(title: "Upload", value: displayUpload, color: .purple, icon: "arrow.up.circle.fill")
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Status")
            HStack(alignment: .center, spacing: 8) {
                Label(model.status, systemImage: model.finished && model.errorMessage == nil ? "checkmark.circle.fill" : (model.errorMessage == nil ? "circle.dashed" : "xmark.octagon.fill"))
                    .foregroundColor(model.errorMessage == nil ? .green : .orange)
                    .font(.headline)
                Spacer(minLength: 4)
                Button(action: { model.startTest() }) {
                    Image(systemName: model.isRunning ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .help(model.isRunning ? "Speed test is running" : "Test again")
            }

            Divider().opacity(0.35)
            SectionHeader("Quality")
            CapabilityRow(title: "Voice Call", items: model.latencyMs > 0 && model.latencyMs < 150 ? ["SD", "HD"] : ["SD"])
            CapabilityRow(title: "Video Call", items: displayDownloadMbps > 5 ? ["480", "720"] : ["480"])
            Label(displayDownloadMbps > 25 ? "Good for streaming" : "Not enough bandwidth", systemImage: displayDownloadMbps > 25 ? "play.tv.fill" : "play.tv")
                .foregroundColor(displayDownloadMbps > 25 ? .green : .secondary)
                .font(.callout.weight(.semibold))

            Divider().opacity(0.35)
            SectionHeader("Network Details")
            DetailLine(label: "Interface", value: model.interfaceName)
            DetailLine(label: "Endpoint", value: model.endpoint)
            DetailLine(label: "Transferred", value: model.transferred)
            DetailLine(label: "Responsiveness", value: model.responsiveness)

        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.bottom, 10)
    }

    private func SectionHeader(_ text: String) -> some View {
        Text(text).font(.caption.weight(.bold)).foregroundColor(.secondary).textCase(.uppercase)
    }

    private func rateString(_ mbps: Double) -> String {
        if mbps <= 0 { return "—" }
        if mbps >= 1000 { return String(format: "%.2f Gbps", mbps / 1000) }
        return String(format: "%.2f Mbps", mbps)
    }
}

struct GaugeDial: View {
    let title: String
    let value: String
    let progress: Double
    let color: Color
    let isRunning: Bool

    private var speedParts: (number: String, unit: String) {
        let pieces = value.split(separator: " ", maxSplits: 1).map(String.init)
        if pieces.count == 2 { return (pieces[0], pieces[1]) }
        return (value, "")
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .trim(from: 0.10, to: 0.90)
                    .stroke(Color.secondary.opacity(0.20), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle()
                    .trim(from: 0.10, to: 0.10 + 0.80 * progress)
                    .stroke(AngularGradient(colors: [color.opacity(0.65), color], center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .shadow(color: color.opacity(isRunning ? 0.55 : 0.25), radius: isRunning ? 10 : 4)
                    .animation(.spring(response: 1.0, dampingFraction: 0.8), value: progress)

                VStack(spacing: 0) {
                    Text(speedParts.number)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    if !speedParts.unit.isEmpty {
                        Text(speedParts.unit)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                            .textCase(.none)
                    }
                }
                .padding(.top, 6)
            }
            .frame(width: 180, height: 150)

            Text(title)
                .font(.callout.weight(.bold))
                .foregroundColor(color)
                .padding(.top, 0)
        }
        .frame(width: 180, height: 185)
    }
}

struct MiniGraph: View {
    let title: String
    let value: String
    let peak: String
    let samples: [Double]
    let color: Color
    let active: Bool

    private var effectiveSamples: [Double] {
        samples.isEmpty ? Array(repeating: 0, count: 18) : samples
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.semibold)).foregroundColor(.secondary)
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let maxValue = max(effectiveSamples.max() ?? 1, 1)
                    Path { path in
                        for index in effectiveSamples.indices {
                            let x = geo.size.width * CGFloat(index) / CGFloat(max(effectiveSamples.count - 1, 1))
                            let normalized = min(max(effectiveSamples[index] / maxValue, 0), 1)
                            let y = geo.size.height - (geo.size.height * 0.72 * CGFloat(normalized)) - 4
                            if index == effectiveSamples.startIndex { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: color.opacity(active ? 0.65 : 0.25), radius: active ? 7 : 2)
                    .animation(.easeInOut(duration: 0.45), value: effectiveSamples)
                }
                .frame(height: 43)
                .padding(.horizontal, 8)
                .padding(.top, 8)

                HStack {
                    Text("peak " + peak)
                    Spacer()
                    Text(value).fontWeight(.bold)
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(.primary.opacity(0.82))
                .padding(.horizontal, 10)
                .padding(.top, 3)
                .padding(.bottom, 8)
                .background(Color.black.opacity(0.10))
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(height: 76)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.secondary.opacity(0.07)))
    }
}

struct SmallStat: View {
    let title: String
    let value: String
    let color: Color
    let icon: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                Text(value).font(.callout.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.15)))
    }
}

struct CapabilityRow: View {
    let title: String
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundColor(.secondary)
            HStack { ForEach(items, id: \.self) { Text($0).font(.caption.weight(.bold)).padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.blue.opacity(0.22))) } }
        }
    }
}

struct DetailLine: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
            Text(value).font(.caption).lineLimit(2).minimumScaleFactor(0.7)
        }
    }
}