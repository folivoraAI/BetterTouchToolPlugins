// BTT-Plugin-Name: Media Downloader
// BTT-Plugin-Identifier: com.loay.btt.media-downloader
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: arrow.down.circle.fill
//
// BetterTouchTool Swift Source Launcher Plugin
// Media Downloader for BTT Launcher.
// Download video or audio from YouTube, Facebook, Instagram, TikTok and many
// other yt-dlp supported sites using a minimal one-page UI.
//
// Requirements:
// - BetterTouchTool with Swift plugins enabled
// - Homebrew at /opt/homebrew/bin/brew
// - yt-dlp, ffmpeg and ffprobe at /opt/homebrew/bin/
//
// The plugin includes an Update button that can install/update yt-dlp and FFmpeg
// through Homebrew. Only download media you own or have permission to download.

import AppKit
import Foundation
import SwiftUI
import Combine

final class VideoDownloader: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    let ytDLP = "/opt/homebrew/bin/yt-dlp"
    let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    let ffprobe = "/opt/homebrew/bin/ffprobe"
    let brew = "/opt/homebrew/bin/brew"
    let ffmpegLocation = "/opt/homebrew/bin"

    static func launcherPluginName() -> String { "Media Downloader" }
    static func launcherPluginDescription() -> String { "YouTube, Facebook, Instagram, TikTok and more downloader." }
    static func launcherPluginIcon() -> String { "arrow.down.circle.fill" }
    static func configurationFormItems() -> BTTPluginFormItem? { nil }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = "media-downloader-dashboard"
        result.title = "Media Downloader"
        result.subtitle = firstURL(in: context.query ?? "") == nil ? "YouTube, Facebook, Instagram, TikTok and more downloader" : "URL detected — open media downloader"
        result.systemImageName = "arrow.down.circle.fill"
        result.surfaceIdentifier = "media-downloader-dashboard-surface"
        result.trailingHint = "Open"
        result.keywords = ["youtube", "yt-dlp", "download", "video", "audio", "mp3", "mp4", "media"]
        if firstURL(in: context.query ?? "") != nil { result.searchMatchPriority = NSNumber(value: 95) }
        return [result]
    }

    func launcherSurface(forItemIdentifier itemIdentifier: String, surfaceIdentifier: String?, context: BTTLauncherPluginContext) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard (surfaceIdentifier ?? itemIdentifier) == "media-downloader-dashboard-surface" else { return nil }
        return VideoDownloaderDashboardSurface(plugin: self, context: context)
    }

    func performAction(forItemIdentifier itemIdentifier: String, actionIdentifier: String?, context: BTTLauncherPluginContext) -> BTTLauncherPluginActionResult? {
        let result = BTTLauncherPluginActionResult()
        result.success = true
        result.closeLauncher = false
        result.message = "Open the Media Downloader surface."
        return result
    }

    func suggestedURL(for context: BTTLauncherPluginContext) -> String {
        firstURL(in: context.query ?? "") ?? firstURL(in: NSPasteboard.general.string(forType: .string) ?? "") ?? ""
    }

    func defaultDownloadDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("BTT Media Downloads", isDirectory: true)
    }

    func lastLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("BTTMediaDownloader.log")
    }

    func prepareLogFile() -> URL {
        let logURL = lastLogURL()
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { _ = FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        return logURL
    }

    func openDownloadFolder() {
        let folder = defaultDownloadDirectory()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func copyLastLog() -> Bool {
        let log = (try? String(contentsOf: lastLogURL(), encoding: .utf8)) ?? "No log found."
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(log, forType: .string)
    }

    @discardableResult
    func startToolUpdate(progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let script = """
        set -euo pipefail
        export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        if [ ! -x "\(brew)" ]; then
          echo "Homebrew was not found at \(brew)"
          exit 1
        fi
        "\(brew)" update
        "\(brew)" list yt-dlp >/dev/null 2>&1 || "\(brew)" install yt-dlp
        "\(brew)" list ffmpeg >/dev/null 2>&1 || "\(brew)" install ffmpeg
        "\(brew)" upgrade yt-dlp ffmpeg
        test -x "\(ytDLP)"
        test -x "\(ffmpeg)"
        test -x "\(ffprobe)"
        """
        return runShell(script: script, progress: progress, completion: completion)
    }

    func fetchThumbnail(for videoURL: String, completion: @escaping (NSImage?) -> Void) {
        guard let validatedURL = validatedHTTPURLString(videoURL),
              FileManager.default.isExecutableFile(atPath: ytDLP) else { completion(nil); return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytDLP)
        task.arguments = [
            "--ignore-config",
            "--no-warnings",
            "--skip-download",
            "--playlist-items", "1",
            "--print", "thumbnail",
            "--", validatedURL
        ]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        var output = Data()
        var didComplete = false
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            if output.count < 64_000 { output.append(data) }
        }

        task.terminationHandler = { process in
            handle.readabilityHandler = nil
            DispatchQueue.main.async {
                guard !didComplete else { return }
                didComplete = true
                guard process.terminationStatus == 0,
                      let text = String(data: output, encoding: .utf8),
                      let firstLine = text.components(separatedBy: .newlines)
                        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                        .first(where: { $0.hasPrefix("http://") || $0.hasPrefix("https://") }),
                      let imageURL = URL(string: firstLine) else {
                    completion(nil)
                    return
                }
                URLSession.shared.dataTask(with: imageURL) { data, _, _ in
                    let image = data.flatMap { NSImage(data: $0) }
                    DispatchQueue.main.async { completion(image) }
                }.resume()
            }
        }

        do {
            try task.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12) {
                if task.isRunning { task.terminate() }
            }
        } catch {
            handle.readabilityHandler = nil
            completion(nil)
        }
    }

    func makeDownloadArguments(mode: DownloadMode, url: String, videoPreset: String, customFormat: String, audioFormat: String, audioQuality: String, folder: URL) -> [String]? {
        guard let validatedURL = validatedHTTPURLString(url) else { return nil }
        let isPlaylist = shouldDownloadPlaylist(validatedURL)
        let fileNameTemplate = "%(title).180B - %(channel,uploader,creator|Unknown Channel).80B.%(ext)s"
        let outputTemplate = isPlaylist
            ? "%(playlist_title).180B/" + fileNameTemplate
            : fileNameTemplate

        var args = [
            "--ignore-config",
            "--newline",
            "--no-color",
            "--no-warnings",
            "--no-simulate",
            "--progress",
            "--progress-template", "download:download:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "after_move:filepath",
            "--ffmpeg-location", ffmpegLocation,
            "-P", folder.path,
            "-o", outputTemplate,
            isPlaylist ? "--yes-playlist" : "--no-playlist"
        ]

        switch mode {
        case .video:
            let format = videoFormatSelector(preset: videoPreset, customFormat: customFormat)
            args += ["-f", format.selector]
            if let merge = format.mergeFormat { args += ["--merge-output-format", merge] }
        case .audio:
            let formatMap = ["MP3": "mp3", "M4A": "m4a", "WAV": "wav", "Opus": "opus", "FLAC": "flac"]
            args += ["-x", "--audio-format", formatMap[audioFormat] ?? "mp3", "--add-metadata"]
            if audioFormat != "WAV" && audioFormat != "FLAC" {
                let qualityMap = ["Best": "0", "320 kbps": "320K", "256 kbps": "256K", "192 kbps": "192K", "128 kbps": "128K"]
                args += ["--audio-quality", qualityMap[audioQuality] ?? "0"]
            }
        }
        args += ["--", validatedURL]
        return args
    }

    func runYTDLP(arguments: [String], progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let missing = [ytDLP, ffmpeg, ffprobe].filter { !FileManager.default.isExecutableFile(atPath: $0) }
        guard missing.isEmpty else {
            progress("Missing tools: " + missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))
            completion(false)
            return nil
        }
        return runProcess(executable: ytDLP, arguments: arguments, progress: progress, completion: completion)
    }

    @discardableResult
    private func runShell(script: String, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        runProcess(executable: "/bin/zsh", arguments: ["-lc", script], progress: progress, completion: completion)
    }

    private func runProcess(executable: String, arguments: [String], progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let logURL = prepareLogFile()
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let file = try? FileHandle(forWritingTo: logURL) {
                try? file.seekToEnd()
                if let d = text.data(using: .utf8) { try? file.write(contentsOf: d) }
                try? file.close()
            }
            DispatchQueue.main.async { progress(text) }
        }
        task.terminationHandler = { process in
            handle.readabilityHandler = nil
            DispatchQueue.main.async { completion(process.terminationStatus == 0) }
        }
        do {
            try task.run()
            return task
        } catch {
            progress("Could not start: \(error.localizedDescription)")
            completion(false)
            return nil
        }
    }

    private func videoFormatSelector(preset: String, customFormat: String) -> (selector: String, mergeFormat: String?) {
        if preset == "Custom yt-dlp selector" { return (customFormat.isEmpty ? "bestvideo+bestaudio/best" : customFormat, nil) }
        let components = preset.components(separatedBy: " | ")
        let quality = components.first ?? "1080p"
        let container = components.count > 1 ? components[1] : "MP4"
        let heights = ["2160p / 4K": 2160, "1440p / 2K": 1440, "1080p": 1080, "720p": 720, "480p": 480, "360p": 360]
        let cap = heights[quality].map { "[height<=\($0)]" } ?? ""
        switch container {
        case "MP4": return ("bestvideo\(cap)[ext=mp4]+bestaudio[ext=m4a]/best\(cap)[ext=mp4]/best\(cap)", "mp4")
        case "MKV": return ("bestvideo\(cap)+bestaudio/best\(cap)/best", "mkv")
        case "WebM": return ("bestvideo\(cap)[ext=webm]+bestaudio[ext=webm]/best\(cap)[ext=webm]/best\(cap)", "webm")
        default: return ("bestvideo\(cap)+bestaudio/best\(cap)/best", nil)
        }
    }

    func willDownloadPlaylist(_ url: String) -> Bool {
        guard let validatedURL = validatedHTTPURLString(url) else { return false }
        return shouldDownloadPlaylist(validatedURL)
    }

    func validatedHTTPURLString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty,
              let url = components.url else { return nil }
        return url.absoluteString
    }

    private func shouldDownloadPlaylist(_ url: String) -> Bool {
        guard let components = URLComponents(string: url), let items = components.queryItems else { return false }
        return items.contains { $0.name.lowercased() == "list" && !($0.value ?? "").isEmpty }
    }

    private func firstURL(in text: String) -> String? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'"))
            if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") { return String(cleaned) }
        }
        return nil
    }
}

