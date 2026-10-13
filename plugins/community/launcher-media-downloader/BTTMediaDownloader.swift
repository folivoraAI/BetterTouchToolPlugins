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
// - Homebrew at /opt/homebrew/bin/brew (Apple Silicon) or /usr/local/bin/brew (Intel)
// - yt-dlp, ffmpeg and ffprobe in /opt/homebrew/bin/ or /usr/local/bin/
//
// The plugin includes an Update button that can install/update yt-dlp and FFmpeg
// through Homebrew. Only download media you own or have permission to download.

import AppKit
import Foundation
import SwiftUI
import Combine

final class VideoDownloader: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    // The model of the running download (or tool check/update). It is owned by the plugin, not by a
    // surface, so a reopened Launcher surface shows the live progress and Cancel still reaches the process.
    var activeJobModel: VideoDownloaderViewModel?

    /// Sends SIGTERM to the process and its direct children (ffmpeg), escalating to SIGKILL after 0.7 s
    /// while the process is still running. Returns false when there was no running process to signal.
    @discardableResult
    func killProcessTree(_ process: Process?) -> Bool {
        guard let process, process.isRunning else { return false }
        let pid = process.processIdentifier
        guard pid > 0 else { return false }

        DispatchQueue.global(qos: .userInitiated).async {
            // Children first: pkill -P only finds them while their parent is still alive.
            // Process.isRunning stays true until the child is reaped, so the pid cannot have been reused while it is true.
            VideoDownloader.signalChildProcesses(of: pid, signal: "TERM")
            if process.isRunning { kill(pid, SIGTERM) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.7) {
                guard process.isRunning else { return }
                VideoDownloader.signalChildProcesses(of: pid, signal: "KILL")
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        return true
    }

    /// Runs /usr/bin/pkill directly (no shell) and waits briefly for it. Must not be called on the main thread.
    private static func signalChildProcesses(of pid: pid_t, signal: String) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-\(signal)", "-P", String(pid)]
        pkill.standardInput = FileHandle.nullDevice
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        pkill.terminationHandler = { _ in finished.signal() }
        guard (try? pkill.run()) != nil else { return }
        _ = finished.wait(timeout: .now() + 2)
    }

    // One resolver for Check Tools, Update Tools, previews and downloads: Apple Silicon Homebrew first, then Intel Homebrew.
    static let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let toolSearchPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    func toolPath(_ name: String) -> String? {
        for directory in VideoDownloader.toolDirectories {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    var ffmpegLocation: String? {
        toolPath("ffmpeg").map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    }

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

    // The clipboard is not read here; the surface reads it once when it appears (see loadURLFromClipboardIfNeeded).
    func suggestedURL(for context: BTTLauncherPluginContext) -> String {
        firstURL(in: context.query ?? "") ?? ""
    }

    // Clipboard URLs are previewed automatically only for these hosts (or their subdomains).
    private static let wellKnownMediaHosts = [
        "youtube.com", "youtu.be", "music.youtube.com", "vimeo.com", "instagram.com", "tiktok.com",
        "facebook.com", "fb.watch", "x.com", "twitter.com", "soundcloud.com", "twitch.tv",
        "dailymotion.com", "reddit.com", "bilibili.com", "open.spotify.com"
    ]

    func isWellKnownMediaURL(_ raw: String) -> Bool {
        guard let validatedURL = validatedHTTPURLString(raw),
              let host = URLComponents(string: validatedURL)?.host?.lowercased() else { return false }
        return VideoDownloader.wellKnownMediaHosts.contains { host == $0 || host.hasSuffix("." + $0) }
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

    func copyLastLog() -> Bool {
        let log = (try? String(contentsOf: lastLogURL(), encoding: .utf8)) ?? "No log found."
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(log, forType: .string)
    }

    func openDownloadedFile(at path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) else { return false }
        return NSWorkspace.shared.open(URL(fileURLWithPath: trimmed))
    }

    @discardableResult
    func startToolCheck(folderPath: String, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let safeFolder = shellSingleQuote(folderPath)
        let script = """
        set +e
        export PATH="\(VideoDownloader.toolSearchPATH)"
        BREW=\(quotedToolPath("brew"))
        YTDLP=\(quotedToolPath("yt-dlp"))
        FFMPEG=\(quotedToolPath("ffmpeg"))
        FFPROBE=\(quotedToolPath("ffprobe"))

        echo "Health check"
        if [ -n "$BREW" ]; then echo "✅ Homebrew: $($BREW --version | head -n 1)"; else echo "❌ Homebrew: missing"; fi
        if [ -n "$YTDLP" ]; then echo "✅ yt-dlp: $($YTDLP --version)"; else echo "❌ yt-dlp: missing"; fi
        if [ -n "$FFMPEG" ]; then echo "✅ ffmpeg: $($FFMPEG -version | head -n 1 | sed 's/^ffmpeg version //')"; else echo "❌ ffmpeg: missing"; fi
        if [ -n "$FFPROBE" ]; then echo "✅ ffprobe: installed"; else echo "❌ ffprobe: missing"; fi
        if /usr/bin/curl -Is --max-time 5 https://github.com >/dev/null 2>&1; then echo "✅ Internet: OK"; else echo "⚠️ Internet: could not verify"; fi
        mkdir -p \(safeFolder) 2>/dev/null
        if [ -w \(safeFolder) ]; then echo "✅ Folder: writable"; else echo "❌ Folder: not writable"; fi
        FREE_KB=$(df -k \(safeFolder) 2>/dev/null | tail -1 | awk '{print $4}')
        if [ -n "$FREE_KB" ]; then awk -v kb="$FREE_KB" 'BEGIN { printf "✅ Disk free: %.1f GB\\n", kb/1024/1024 }'; else echo "⚠️ Disk free: unknown"; fi
        [ -n "$YTDLP" ] && [ -n "$FFMPEG" ] && [ -n "$FFPROBE" ] && [ -w \(safeFolder) ]
        """
        return runShell(script: script, progress: progress, completion: completion)
    }

    @discardableResult
    func startToolUpdate(progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let script = """
        set -euo pipefail
        export PATH="\(VideoDownloader.toolSearchPATH)"
        BREW=\(quotedToolPath("brew"))
        if [ -z "$BREW" ]; then
          echo "Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew"
          exit 1
        fi
        "$BREW" update
        "$BREW" list yt-dlp >/dev/null 2>&1 || "$BREW" install yt-dlp
        "$BREW" list ffmpeg >/dev/null 2>&1 || "$BREW" install ffmpeg
        "$BREW" upgrade yt-dlp ffmpeg
        command -v yt-dlp >/dev/null
        command -v ffmpeg >/dev/null
        command -v ffprobe >/dev/null
        """
        return runShell(script: script, progress: progress, completion: completion)
    }

    /// Fetches title, channel, duration and thumbnail URL with one yt-dlp call (never with browser cookies).
    /// Returns the process so the caller can terminate it when the preview is no longer needed.
    @discardableResult
    func fetchMediaMetadata(for mediaURL: String, completion: @escaping (MediaPreview?) -> Void) -> Process? {
        guard let validatedURL = validatedHTTPURLString(mediaURL),
              let ytDLP = toolPath("yt-dlp") else {
            completion(nil)
            return nil
        }
        let arguments = ["--ignore-config", "--no-warnings", "--skip-download", "--playlist-items", "1", "--dump-single-json", "--", validatedURL]
        return runCapturingProcess(executable: ytDLP, arguments: arguments, outputLimit: 16_000_000, timeout: 12) { status, data in
            guard status == 0,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            var preview = MediaPreview()
            preview.title = object["title"] as? String
            preview.source = (object["channel"] as? String) ?? (object["uploader"] as? String) ?? (object["extractor_key"] as? String)
            if let seconds = (object["duration"] as? NSNumber)?.intValue, seconds > 0 {
                if seconds >= 3600 {
                    preview.duration = String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
                } else {
                    preview.duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
                }
            }
            // Playlists carry the thumbnail on their first entry.
            let firstEntry = (object["entries"] as? [Any])?.first as? [String: Any]
            preview.thumbnailURL = (object["thumbnail"] as? String) ?? (firstEntry?["thumbnail"] as? String)
            completion(preview)
        }
    }

    /// Downloads a thumbnail with an ephemeral session (no shared cookies or cache), a 10 s timeout and a 10 MB cap.
    func fetchThumbnailImage(from imageURL: String, completion: @escaping (NSImage?) -> Void) -> ThumbnailDownload? {
        guard let validatedURL = validatedHTTPURLString(imageURL), let url = URL(string: validatedURL) else {
            completion(nil)
            return nil
        }
        return ThumbnailDownload(url: url, completion: completion)
    }

    func makeDownloadArguments(mode: DownloadMode, url: String, videoPreset: String, customFormat: String, audioFormat: String, audioQuality: String, cookiesBrowser: String, folder: URL) -> [String]? {
        guard let downloadTarget = normalizedDownloadTarget(url) else { return nil }
        let isPlaylist = validatedHTTPURLString(downloadTarget).map { shouldDownloadPlaylist($0) } ?? false
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
            "--progress-template", "download:download:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(progress.downloaded_bytes)s|%(progress.total_bytes_estimate)s",
            "--print", "after_move:filepath",
            "-P", folder.path,
            "-o", outputTemplate,
            isPlaylist ? "--yes-playlist" : "--no-playlist"
        ]

        if let ffmpegLocation {
            args += ["--ffmpeg-location", ffmpegLocation]
        }

        // Browser cookies are only ever passed to the actual download, never to previews or estimates.
        if let browser = cookiesBrowserArgument(cookiesBrowser) {
            args += ["--cookies-from-browser", browser]
        }

        switch mode {
        case .video:
            let format = videoFormatSelector(preset: videoPreset, customFormat: customFormat)
            args += ["-f", format.selector]
            if let merge = format.mergeFormat { args += ["--merge-output-format", merge] }
        case .audio:
            let formatMap = ["MP3": "mp3", "M4A": "m4a", "WAV": "wav", "Opus": "opus", "FLAC": "flac"]
            args += ["-x", "--audio-format", formatMap[audioFormat] ?? "mp3", "--add-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg"]
            if audioFormat != "WAV" && audioFormat != "FLAC" {
                let qualityMap = ["Best": "0", "320 kbps": "320K", "256 kbps": "256K", "192 kbps": "192K", "128 kbps": "128K"]
                args += ["--audio-quality", qualityMap[audioQuality] ?? "0"]
            }
        }
        args += ["--", downloadTarget]
        return args
    }

    /// Estimates the download size without browser cookies. Single items are resolved with the selected format;
    /// playlists are only listed (--flat-playlist) for their entry count because extracting every entry is slow.
    @discardableResult
    func estimateDownloadSize(mode: DownloadMode, url: String, videoPreset: String, customFormat: String, audioFormat: String, completion: @escaping (Int64?, Int?) -> Void) -> Process? {
        guard let validatedURL = validatedHTTPURLString(url), let ytDLP = toolPath("yt-dlp") else {
            completion(nil, nil)
            return nil
        }

        let isPlaylist = shouldDownloadPlaylist(validatedURL)
        var args = [
            "--ignore-config",
            "--no-warnings",
            "--skip-download",
            "--dump-single-json"
        ]

        if isPlaylist {
            args += ["--yes-playlist", "--flat-playlist"]
        } else {
            args += ["--no-playlist"]
            if let ffmpegLocation {
                args += ["--ffmpeg-location", ffmpegLocation]
            }
            switch mode {
            case .video:
                args += ["-f", videoFormatSelector(preset: videoPreset, customFormat: customFormat).selector]
            case .audio:
                args += ["-f", "bestaudio/best"]
            }
        }
        args += ["--", validatedURL]

        return runCapturingProcess(executable: ytDLP, arguments: args, outputLimit: 8_000_000, timeout: 25) { status, data in
            guard status == 0, let object = try? JSONSerialization.jsonObject(with: data) else {
                completion(nil, nil)
                return
            }
            completion(isPlaylist ? nil : self.estimatedBytes(from: object), self.playlistItemCount(from: object))
        }
    }

    private func playlistItemCount(from object: Any) -> Int? {
        guard let dictionary = object as? [String: Any], let entries = dictionary["entries"] as? [Any] else { return nil }
        let count = entries.filter { !($0 is NSNull) }.count
        return count > 1 ? count : nil
    }

    private func estimatedBytes(from object: Any) -> Int64? {
        if let dictionary = object as? [String: Any] {
            if let entries = dictionary["entries"] as? [Any] {
                let values = entries.compactMap { estimatedBytes(from: $0) }
                return values.isEmpty ? nil : saturatingSum(values)
            }
            if let requested = dictionary["requested_formats"] as? [Any] {
                let values = requested.compactMap { estimatedBytes(from: $0) }
                return values.isEmpty ? directFileSize(from: dictionary) : saturatingSum(values)
            }
            return directFileSize(from: dictionary)
        }
        return nil
    }

    // Sizes come from remote metadata, so add them up without risking an overflow trap.
    private func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }

    private func directFileSize(from dictionary: [String: Any]) -> Int64? {
        for key in ["filesize", "filesize_approx"] {
            if let number = dictionary[key] as? NSNumber, number.int64Value > 0 { return number.int64Value }
            if let int = dictionary[key] as? Int64, int > 0 { return int }
            if let double = dictionary[key] as? Double, double > 0, double < Double(Int64.max) { return Int64(double) }
        }
        return nil
    }

    func runYTDLP(arguments: [String], progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let missing = ["yt-dlp", "ffmpeg", "ffprobe"].filter { toolPath($0) == nil }
        guard missing.isEmpty, let ytDLP = toolPath("yt-dlp") else {
            progress("Missing tools: " + missing.joined(separator: ", "))
            completion(false)
            return nil
        }
        return runProcess(executable: ytDLP, arguments: arguments, progress: progress, completion: completion)
    }

    @discardableResult
    private func runShell(script: String, progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        // Not a login shell, so the user's dotfiles are not loaded; the scripts set PATH explicitly.
        runProcess(executable: "/bin/zsh", arguments: ["-c", script], progress: progress, completion: completion)
    }

    private func runProcess(executable: String, arguments: [String], progress: @escaping (String) -> Void, completion: @escaping (Bool) -> Void) -> Process? {
        let logURL = prepareLogFile()
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        let logFile = try? FileHandle(forWritingTo: logURL)
        do {
            return try launchProcess(executable: executable, arguments: arguments, mergeErrorOutput: true, output: { data in
                // Runs on the pipe's single background reader, so log writes and progress stay in order.
                try? logFile?.write(contentsOf: data)
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { progress(text) }
            }, completion: { status in
                completion(status == 0)
            })
        } catch {
            progress("Could not start: \(error.localizedDescription)")
            completion(false)
            return nil
        }
    }

    /// Runs a short helper process (previews, estimates) with a hard timeout and hands its stdout to `completion`
    /// on the main thread.
    private func runCapturingProcess(executable: String, arguments: [String], outputLimit: Int, timeout: TimeInterval, completion: @escaping (Int32, Data) -> Void) -> Process? {
        let buffer = ProcessOutputBuffer(limit: outputLimit)
        guard let task = try? launchProcess(executable: executable, arguments: arguments, mergeErrorOutput: false, output: { buffer.append($0) }, completion: { status in
            completion(status, buffer.data)
        }) else {
            completion(-1, Data())
            return nil
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if task.isRunning { task.terminate() }
        }
        return task
    }

    /// Launches a process and reads stdout/stderr on background threads while it runs, so the child never blocks
    /// on a full pipe. `output` receives the data in order; `completion` runs on the main thread once the process
    /// has exited and the remaining output has been drained.
    private func launchProcess(executable: String, arguments: [String], mergeErrorOutput: Bool, output: @escaping (Data) -> Void, completion: @escaping (Int32) -> Void) throws -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = mergeErrorOutput ? outputPipe : Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        let readers = DispatchGroup()
        let readerCount = mergeErrorOutput ? 1 : 2
        for _ in 0..<readerCount { readers.enter() }
        task.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.global(qos: .utility).async {
                // Let the readers drain the pipes, but don't wait forever if an orphaned grandchild keeps them open.
                _ = readers.wait(timeout: .now() + 3)
                DispatchQueue.main.async { completion(status) }
            }
        }

        do {
            try task.run()
        } catch {
            for _ in 0..<readerCount { readers.leave() }
            throw error
        }
        VideoDownloader.readPipe(outputPipe.fileHandleForReading, output: output) { readers.leave() }
        if !mergeErrorOutput {
            // stderr is drained (and dropped) so a chatty child can't block on it.
            VideoDownloader.readPipe(errorPipe.fileHandleForReading, output: { _ in }) { readers.leave() }
        }
        return task
    }

    /// Reads `handle` until EOF on a background thread. Data is passed on in whole lines where possible, so
    /// progress lines and UTF-8 sequences are not split between callbacks.
    private static func readPipe(_ handle: FileHandle, output: @escaping (Data) -> Void, finished: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if let newline = chunk.lastIndex(of: 0x0A) {
                    let split = chunk.index(after: newline)
                    pending.append(chunk.subdata(in: chunk.startIndex..<split))
                    output(pending)
                    pending = chunk.subdata(in: split..<chunk.endIndex)
                } else {
                    pending.append(chunk)
                    if pending.count >= 1_048_576 {
                        output(pending)
                        pending = Data()
                    }
                }
            }
            if !pending.isEmpty { output(pending) }
            finished()
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

    func isSpotifyURL(_ raw: String) -> Bool {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased() else { return false }
        return host == "open.spotify.com" || host.hasSuffix(".spotify.com")
    }

    func spotifyURLKind(_ raw: String) -> String? {
        guard isSpotifyURL(raw),
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        return parts.first?.lowercased()
    }

    func normalizedDownloadTarget(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("ytsearch") { return trimmed }
        if let url = validatedHTTPURLString(trimmed) { return url }
        // Plain text search support: let yt-dlp search YouTube and download the best first match.
        // This allows typing e.g. "daft punk around the world" instead of pasting a URL.
        return "ytsearch1:\(trimmed)"
    }

    func resolveSpotifyToYouTubeSearch(_ spotifyURL: String, completion: @escaping (String?) -> Void) {
        let trimmed = spotifyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSpotifyURL(trimmed),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://open.spotify.com/oembed?url=\(encoded)") else {
            completion(nil)
            return
        }

        // Ephemeral session: BetterTouchTool's shared cookies and cache are not used.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: url) { data, _, _ in
            var query: String?
            if let data,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = object["title"] as? String {
                query = title
                    .replacingOccurrences(of: " - song and lyrics by ", with: " ", options: [.caseInsensitive])
                    .replacingOccurrences(of: " song and lyrics by ", with: " ", options: [.caseInsensitive])
                    .replacingOccurrences(of: " | Spotify", with: "", options: [.caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let query, !query.isEmpty {
                completion("ytsearch1:\(query) audio")
            } else {
                completion(nil)
            }
        }.resume()
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

    private func shellSingleQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func quotedToolPath(_ name: String) -> String {
        toolPath(name).map(shellSingleQuote) ?? "''"
    }

    private func cookiesBrowserArgument(_ browser: String) -> String? {
        switch browser.lowercased() {
        case "safari": return "safari"
        case "chrome": return "chrome"
        case "edge": return "edge"
        case "firefox": return "firefox"
        case "brave": return "brave"
        default: return nil
        }
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

struct MediaPreview {
    var title: String?
    var source: String?
    var duration: String?
    var thumbnailURL: String?
}

/// Process output collected from a background reader thread; all access is lock-protected.
final class ProcessOutputBuffer {
    private let lock = NSLock()
    private var storage = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        if storage.count < limit { storage.append(data) }
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Downloads one preview image. The ephemeral session shares no cookies or cache with BetterTouchTool,
/// requests time out after 10 s and responses larger than 10 MB are cancelled instead of buffered.
final class ThumbnailDownload: NSObject, URLSessionDataDelegate {
    static let maximumBytes: Int64 = 10 * 1024 * 1024
    private var data = Data() // only touched on the session's serial delegate queue
    private var completion: ((NSImage?) -> Void)?
    private var task: URLSessionDataTask?

    init(url: URL, completion: @escaping (NSImage?) -> Void) {
        self.completion = completion
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
        session.finishTasksAndInvalidate() // releases this delegate once the task has finished
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let expectedLength = dataTask.response?.expectedContentLength ?? -1
        guard expectedLength <= ThumbnailDownload.maximumBytes,
              Int64(self.data.count + data.count) <= ThumbnailDownload.maximumBytes else {
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let image = error == nil && (200..<300).contains(statusCode) ? NSImage(data: data) : nil
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async { completion?(image) }
    }
}

final class VideoDownloaderDashboardSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private weak var plugin: VideoDownloader?
    private let context: BTTLauncherPluginContext
    private var model: VideoDownloaderViewModel?
    private var isVisible = false
    private var didCheckClipboard = false

    init(plugin: VideoDownloader, context: BTTLauncherPluginContext) {
        self.plugin = plugin
        self.context = context
        super.init()
    }

    deinit {
        if isVisible { model?.surfaceWillDisappear() }
    }

    func makeLauncherSurfaceView() -> NSView {
        // A running job keeps its model in the plugin, so reopening the Launcher shows its live progress.
        let model = plugin?.activeJobModel ?? self.model ?? VideoDownloaderViewModel(plugin: plugin, context: context)
        self.model = model
        return NSHostingView(rootView: VideoDownloaderDashboardView(model: model))
    }

    func launcherSurfaceDidAppear() {
        guard !isVisible else { return }
        isVisible = true
        // The clipboard is read once per opened surface, and only to prefill an empty source.
        model?.surfaceDidAppear(checkClipboard: !didCheckClipboard)
        didCheckClipboard = true
    }

    func launcherSurfaceWillDisappear() {
        guard isVisible else { return }
        isVisible = false
        // Stops preview processes only. Do not cancel downloads here: closing the launcher with Escape should
        // let yt-dlp continue in the background.
        model?.surfaceWillDisappear()
    }

    func handleLauncherRawKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 36, 76: // Return / Enter
            model?.start()
            return true
        case 48: // Tab switches mode reliably inside BTT Launcher
            model?.toggleMode()
            return true
        default:
            return false
        }
    }

    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        // Let the launcher's text input keep normal cursor movement/editing.
        // This prevents the surface from stealing arrow-key navigation while editing pasted/search text.
        switch event.keyCode {
        case 123, 124, 125, 126: // Left, Right, Down, Up
            return true
        default:
            return false
        }
    }

    func launcherSurfaceQueryDidChange(_ query: String?) {
        model?.updateURLFromLauncherQuery(query)
    }

    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 850, height: 450) }
    func launcherSurfaceMinimumContentSize() -> CGSize { CGSize(width: 760, height: 420) }
    func launcherSurfacePlaceholderText() -> String? { "Paste URL, search text, or multi-line song list" }
    func launcherSurfaceFooterHint() -> String? { nil }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { false }
}

