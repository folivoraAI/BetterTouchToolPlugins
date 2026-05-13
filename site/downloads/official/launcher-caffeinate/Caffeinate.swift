// BTT-Plugin-Name: Caffeinate
// BTT-Plugin-Identifier: com.folivora.btt.launcher.caffeinate
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: zzz
// BTT-AI-Managed: true

import AppKit
import Darwin

final class CaffeinateLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let toggle = "toggle-caffeinate"
    }

    private let pidFileName = "com.folivora.btt.launcher.caffeinate.pid"

    static func launcherPluginName() -> String { "Caffeinate" }
    static func launcherPluginDescription() -> String { "Keeps the Mac awake by toggling a background caffeinate process." }
    static func launcherPluginIcon() -> String { "zzz" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let query = (context.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            let matches = query.contains("caff") || query.contains("awake") || query.contains("sleep") || query.contains("keep")
            if !matches { return nil }
        }

        let running = isCaffeinateRunning()
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = IDs.toggle
        result.title = running ? "Stop Keeping Awake" : "Keep Awake"
        result.subtitle = running ? "Caffeinate is running." : "Starts caffeinate until you toggle it off."
        result.systemImageName = running ? "moon.zzz.fill" : "zzz"
        result.trailingHint = running ? "Stop" : "Start"
        result.primaryActionIdentifier = IDs.toggle
        result.keywords = ["caffeinate", "awake", "sleep", "keep awake", "insomnia"]
        result.searchMatchPriority = 10
        return [result]
    }

    func performAction(forItemIdentifier itemIdentifier: String, actionIdentifier: String?, context: BTTLauncherPluginContext) -> BTTLauncherPluginActionResult? {
        guard itemIdentifier == IDs.toggle else { return nil }

        let running = isCaffeinateRunning()
        let success: Bool
        let message: String

        if running {
            success = stopCaffeinate()
            message = success ? "Caffeinate stopped." : "Could not stop caffeinate."
        } else {
            success = startCaffeinate()
            message = success ? "Caffeinate started." : "Could not start caffeinate."
        }

        let result = BTTLauncherPluginActionResult()
        result.success = success
        result.message = message
        result.closeLauncher = true
        delegate?.requestLauncherResultsRefresh()
        return result
    }

    private func pidFileURL() -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BetterTouchTool/Plugins", isDirectory: true)
        return base.appendingPathComponent(pidFileName)
    }

    private func currentPid() -> pid_t? {
        let url = pidFileURL()
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(text), pid > 0 else {
            return nil
        }
        return pid
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func isCaffeinateRunning() -> Bool {
        guard let pid = currentPid() else { return false }
        if isProcessAlive(pid) { return true }
        try? FileManager.default.removeItem(at: pidFileURL())
        return false
    }

    private func startCaffeinate() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-dimsu"]
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            writePid(process.processIdentifier)
            return true
        } catch {
            return false
        }
    }

    private func stopCaffeinate() -> Bool {
        guard let pid = currentPid() else { return true }
        _ = kill(pid, SIGTERM)
        try? FileManager.default.removeItem(at: pidFileURL())
        return true
    }

    private func writePid(_ pid: pid_t) {
        let url = pidFileURL()
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? String(pid).write(to: url, atomically: true, encoding: .utf8)
    }
}