enum DownloadMode: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    var id: String { rawValue }
}

final class VideoDownloaderDashboardSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private weak var plugin: VideoDownloader?
    private let context: BTTLauncherPluginContext
    private var model: VideoDownloaderViewModel?
    private var commandKeyWasDown = false
    private var commandEventMonitor: Any?

    init(plugin: VideoDownloader, context: BTTLauncherPluginContext) {
        self.plugin = plugin
        self.context = context
        super.init()
    }

    func makeLauncherSurfaceView() -> NSView {
        let model = VideoDownloaderViewModel(plugin: plugin, context: context)
        self.model = model
        return NSHostingView(rootView: VideoDownloaderDashboardView(model: model))
    }

    func launcherSurfaceDidAppear() {
        commandEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            _ = self?.handleCommandFlags(event)
            return event
        }
    }

    func launcherSurfaceWillDisappear() {
        if let commandEventMonitor {
            NSEvent.removeMonitor(commandEventMonitor)
            self.commandEventMonitor = nil
        }
        commandKeyWasDown = false
    }

    private func handleCommandFlags(_ event: NSEvent) -> Bool {
        let commandIsDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if commandIsDown && !commandKeyWasDown {
            commandKeyWasDown = true
            model?.toggleMode()
            return true
        }
        commandKeyWasDown = commandIsDown
        return false
    }

    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            return handleCommandFlags(event)
        }

        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 36, 76: // Return / Enter
            model?.start()
            return true
        case 48: // Tab cycles format reliably inside BTT Launcher
            model?.cycleFormat(backwards: event.modifierFlags.contains(.shift))
            return true
        default:
            return false
        }
    }

    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 850, height: 440) }
    func launcherSurfaceMinimumContentSize() -> CGSize { CGSize(width: 720, height: 410) }
    func launcherSurfacePlaceholderText() -> String? { "Paste a video URL" }
    func launcherSurfaceFooterHint() -> String? { "⌘ Command: Switch Video/Audio • ↩ Enter: Download • ⇥ Tab: Change Format" }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { true }
}