final class VideoDownloaderViewModel: ObservableObject {
    @Published var mode: DownloadMode = .video
    @Published var url: String
    @Published var videoPreset = "Best available | Original"
    @Published var customFormat = "bestvideo+bestaudio/best"
    @Published var audioFormat = "MP3"
    @Published var audioQuality = "Best"
    @Published var cookiesBrowser = "None"
    @Published var folderPath: String
    @Published var status = "Ready"
    @Published var detail = "Paste a URL and choose a format."
    @Published var progress: Double = 0
    @Published var overallProgress: Double = 0
    @Published var speed = "—"
    @Published var eta = "—"
    @Published var isRunning = false
    @Published var thumbnail: NSImage?
    @Published var sizeEstimate = "Size: —"
    @Published var playlistCounter = ""
    @Published var queueStatus = ""
    @Published var healthStatus = ""
    @Published var lastDownloadedFile = ""
    @Published var transferredBytes: Int64?
    @Published var totalBytes: Int64?
    @Published var jobSummary = ""
    @Published var mediaTitle = ""
    @Published var mediaSource = ""
    @Published var mediaDuration = ""

    let videoPresets = ["Best available | Original", "2160p / 4K", "1440p / 2K", "1080p", "720p", "480p", "360p", "1080p | MKV", "720p | WebM", "Custom yt-dlp selector"]
    let audioFormats = ["MP3", "M4A", "WAV", "Opus", "FLAC"]
    let audioQualities = ["Best", "320 kbps", "256 kbps", "192 kbps", "128 kbps"]
    let cookiesBrowsers = ["None", "Safari", "Chrome", "Edge", "Firefox", "Brave"]