final class VideoDownloaderViewModel: ObservableObject {
    @Published var mode: DownloadMode = .video
    @Published var url: String
    @Published var videoPreset = "Best available | Original"
    @Published var customFormat = "bestvideo+bestaudio/best"
    @Published var audioFormat = "MP3"
    @Published var audioQuality = "Best"
    @Published var folderPath: String
    @Published var status = "Ready"
    @Published var detail = "Paste a URL and choose a format."
    @Published var progress: Double = 0
    @Published var speed = "—"
    @Published var eta = "—"
    @Published var isRunning = false
    @Published var thumbnail: NSImage?

    let videoPresets = ["Best available | Original", "2160p / 4K | MP4", "1440p / 2K | MP4", "1080p | MP4", "720p | MP4", "480p | MP4", "360p | MP4", "1080p | MKV", "720p | WebM", "Custom yt-dlp selector"]
    let audioFormats = ["MP3", "M4A", "WAV", "Opus", "FLAC"]
    let audioQualities = ["Best", "320 kbps", "256 kbps", "192 kbps", "128 kbps"]

    private weak var plugin: VideoDownloader?
    private var task: Process?
    private var progressTimer: Timer?
    private var cancellationRequested = false
    private var lastThumbnailURL = ""

    init(plugin: VideoDownloader?, context: BTTLauncherPluginContext) {
        self.plugin = plugin
        self.url = plugin?.suggestedURL(for: context) ?? ""
        self.folderPath = plugin?.defaultDownloadDirectory().path ?? ""
        refreshThumbnailIfNeeded()
    }

    func refreshThumbnailIfNeeded() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastThumbnailURL, !trimmed.isEmpty else { return }
        lastThumbnailURL = trimmed
        plugin?.fetchThumbnail(for: trimmed) { [weak self] image in self?.thumbnail = image }
    }

    func start() {
        guard !isRunning else { return }
        guard let plugin else { fail("Plugin not available."); return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plugin.validatedHTTPURLString(trimmed) != nil else { fail("Please paste a valid http(s) URL."); return }
        refreshThumbnailIfNeeded()
        let folder = URL(fileURLWithPath: folderPath.isEmpty ? plugin.defaultDownloadDirectory().path : folderPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let args = plugin.makeDownloadArguments(mode: mode, url: trimmed, videoPreset: videoPreset, customFormat: customFormat, audioFormat: audioFormat, audioQuality: audioQuality, folder: folder) else {
            fail("Please paste a valid http(s) URL.")
            return
        }

        progress = 0
        speed = "—"
        eta = "—"
        cancellationRequested = false
        isRunning = true
        beginLiveProgress()
        status = mode == .video ? "Downloading video…" : "Downloading audio…"
        detail = plugin.willDownloadPlaylist(trimmed) ? "Starting playlist download into its own folder." : "Starting yt-dlp."
        task = plugin.runYTDLP(arguments: args, progress: { [weak self] text in self?.consumeOutput(text) }, completion: { [weak self] success in
            guard let self else { return }
            self.isRunning = false
            self.stopLiveProgress()
            if self.cancellationRequested {
                self.status = "Cancelled"
                self.detail = "The active operation was stopped."
                self.cancellationRequested = false
                return
            }
            self.progress = success ? 1 : self.progress
            self.status = success ? "Finished" : "Failed"
            self.detail = success ? "Download completed." : "Download failed. Copy Last Log for details."
        })
    }

    func cancel() {
        guard let task, task.isRunning else { return }
        cancellationRequested = true
        status = "Cancelling…"
        detail = "Stopping the active operation."
        task.terminate()
    }

    func updateTools() {
        guard !isRunning else { return }
        guard let plugin else { fail("Plugin not available."); return }
        cancellationRequested = false
        isRunning = true
        progress = 0
        beginLiveProgress()
        status = "Updating yt-dlp…"
        detail = "Homebrew is checking yt-dlp and FFmpeg."
        task = plugin.startToolUpdate(progress: { [weak self] text in self?.consumeOutput(text) }, completion: { [weak self] success in
            guard let self else { return }
            self.isRunning = false
            self.stopLiveProgress()
            if self.cancellationRequested {
                self.status = "Cancelled"
                self.detail = "The update was stopped."
                self.cancellationRequested = false
                return
            }
            self.progress = success ? 1 : 0
            self.status = success ? "Tools updated" : "Tool update failed"
            self.detail = success ? "yt-dlp and FFmpeg are ready." : "Copy Last Log for details."
        })
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }

    func toggleMode() {
        mode = mode == .video ? .audio : .video
    }

    func cycleFormat(backwards: Bool = false) {
        if mode == .video {
            guard let current = videoPresets.firstIndex(of: videoPreset) else {
                videoPreset = videoPresets.first ?? videoPreset
                return
            }
            let next = backwards
                ? (current - 1 + videoPresets.count) % videoPresets.count
                : (current + 1) % videoPresets.count
            videoPreset = videoPresets[next]
        } else {
            guard let current = audioFormats.firstIndex(of: audioFormat) else {
                audioFormat = audioFormats.first ?? audioFormat
                return
            }
            let next = backwards
                ? (current - 1 + audioFormats.count) % audioFormats.count
                : (current + 1) % audioFormats.count
            audioFormat = audioFormats[next]
        }
    }

    func copyLog() {
        if plugin?.copyLastLog() == true {
            status = "Log copied"
            detail = "The last log is now on your clipboard."
        } else { fail("Could not copy the log.") }
    }

    private func consumeOutput(_ text: String) {
        noteActivity()
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("download:") {
                let payload = String(line.dropFirst("download:".count))
                let parts = payload.components(separatedBy: "|")
                if parts.count >= 3 {
                    updateProgress(percent: parts[0], speedText: parts[1], etaText: parts[2])
                }
            } else if let percentRange = line.range(of: #"\d+(?:\.\d+)?%"#, options: .regularExpression) {
                let percentText = String(line[percentRange])
                let speedText = firstMatch(in: line, pattern: #"at\s+([^\s]+/s)"#) ?? speed
                let etaText = firstMatch(in: line, pattern: #"ETA\s+([^\s]+)"#) ?? eta
                updateProgress(percent: percentText, speedText: speedText, etaText: etaText)
            } else if line.hasPrefix("/") || line.contains(".mp4") || line.contains(".webm") || line.contains(".mp3") || line.contains(".m4a") {
                detail = line
            }
        }
    }

    private func updateProgress(percent: String, speedText: String, etaText: String) {
        let cleanedPercent = percent.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let p = Double(cleanedPercent) { progress = min(max(p / 100.0, 0), 1) }
        speed = speedText.trimmingCharacters(in: .whitespaces)
        eta = etaText.trimmingCharacters(in: .whitespaces)
        status = "Downloading"
        detail = "\(Int(progress * 100))% • \(speed) • ETA \(eta)"
    }

    private func beginLiveProgress() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            // yt-dlp only reports exact percentages during the download phase.
            // During resolving, extracting info, playlist preparation, merging and post-processing,
            // keep the bar alive but never fake-complete it. Real percent output still overrides this.
            if self.progress < 0.92 {
                let step = self.progress < 0.12 ? 0.018 : 0.006
                self.progress = min(self.progress + step, 0.92)
            }
            if self.status == "Downloading video…" || self.status == "Downloading audio…" {
                self.status = "Processing"
            }
        }
    }

    private func stopLiveProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func noteActivity() {
        if isRunning && progress < 0.06 { progress = 0.06 }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func fail(_ message: String) {
        status = "Needs attention"
        detail = message
    }
}

struct VideoDownloaderDashboardView: View {
    @ObservedObject var model: VideoDownloaderViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                header
                controls
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            previewAndProgress
        }
        .padding(18)
        .frame(width: 806, height: 356, alignment: .top)
        .background(Color.clear)
        .onChange(of: model.url) { _ in model.refreshThumbnailIfNeeded() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Media Downloader").font(.title2.weight(.semibold))
                Text("YouTube, Facebook, Instagram, TikTok and more downloader.").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("URL") {
                TextField("https://youtu.be/…", text: $model.url)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.start() }
            }

            field("Mode & Format") {
                HStack(spacing: 10) {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(DownloadMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)

                    if model.mode == .video {
                        Picker("Format", selection: $model.videoPreset) {
                            ForEach(model.videoPresets, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("Format", selection: $model.audioFormat) {
                            ForEach(model.audioFormats, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)

                        if model.audioFormat != "WAV" && model.audioFormat != "FLAC" {
                            Picker("Quality", selection: $model.audioQuality) {
                                ForEach(model.audioQualities, id: \.self) { Text($0).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                        }
                    }
                }
            }

            if model.mode == .video && model.videoPreset == "Custom yt-dlp selector" {
                field("Custom Selector") {
                    TextField("bestvideo+bestaudio/best", text: $model.customFormat)
                        .textFieldStyle(.roundedBorder)
                }
            }

            field("Save To") {
                HStack(spacing: 8) {
                    TextField("Download folder", text: $model.folderPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.start() }
                    Button("Choose…") { model.chooseFolder() }
                }
            }

            Button(action: { model.start() }) {
                Text("Download")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .keyboardShortcut(.return, modifiers: [])
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning)

            Text("⌘ Command: Switch Video/Audio   •   ↩ Enter: Download   •   ⇥ Tab: Change Format")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            if model.isRunning {
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancel() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var previewAndProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                if let image = model.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 245, height: 138)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Thumbnail").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 245, height: 138)
            .clipped()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.status).font(.headline)
                    Spacer()
                }
                HStack {
                    Spacer()
                    Text("\(Int(model.progress * 100))%")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(model.progress >= 1 ? .green : .primary)
                }
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack {
                    Label(model.speed, systemImage: "speedometer")
                    Spacer()
                    Label("ETA \(model.eta)", systemImage: "timer")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Spacer(minLength: 10)

                HStack(spacing: 8) {
                    Spacer()
                    Button("Update") { model.updateTools() }
                        .font(.caption.weight(.semibold))
                        .disabled(model.isRunning)
                    Button("Log") { model.copyLog() }
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .frame(width: 245, height: 320, alignment: .topLeading)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