    // While a job runs, the plugin owns this model, so the job outlives the surface and a reopened surface reuses it.
    private func retainForBackgroundDownload() {
        plugin?.activeJobModel = self
    }

    private func releaseFromBackgroundDownload() {
        if plugin?.activeJobModel === self { plugin?.activeJobModel = nil }
    }

    private weak var plugin: VideoDownloader?
    private let defaults = UserDefaults.standard
    // These settings live in BetterTouchTool's preferences domain, so every key carries the plugin identifier.
    private enum DefaultsKey {
        static let prefix = "com.loay.btt.media-downloader."
        static let mode = prefix + "mode"
        static let videoPreset = prefix + "videoPreset"
        static let customFormat = prefix + "customFormat"
        static let audioFormat = prefix + "audioFormat"
        static let audioQuality = prefix + "audioQuality"
        static let cookiesBrowser = prefix + "cookiesBrowser"
        static let lastDownloadedFile = prefix + "lastDownloadedFile"
        static let folderPath = prefix + "folderPath"
        // Earlier versions used the generic "MediaDownloader." prefix; those values are migrated once.
        static let legacyPrefix = "MediaDownloader."
        static let migratedNames = ["mode", "videoPreset", "customFormat", "audioFormat", "audioQuality", "cookiesBrowser", "lastDownloadedFile", "folderPath"]
        static let obsoleteNames = ["recentFolders"]
    }

    private static func migrateLegacyDefaults(_ defaults: UserDefaults) {
        for name in DefaultsKey.migratedNames + DefaultsKey.obsoleteNames {
            let legacyKey = DefaultsKey.legacyPrefix + name
            guard let value = defaults.object(forKey: legacyKey) else { continue }
            let key = DefaultsKey.prefix + name
            if DefaultsKey.migratedNames.contains(name), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private var task: Process?
    private var estimateTask: Process?
    private var metadataTask: Process?
    private var thumbnailDownload: ThumbnailDownload?
    private var previewWorkItem: DispatchWorkItem?
    private var previewGeneration = 0
    private var estimateGeneration = 0
    private var isSurfaceVisible = false
    // A clipboard URL from a site that isn't a well-known media host is not contacted until the user confirms it.
    private var clipboardURLAwaitingConfirmation: String?
    private var launcherQuery = ""
    private var jobID = 0
    private var cancellationRequested = false
    private var playlistCurrentItem = 0
    private var playlistTotalItems = 0
    private var queuedURLs: [String] = []
    private var queueCompleted = 0
    private var queueTotal = 0
    private var queueSubfolderName: String?
    private var lastThumbnailURL = ""
    private var lastEstimateKey = ""

    init(plugin: VideoDownloader?, context: BTTLauncherPluginContext) {
        self.plugin = plugin
        self.launcherQuery = context.query ?? ""
        self.url = plugin?.suggestedURL(for: context) ?? ""
        VideoDownloaderViewModel.migrateLegacyDefaults(defaults)

        let defaultFolder = plugin?.defaultDownloadDirectory().path ?? ""
        self.folderPath = defaults.string(forKey: DefaultsKey.folderPath) ?? defaultFolder
        self.mode = DownloadMode(rawValue: defaults.string(forKey: DefaultsKey.mode) ?? "") ?? .video

        let savedVideoPreset = defaults.string(forKey: DefaultsKey.videoPreset)
        if let savedVideoPreset, videoPresets.contains(savedVideoPreset) { self.videoPreset = savedVideoPreset }
        self.customFormat = defaults.string(forKey: DefaultsKey.customFormat) ?? self.customFormat

        let savedAudioFormat = defaults.string(forKey: DefaultsKey.audioFormat)
        if let savedAudioFormat, audioFormats.contains(savedAudioFormat) { self.audioFormat = savedAudioFormat }

        let savedAudioQuality = defaults.string(forKey: DefaultsKey.audioQuality)
        if let savedAudioQuality, audioQualities.contains(savedAudioQuality) { self.audioQuality = savedAudioQuality }

        let savedCookiesBrowser = defaults.string(forKey: DefaultsKey.cookiesBrowser)
        if let savedCookiesBrowser, cookiesBrowsers.contains(savedCookiesBrowser) { self.cookiesBrowser = savedCookiesBrowser }
        self.lastDownloadedFile = defaults.string(forKey: DefaultsKey.lastDownloadedFile) ?? ""
        saveSettings()
        // Previews start (debounced) once the surface appears, see surfaceDidAppear.
    }

    deinit {
        previewWorkItem?.cancel()
        thumbnailDownload?.cancel()
        if let metadataTask, metadataTask.isRunning { metadataTask.terminate() }
        if let estimateTask, estimateTask.isRunning { estimateTask.terminate() }
    }

    func surfaceDidAppear(checkClipboard: Bool) {
        isSurfaceVisible = true
        if checkClipboard { loadURLFromClipboardIfNeeded() }
        schedulePreview()
    }

    func surfaceWillDisappear() {
        isSurfaceVisible = false
        stopPreviews()
    }

    func updateURLFromLauncherQuery(_ query: String?) {
        launcherQuery = query ?? ""
        // A running job keeps its source and queue; launcher typing must not replace them.
        guard !isRunning else { return }
        // A URL typed or pasted into the launcher is explicit input, so it may be previewed.
        if clipboardURLAwaitingConfirmation != nil, !allURLCandidates(in: launcherQuery).isEmpty {
            clipboardURLAwaitingConfirmation = nil
            schedulePreview()
        }
        loadSource(launcherQuery)
    }

    func pasteFromClipboard() {
        guard !isRunning,
              let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pasted.isEmpty else { return }
        // An explicit paste may load a multi-line list and is previewed like typed input.
        clipboardURLAwaitingConfirmation = nil
        url = pasted
        loadSource(pasted)
        schedulePreview()
    }

    private func loadSource(_ rawQuery: String) {
        guard let plugin else { return }
        let urls = allURLCandidates(in: rawQuery)
        if urls.count > 1 {
            queuedURLs = urls
            queueCompleted = 0
            queueTotal = urls.count
            queueSubfolderName = nil
            queueStatus = "0 of \(urls.count)"
            url = urls[0]
            status = "Queue ready"
            detail = "\(urls.count) URLs loaded. Press Enter to start queue."
            schedulePreview()
            return
        }

        let searches = allSearchCandidates(in: rawQuery)
        if urls.isEmpty, searches.count > 1 {
            queuedURLs = searches
            queueCompleted = 0
            queueTotal = searches.count
            queueSubfolderName = textPlaylistFolderName(from: searches)
            queueStatus = "0 of \(searches.count)"
            url = searches[0]
            status = "Text playlist ready"
            detail = "\(searches.count) search lines loaded. Press Enter to download them in order."
            thumbnail = nil
            schedulePreview()
            return
        }
        let candidate = urls.first ?? ""
        if !candidate.isEmpty, plugin.validatedHTTPURLString(candidate) != nil, candidate != url {
            queuedURLs = []
            queueCompleted = 0
            queueTotal = 0
            queueStatus = ""
            url = candidate
            status = "URL ready"
            detail = "URL taken from launcher input."
            schedulePreview()
            return
        }

        let searchText = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty, plugin.normalizedDownloadTarget(searchText) != nil, searchText != url else { return }
        queuedURLs = []
        queueCompleted = 0
        queueTotal = 0
        queueSubfolderName = nil
        queueStatus = ""
        url = searchText
        status = "Search ready"
        detail = "Press Enter to search YouTube and download the first result."
        thumbnail = nil
        schedulePreview()
    }

    /// Called once when a surface appears. Prefills a single clipboard URL into an empty source unless the launcher
    /// query already contains a URL. Lists (several URLs or lines) are only loaded through the Paste button.
    func loadURLFromClipboardIfNeeded() {
        guard let plugin, !isRunning,
              url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              allURLCandidates(in: launcherQuery).isEmpty else { return }
        let clipboardText = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipboardText.isEmpty, clipboardText.utf16.count <= 4_096 else { return }
        let urls = allURLCandidates(in: clipboardText)
        guard urls.count == 1, !clipboardText.contains(where: { $0.isNewline }) else {
            if urls.count > 1 || allSearchCandidates(in: clipboardText).count > 1 {
                detail = "The clipboard holds a list. Click Paste to load it as a queue."
            }
            return
        }

        let clipboardURL = urls[0]
        url = clipboardURL
        queuedURLs = []
        queueCompleted = 0
        queueTotal = 0
        queueSubfolderName = nil
        queueStatus = ""
        status = "Clipboard URL ready"
        if plugin.isWellKnownMediaURL(clipboardURL) {
            detail = "URL was loaded from clipboard. Press Enter to download."
        } else {
            clipboardURLAwaitingConfirmation = clipboardURL
            detail = "Not previewed for this site. Edit it, click Paste, or press Enter to download."
        }
    }

    private func allURLCandidates(in text: String) -> [String] {
        guard let plugin else { return [] }
        var seen = Set<String>()
        var results: [String] = []
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>()\[\]{}\"']+"#, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            var candidate = String(text[range])
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>'\""))
            guard plugin.validatedHTTPURLString(candidate) != nil, !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            results.append(candidate)
        }
        return results
    }

    private func allSearchCandidates(in text: String) -> [String] {
        var seen = Set<String>()
        var results: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            guard cleaned.count >= 2 else { continue }
            guard plugin?.validatedHTTPURLString(cleaned) == nil else { continue }
            guard !cleaned.lowercased().hasPrefix("http://"), !cleaned.lowercased().hasPrefix("https://") else { continue }
            guard !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            results.append(cleaned)
        }
        return results
    }

    private func textPlaylistFolderName(from searches: [String]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Media Playlist \(formatter.string(from: Date()))"
    }

    /// Previews (metadata, thumbnail, size) run 0.6 s after the source stops changing and only while a surface is
    /// visible. A clipboard URL from an unknown site waits until the user edits it, clicks Paste or starts the download.
    func schedulePreview() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        guard isSurfaceVisible else { return }
        if let pendingURL = clipboardURLAwaitingConfirmation {
            guard url.trimmingCharacters(in: .whitespacesAndNewlines) != pendingURL else { return }
            clipboardURLAwaitingConfirmation = nil // the source was edited, so it is the user's choice now
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewWorkItem = nil
            self.refreshThumbnailIfNeeded()
            self.refreshSizeEstimateIfNeeded()
        }
        previewWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    /// Terminates in-flight preview work and drops its late results; unfinished previews load again on the next appear.
    private func stopPreviews() {
        previewWorkItem?.cancel()
        previewWorkItem = nil
        previewGeneration += 1
        estimateGeneration += 1
        if metadataTask != nil || thumbnailDownload != nil { lastThumbnailURL = "" }
        if estimateTask != nil { lastEstimateKey = "" }
        terminatePreviewProcess(metadataTask)
        terminatePreviewProcess(estimateTask)
        metadataTask = nil
        estimateTask = nil
        thumbnailDownload?.cancel()
        thumbnailDownload = nil
    }

    private func terminatePreviewProcess(_ process: Process?) {
        if let process, process.isRunning { process.terminate() }
    }

    private func refreshThumbnailIfNeeded() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastThumbnailURL, !trimmed.isEmpty else { return }
        lastThumbnailURL = trimmed
        // One preview at a time: stop the previous fetch and ignore its late results via the generation token.
        previewGeneration += 1
        let generation = previewGeneration
        terminatePreviewProcess(metadataTask)
        thumbnailDownload?.cancel()
        thumbnailDownload = nil
        thumbnail = nil
        mediaTitle = ""
        mediaSource = ""
        mediaDuration = ""
        metadataTask = plugin?.fetchMediaMetadata(for: trimmed) { [weak self] preview in
            guard let self, self.previewGeneration == generation else { return }
            self.metadataTask = nil
            self.mediaTitle = preview?.title ?? ""
            self.mediaSource = preview?.source ?? ""
            self.mediaDuration = preview?.duration ?? ""
            guard let thumbnailURL = preview?.thumbnailURL else { return }
            self.thumbnailDownload = self.plugin?.fetchThumbnailImage(from: thumbnailURL) { [weak self] image in
                guard let self, self.previewGeneration == generation else { return }
                self.thumbnailDownload = nil
                self.thumbnail = image
            }
        }
    }

    private func refreshSizeEstimateIfNeeded() {
        guard let plugin else { return }
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = [trimmed, mode.rawValue, videoPreset, customFormat, audioFormat, audioQuality].joined(separator: "|")
        guard key != lastEstimateKey else { return }
        lastEstimateKey = key
        estimateGeneration += 1
        let generation = estimateGeneration
        terminatePreviewProcess(estimateTask)
        estimateTask = nil

        guard plugin.validatedHTTPURLString(trimmed) != nil, !plugin.isSpotifyURL(trimmed) else {
            if plugin.isSpotifyURL(trimmed) {
                let kind = plugin.spotifyURLKind(trimmed) ?? "link"
                sizeEstimate = kind == "track" ? "Spotify track → YouTube" : "Spotify \(kind) not supported"
            } else if plugin.normalizedDownloadTarget(trimmed)?.lowercased().hasPrefix("ytsearch") == true {
                sizeEstimate = "YouTube search → first result"
            } else {
                sizeEstimate = "Size: —"
            }
            playlistCounter = ""
            return
        }

        let isPlaylist = plugin.willDownloadPlaylist(trimmed)
        sizeEstimate = isPlaylist ? "Counting playlist…" : "Estimating size…"
        estimateTask = plugin.estimateDownloadSize(mode: mode, url: trimmed, videoPreset: videoPreset, customFormat: customFormat, audioFormat: audioFormat) { [weak self] bytes, playlistCount in
            guard let self, self.estimateGeneration == generation else { return }
            self.estimateTask = nil
            if let playlistCount, playlistCount > 1 {
                self.playlistCounter = "0 of \(playlistCount)"
            } else if !self.isRunning {
                self.playlistCounter = ""
            }
            if isPlaylist {
                // Playlists are only counted; their size is not estimated.
                self.sizeEstimate = playlistCount.map { "Playlist: \($0) items" } ?? "Playlist"
            } else if let bytes, bytes > 0 {
                let approx = self.mode == .audio ? "Approx. audio size" : "Approx. size"
                self.sizeEstimate = "\(approx): \(self.formatBytes(bytes))"
            } else {
                self.sizeEstimate = "Size: unknown"
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_073_741_824 { return String(format: "%.2f GB", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return "\(bytes) B"
    }

    func start() {
        guard !isRunning else { return }
        // Starting the download confirms a clipboard URL, so its preview may load now.
        clipboardURLAwaitingConfirmation = nil
        jobID += 1
        if queuedURLs.count > 1 {
            startQueue()
            return
        }
        startSingleDownload(url.trimmingCharacters(in: .whitespacesAndNewlines), queueMode: false, completion: nil)
    }

    private func startQueue() {
        guard !queuedURLs.isEmpty else { return }
        retainForBackgroundDownload()
        cancellationRequested = false
        queueCompleted = 0
        queueTotal = queuedURLs.count
        queueStatus = "0 of \(queueTotal)"
        overallProgress = 0
        isRunning = true
        startNextQueueItem()
    }

    private func startNextQueueItem() {
        guard !cancellationRequested else { finishQueue(cancelled: true); return }
        guard queueCompleted < queuedURLs.count else { finishQueue(cancelled: false); return }
        let currentURL = queuedURLs[queueCompleted]
        url = currentURL
        queueStatus = "\(queueCompleted) of \(queueTotal)"
        status = "Queue item \(queueCompleted + 1) of \(queueTotal)"
        startSingleDownload(currentURL, queueMode: true) { [weak self] success in
            guard let self else { return }
            if self.cancellationRequested { self.finishQueue(cancelled: true); return }
            self.queueCompleted += 1
            self.queueStatus = "\(self.queueCompleted) of \(self.queueTotal)"
            self.overallProgress = Double(self.queueCompleted) / Double(max(self.queueTotal, 1))
            if !success {
                self.detail = "One queue item failed; continuing with next URL."
            }
            self.startNextQueueItem()
        }
    }

    private func finishQueue(cancelled: Bool) {
        isRunning = false
        releaseFromBackgroundDownload()
        if cancelled {
            status = "Queue cancelled"
            detail = "Stopped at \(queueCompleted) of \(queueTotal)."
        } else {
            progress = 1
            overallProgress = 1
            status = "Queue finished"
            detail = "Downloaded \(queueCompleted) of \(queueTotal) queued URLs."
            queueStatus = "\(queueCompleted) of \(queueTotal)"
        }
    }

    private func startSingleDownload(_ downloadURL: String, queueMode: Bool, completion: ((Bool) -> Void)?) {
        guard let plugin else { fail("Plugin not available."); completion?(false); return }
        let trimmed = downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if plugin.isSpotifyURL(trimmed) {
            let kind = plugin.spotifyURLKind(trimmed) ?? ""
            guard kind == "track" else {
                let label = kind.isEmpty ? "Spotify link" : "Spotify \(kind)"
                fail("\(label.capitalized) is not supported for auto YouTube matching yet. Paste individual Spotify track links, normal media URLs, or an exported artist/title list.")
                completion?(false)
                return
            }
            status = "Resolving Spotify track…"
            detail = "Using Spotify track metadata to search YouTube for a matching audio result."
            let job = jobID
            plugin.resolveSpotifyToYouTubeSearch(trimmed) { [weak self] target in
                DispatchQueue.main.async {
                    // Drop the result if this job was cancelled or replaced while Spotify was being asked.
                    guard let self, self.jobID == job, !self.cancellationRequested else { return }
                    guard let target else {
                        self.fail("Could not resolve Spotify metadata. Paste artist + song title or use a normal media URL.")
                        completion?(false)
                        return
                    }
                    self.startSingleDownload(target, queueMode: queueMode, completion: completion)
                }
            }
            return
        }
        guard plugin.normalizedDownloadTarget(trimmed) != nil else { fail("Paste a URL, Spotify track, or type search text."); completion?(false); return }
        url = trimmed
        schedulePreview()
        let baseFolder = URL(fileURLWithPath: folderPath.isEmpty ? plugin.defaultDownloadDirectory().path : folderPath, isDirectory: true)
        let folder = queueMode && queueSubfolderName != nil
            ? baseFolder.appendingPathComponent(queueSubfolderName ?? "Text Playlist", isDirectory: true)
            : baseFolder
        rememberFolder(baseFolder.path)
        saveSettings()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let args = plugin.makeDownloadArguments(mode: mode, url: trimmed, videoPreset: videoPreset, customFormat: customFormat, audioFormat: audioFormat, audioQuality: audioQuality, cookiesBrowser: cookiesBrowser, folder: folder) else {
            fail("Please paste a valid http(s) URL.")
            completion?(false)
            return
        }

        if !queueMode {
            retainForBackgroundDownload()
        }

        progress = 0
        playlistCurrentItem = 0
        playlistTotalItems = 0
        speed = "—"
        eta = "—"
        transferredBytes = nil
        totalBytes = nil
        let selectedFormat = mode == .video ? videoPreset : audioFormat
        let selectedQuality = mode == .video ? videoPreset : ((audioFormat == "WAV" || audioFormat == "FLAC") ? "Lossless conversion" : audioQuality)
        jobSummary = "\(mode.rawValue) • \(selectedFormat) • \(selectedQuality) • \(baseFolder.lastPathComponent)"
        playlistCounter = queueMode ? playlistCounter : ""
        cancellationRequested = false
        isRunning = true
        status = queueMode ? "Queue item \(queueCompleted + 1) of \(queueTotal)" : (mode == .video ? "Downloading video…" : "Downloading audio…")
        detail = plugin.normalizedDownloadTarget(trimmed)?.lowercased().hasPrefix("ytsearch") == true ? "Searching YouTube for best matching result." : (plugin.willDownloadPlaylist(trimmed) ? "Starting playlist download into its own folder." : "Starting yt-dlp.")
        task = plugin.runYTDLP(arguments: args, progress: { [weak self] text in self?.consumeOutput(text) }, completion: { [weak self] success in
            guard let self else { return }
            if self.cancellationRequested {
                if queueMode { completion?(false); return }
                self.isRunning = false
                self.status = "Cancelled"
                self.detail = "The active operation was stopped."
                self.cancellationRequested = false
                self.releaseFromBackgroundDownload()
                return
            }
            self.progress = success ? 1 : self.progress
            self.updateOverallProgressFromCurrentItem()
            if queueMode {
                completion?(success)
            } else {
                self.isRunning = false
                self.overallProgress = success ? 1 : self.overallProgress
                self.status = success ? "Completed" : "Failed"
                self.detail = success ? "File is ready." : "Download failed. Open details or copy the log, then retry."
                self.releaseFromBackgroundDownload()
            }
        })
    }

    func cancel() {
        guard isRunning else { return }
        cancellationRequested = true
        queuedURLs.removeAll()
        queueSubfolderName = nil

        if plugin?.killProcessTree(task) == true {
            // The process's completion handler reports "Cancelled" once it has actually exited.
            status = queueTotal > 1 ? "Cancelling queue…" : "Cancelling…"
            detail = queueTotal > 1 ? "Stopping the active queue item and its child processes." : "Stopping the active process and its child processes."
            return
        }

        // No process was running (e.g. a Spotify link was still being resolved), so stop right away.
        task = nil
        if queueTotal > 1 {
            finishQueue(cancelled: true)
        } else {
            isRunning = false
            status = "Cancelled"
            detail = "Stopped. No yt-dlp process was running."
            releaseFromBackgroundDownload()
        }
    }

    func checkTools() {
        guard !isRunning else { return }
        guard let plugin else { fail("Plugin not available."); return }
        cancellationRequested = false
        isRunning = true
        retainForBackgroundDownload()
        progress = 0
        overallProgress = 0
        status = "Checking tools…"
        detail = "Checking Homebrew, yt-dlp, FFmpeg, internet, folder and disk space."
        healthStatus = "Checking…"
        let path = folderPath.isEmpty ? plugin.defaultDownloadDirectory().path : folderPath
        task = plugin.startToolCheck(folderPath: path, progress: { [weak self] text in
            self?.healthStatus = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(6).joined(separator: " • ")
            self?.consumeOutput(text)
        }, completion: { [weak self] success in
            guard let self else { return }
            self.isRunning = false
            self.releaseFromBackgroundDownload()
            if self.cancellationRequested {
                self.status = "Cancelled"
                self.detail = "The tool check was stopped."
                self.cancellationRequested = false
                return
            }
            self.progress = success ? 1 : 0
            self.overallProgress = success ? 1 : 0
            self.status = success ? "Health OK" : "Needs attention"
            self.detail = success ? "All required downloader tools look ready." : "Something is missing or not writable. See status / Log."
        })
    }

    func updateTools() {
        guard !isRunning else { return }
        guard let plugin else { fail("Plugin not available."); return }
        cancellationRequested = false
        isRunning = true
        retainForBackgroundDownload()
        progress = 0
        status = "Updating tools…"
        detail = "Homebrew is installing/updating yt-dlp and FFmpeg."
        task = plugin.startToolUpdate(progress: { [weak self] text in self?.consumeOutput(text) }, completion: { [weak self] success in
            guard let self else { return }
            self.isRunning = false
            self.releaseFromBackgroundDownload()
            if self.cancellationRequested {
                self.status = "Cancelled"
                self.detail = "The update was stopped."
                self.cancellationRequested = false
                return
            }
            self.progress = success ? 1 : 0
            self.overallProgress = success ? 1 : 0
            self.status = success ? "Tools updated" : "Tool update failed"
            self.detail = success ? "yt-dlp and FFmpeg are ready." : "Copy Last Log for details."
            if success { self.checkTools() }
        })
    }

    func openCurrentFolder() {
        let path = folderPath.isEmpty ? plugin?.defaultDownloadDirectory().path ?? "" : folderPath
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
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
            rememberFolder(url.path)
            saveSettings()
        }
    }

    func toggleMode() {
        mode = mode == .video ? .audio : .video
        saveSettings()
    }

    func saveSettings() {
        defaults.set(mode.rawValue, forKey: DefaultsKey.mode)
        defaults.set(videoPreset, forKey: DefaultsKey.videoPreset)
        defaults.set(customFormat, forKey: DefaultsKey.customFormat)
        defaults.set(audioFormat, forKey: DefaultsKey.audioFormat)
        defaults.set(audioQuality, forKey: DefaultsKey.audioQuality)
        defaults.set(cookiesBrowser, forKey: DefaultsKey.cookiesBrowser)
        defaults.set(lastDownloadedFile, forKey: DefaultsKey.lastDownloadedFile)
        defaults.set(folderPath, forKey: DefaultsKey.folderPath)
    }

    private func rememberFolder(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folderPath = trimmed
    }

    func copyLog() {
        if plugin?.copyLastLog() == true {
            status = "Log copied"
            detail = "The last log is now on your clipboard."
        } else { fail("Could not copy the log.") }
    }

    func openLastFile() {
        if plugin?.openDownloadedFile(at: lastDownloadedFile) == true {
            status = "Opened file"
            detail = URL(fileURLWithPath: lastDownloadedFile).lastPathComponent
        } else {
            fail("No completed file found yet.")
        }
    }

    private func consumeOutput(_ text: String) {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("download:") {
                let payload = String(line.dropFirst("download:".count))
                let parts = payload.components(separatedBy: "|")
                if parts.count >= 3 {
                    let downloaded = parts.count > 3 ? Int64(parts[3].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                    let total = parts.count > 4 ? Int64(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                    updateProgress(percent: parts[0], speedText: parts[1], etaText: parts[2], downloadedBytes: downloaded, totalBytes: total)
                }
            } else if updatePlaylistCounter(from: line) {
                continue
            } else if let percentRange = line.range(of: #"\d+(?:\.\d+)?%"#, options: .regularExpression) {
                let percentText = String(line[percentRange])
                let speedText = firstMatch(in: line, pattern: #"at\s+([^\s]+/s)"#) ?? speed
                let etaText = firstMatch(in: line, pattern: #"ETA\s+([^\s]+)"#) ?? eta
                updateProgress(percent: percentText, speedText: speedText, etaText: etaText, downloadedBytes: nil, totalBytes: nil)
            } else if line.hasPrefix("/") || line.contains(".mp4") || line.contains(".webm") || line.contains(".mp3") || line.contains(".m4a") || line.contains(".mkv") || line.contains(".opus") || line.contains(".flac") || line.contains(".wav") {
                detail = line
                if line.hasPrefix("/") {
                    lastDownloadedFile = line
                    saveSettings()
                }
            }
        }
    }

    private func updatePlaylistCounter(from line: String) -> Bool {
        let patterns = [
            #"Downloading item\s+(\d+)\s+of\s+(\d+)"#,
            #"Downloading video\s+(\d+)\s+of\s+(\d+)"#,
            #"\[download\]\s+Downloading item\s+(\d+)\s+of\s+(\d+)"#,
            #"\[download\]\s+Downloading video\s+(\d+)\s+of\s+(\d+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 3,
                  let currentRange = Range(match.range(at: 1), in: line),
                  let totalRange = Range(match.range(at: 2), in: line) else { continue }
            let current = String(line[currentRange])
            let total = String(line[totalRange])
            playlistCurrentItem = Int(current) ?? playlistCurrentItem
            playlistTotalItems = Int(total) ?? playlistTotalItems
            playlistCounter = "\(current) of \(total)"
            status = "Downloading item \(current) of \(total)"
            updateOverallProgressFromCurrentItem()
            return true
        }
        return false
    }

    private func updateProgress(percent: String, speedText: String, etaText: String, downloadedBytes: Int64?, totalBytes: Int64?) {
        let cleanedPercent = percent.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let p = Double(cleanedPercent) { progress = min(max(p / 100.0, 0), 1) }
        if let downloadedBytes, downloadedBytes > 0 { transferredBytes = downloadedBytes }
        if let totalBytes, totalBytes > 0 { self.totalBytes = totalBytes }
        updateOverallProgressFromCurrentItem()
        let cleanSpeed = speedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanETA = etaText.trimmingCharacters(in: .whitespacesAndNewlines)
        speed = cleanSpeed.isEmpty || cleanSpeed.uppercased() == "NA" ? "—" : cleanSpeed
        eta = cleanETA.isEmpty || cleanETA.uppercased() == "NA" ? "—" : cleanETA
        if progress >= 1 {
            status = "Processing"
            detail = "Finalizing, merging, or converting media."
        } else {
            status = playlistTotalItems > 1 ? "Downloading item \(max(playlistCurrentItem, 1)) of \(playlistTotalItems)" : "Downloading"
            let overallText = playlistTotalItems > 1 ? " • Total \(Int(overallProgress * 100))%" : ""
            detail = "\(Int(progress * 100))% current item\(overallText)"
        }
    }

    private func updateOverallProgressFromCurrentItem() {
        let itemProgress: Double
        if playlistTotalItems > 1, playlistCurrentItem > 0 {
            let completedItems = max(0, playlistCurrentItem - 1)
            itemProgress = (Double(completedItems) + min(max(progress, 0), 1)) / Double(playlistTotalItems)
        } else {
            itemProgress = progress
        }

        if queueTotal > 1 {
            let combined = (Double(queueCompleted) + min(max(itemProgress, 0), 1)) / Double(queueTotal)
            overallProgress = min(max(combined, overallProgress), 1)
        } else {
            overallProgress = min(max(itemProgress, overallProgress), 1)
        }
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    var hasValidOutputFile: Bool {
        let path = lastDownloadedFile.trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    func revealLastFile() {
        guard hasValidOutputFile else {
            fail("No completed file is available to reveal.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastDownloadedFile)])
    }

    private func fail(_ message: String) {
        status = "Failed"
        detail = message
    }
}

struct VideoDownloaderDashboardView: View {
    @ObservedObject var model: VideoDownloaderViewModel

    private let panelWidth: CGFloat = 806
    private let panelHeight: CGFloat = 350
    private let rightWidth: CGFloat = 245
    private let accent = Color.accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            leftColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            rightColumn
                .frame(width: rightWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(width: panelWidth, height: panelHeight, alignment: .top)
        .background(Color.clear)
        .onChange(of: model.url, perform: sourceChanged)
        .onChange(of: model.mode, perform: settingsChanged)
        .onChange(of: model.videoPreset, perform: settingsChanged)
        .onChange(of: model.customFormat, perform: settingsChanged)
        .onChange(of: model.audioFormat, perform: settingsChanged)
        .onChange(of: model.audioQuality, perform: settingsChanged)
        .onChange(of: model.cookiesBrowser, perform: settingsChanged)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            sourceSection
            optionsSection
            destinationSection
            Spacer(minLength: 0)
            hintsBar
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 9) {
            previewCard
            statusCard
            settingsCard
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(accent.opacity(0.14))
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 36, height: 36)
            .accessibilityLabel("Media Downloader")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Media Downloader")
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    statusPill
                }
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(statusColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.12), in: Capsule())
        .accessibilityLabel("Status: \(statusLabel)")
    }

    private var sourceSection: some View {
        section("Source") {
            HStack(spacing: 6) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                TextField("Paste URL, search text, or multi-line list", text: $model.url)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1)
                    .disabled(model.isRunning)
                    .accessibilityLabel("Source URL or search text")
                Button {
                    model.pasteFromClipboard()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .help("Paste from Clipboard")
                .accessibilityLabel("Paste from Clipboard")
                Button {
                    model.url = ""
                    model.queueStatus = ""
                    model.playlistCounter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning || model.url.isEmpty)
                .help("Clear Source")
                .accessibilityLabel("Clear Source")
            }
            .controlRowBackground()

            HStack(spacing: 6) {
                Image(systemName: validationIcon)
                    .foregroundStyle(validationColor)
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var optionsSection: some View {
        section("Download Options") {
            Picker("Mode", selection: $model.mode) {
                ForEach(DownloadMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
            .disabled(model.isRunning)

            HStack(spacing: 12) {
                if model.mode == .video {
                    compactMenu("Format", selection: $model.videoPreset, values: model.videoPresets, width: 330)
                        .disabled(model.isRunning)
                } else {
                    compactMenu("Format", selection: $model.audioFormat, values: model.audioFormats, width: 150)
                        .disabled(model.isRunning)
                    if model.audioFormat != "WAV" && model.audioFormat != "FLAC" {
                        compactMenu("Quality", selection: $model.audioQuality, values: model.audioQualities, width: 190)
                            .disabled(model.isRunning)
                    }
                }
                Spacer(minLength: 0)
            }
            if model.mode == .video && model.videoPreset == "Custom yt-dlp selector" {
                TextField("yt-dlp selector", text: $model.customFormat)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .disabled(model.isRunning)
            }
            if model.isRunning {
                Text("Current job uses the settings selected when it started.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var destinationSection: some View {
        section("Destination") {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(destinationName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.folderPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(model.folderPath)
                    Spacer(minLength: 0)
                    Button("Choose") { model.chooseFolder() }
                        .controlSize(.small)
                        .disabled(model.isRunning)
                        .help("Choose Download Folder")
                    Button {
                        model.openCurrentFolder()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help("Open Destination Folder")
                    .accessibilityLabel("Open Destination Folder")
                }
                .controlRowBackground()
                .frame(maxWidth: .infinity)
                .frame(height: 46)

                Group {
                    if model.isRunning {
                        Button(role: .cancel) {
                            model.cancel()
                        } label: {
                            Text("Cancel")
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .help("Stop the active download")
                    } else {
                        Button {
                            model.start()
                        } label: {
                            Text("Download")
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .keyboardShortcut(.return, modifiers: [])
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .disabled(model.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(model.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                        .help("Start download")
                    }
                }
                .frame(width: 132, height: 46)
                .controlSize(.regular)
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                if let image = model.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: rightWidth, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: model.isRunning ? "arrow.down.circle" : "play.rectangle.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(model.isRunning ? "Downloading…" : "Preview")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: rightWidth, height: 112)
            .clipped()

            Text(previewTitle)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(previewSubtitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !model.mediaDuration.isEmpty {
                    Text("•")
                    Text(model.mediaDuration)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: statusSystemImage)
                    .foregroundStyle(statusColor)
                Text(model.status)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(model.sizeEstimate.replacingOccurrences(of: "Approx. ", with: ""))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(model.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(model.isRunning ? 1 : 2)
                .truncationMode(.tail)
            if model.isRunning {
                ProgressView(value: model.overallProgress > 0 ? model.overallProgress : nil)
                    .progressViewStyle(.linear)
                    .tint(accent)
                HStack(spacing: 8) {
                    if let downloaded = model.transferredBytes {
                        Text(byteProgress(downloaded: downloaded, total: model.totalBytes))
                    }
                    if cleanMetric(model.speed) != "—" {
                        Text(cleanMetric(model.speed))
                    }
                    if cleanMetric(model.eta) != "—" {
                        Text(cleanETA(model.eta))
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            let counterText = model.queueStatus.isEmpty ? model.playlistCounter : model.queueStatus
            if !counterText.isEmpty {
                Text(counterText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if !model.healthStatus.isEmpty {
                DisclosureGroup("Technical details") {
                    Text(model.healthStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .font(.caption2)
            }
        }
        .padding(9)
        .frame(height: 112, alignment: .topLeading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var settingsCard: some View {
        HStack(spacing: 7) {
            Menu {
                Picker("Cookies", selection: $model.cookiesBrowser) {
                    ForEach(model.cookiesBrowsers, id: \.self) { Text($0).tag($0) }
                }
                Divider()
                Button("Check Tools") { model.checkTools() }.disabled(model.isRunning)
                Button("Update Tools") { model.updateTools() }.disabled(model.isRunning)
                Button("Copy Log") { model.copyLog() }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .menuStyle(.button)
            .controlSize(.small)
            .help("Cookies, health check, updates, and logs")

            Spacer()
            if model.isRunning {
                Text("Background safe")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if model.hasValidOutputFile {
                Button("Open") { model.openLastFile() }
                    .controlSize(.small)
                    .help("Open the last downloaded file")
                    .accessibilityLabel("Open Downloaded File")
                Button("Reveal") { model.revealLastFile() }
                    .controlSize(.small)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
            }
        }
    }

    private var hintsBar: some View {
        HStack(spacing: 10) {
            Label("Download", systemImage: "return")
            Label("Mode", systemImage: "arrow.right.to.line.compact")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content()
        }
    }

    private func compactMenu(_ title: String, selection: Binding<String>, values: [String], width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(width: width, alignment: .leading)
    }

    private func sourceChanged(_ value: String) {
        model.schedulePreview()
    }

    private func settingsChanged<T>(_ value: T) {
        model.saveSettings()
        model.schedulePreview()
    }

    private var headerSubtitle: String {
        model.isRunning ? "Working in background if this panel closes." : "Paste, search, or download media with yt-dlp."
    }

    private var validationMessage: String {
        let trimmed = model.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Waiting for a URL or search text." }
        if trimmed.contains("\n") { return "Multi-line list will download in order." }
        if trimmed.lowercased().hasPrefix("http") { return "URL detected." }
        return "Search text will use the first YouTube result."
    }

    private var validationIcon: String {
        model.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "circle" : "checkmark.circle.fill"
    }

    private var validationColor: Color {
        model.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .green
    }

    private var sourceIcon: String {
        model.url.contains("\n") ? "music.note.list" : (model.url.lowercased().hasPrefix("http") ? "link" : "magnifyingglass")
    }

    private var destinationName: String {
        let trimmed = model.folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Default Downloads Folder" }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private var previewTitle: String {
        if !model.mediaTitle.isEmpty { return model.mediaTitle }
        let trimmed = model.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "No source selected" }
        if trimmed.contains("\n") { return "Text playlist" }
        if let host = URLComponents(string: trimmed)?.host { return host.replacingOccurrences(of: "www.", with: "") }
        return trimmed
    }

    private var previewSubtitle: String {
        if !model.mediaSource.isEmpty { return model.mediaSource }
        let trimmed = model.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Paste a URL or search text to begin." }
        return URLComponents(string: trimmed)?.host?.replacingOccurrences(of: "www.", with: "") ?? "YouTube search"
    }

    private var statusLabel: String {
        if model.isRunning { return "Active" }
        if model.status.lowercased().contains("fail") || model.status.lowercased().contains("attention") { return "Issue" }
        if model.status.lowercased().contains("finish") || model.status.lowercased().contains("updated") || model.status.lowercased().contains("ok") { return "Ready" }
        return "Idle"
    }

    private var statusColor: Color {
        if model.isRunning { return accent }
        if model.status.lowercased().contains("fail") || model.status.lowercased().contains("attention") { return .red }
        if model.status.lowercased().contains("finish") || model.status.lowercased().contains("updated") || model.status.lowercased().contains("ok") { return .green }
        return .secondary
    }

    private var statusSystemImage: String {
        if model.isRunning { return "arrow.down.circle" }
        if model.status.lowercased().contains("fail") || model.status.lowercased().contains("attention") { return "exclamationmark.triangle" }
        if model.status.lowercased().contains("finish") || model.status.lowercased().contains("updated") || model.status.lowercased().contains("ok") { return "checkmark.circle" }
        return "circle"
    }

    private func byteProgress(downloaded: Int64, total: Int64?) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let current = formatter.string(fromByteCount: downloaded)
        guard let total, total > 0 else { return current }
        return "\(current) / \(formatter.string(fromByteCount: total))"
    }

    private func cleanMetric(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "NA" ? "—" : trimmed
    }

    private func cleanETA(_ value: String) -> String {
        let trimmed = cleanMetric(value)
        return trimmed == "—" ? "ETA —" : "ETA \(trimmed)"
    }
}

private extension View {
    func controlRowBackground() -> some View {
        self
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.055), lineWidth: 1)
            )
    }
}
