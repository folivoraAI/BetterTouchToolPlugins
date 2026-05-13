// BTT-Plugin-Name: QuickTime Recording
// BTT-Plugin-Identifier: com.bttuserplugin.quicktime.recording
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: record.circle.fill
// BTT-AI-Managed: true

import AppKit

class QuickTimeRecordingPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let screenRecording = "screen-recording"
        static let audioRecording  = "audio-recording"
        static let movieRecording  = "movie-recording"
    }

    // MARK: - Metadata

    static func launcherPluginName() -> String { "QuickTime Recording" }
    static func launcherPluginDescription() -> String { "Start a QuickTime screen, audio, or movie recording." }
    static func launcherPluginIcon() -> String { "record.circle.fill" }

    // MARK: - Results

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let items: [(id: String, title: String, icon: String, menuItem: String)] = [
            (IDs.screenRecording, "Start Screen Recording", "rectangle.dashed.badge.record", "New Screen Recording"),
            (IDs.audioRecording,  "Start Audio Recording",  "mic.fill.badge.plus",           "New Audio Recording"),
            (IDs.movieRecording,  "Start Movie Recording",  "video.badge.plus",              "New Movie Recording"),
        ]

        let query = (context.query ?? "").lowercased()
        let qtIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/QuickTime Player.app")

        return items.compactMap { item in
            if !query.isEmpty,
               !item.title.lowercased().contains(query),
               !"quicktime".contains(query) {
                return nil
            }

            let result = BTTLauncherPluginResult()
            result.itemIdentifier = item.id
            result.title = item.title
            result.subtitle = "QuickTime"
            result.systemImageName = item.icon
            result.iconImage = qtIcon
            result.primaryActionIdentifier = "open"
            result.trailingHint = "Start"
            result.keywords = ["quicktime", "record", "qt", item.menuItem.lowercased()]
            return result
        }
    }

    // MARK: - Actions

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {
        let menuItem: String
        switch itemIdentifier {
        case IDs.screenRecording: menuItem = "New Screen Recording"
        case IDs.audioRecording:  menuItem = "New Audio Recording"
        case IDs.movieRecording:  menuItem = "New Movie Recording"
        default: return nil
        }

        let script = """
        tell application "QuickTime Player" to activate
        delay 0.25
        tell application "System Events"
            tell process "QuickTime Player"
                click menu item "\(menuItem)" of menu "File" of menu bar 1
            end tell
        end tell
        """

        var errorDict: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorDict)

        let actionResult = BTTLauncherPluginActionResult()
        actionResult.success = errorDict == nil
        actionResult.closeLauncher = true
        if let err = errorDict {
            actionResult.message = err[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
        }
        return actionResult
    }
}
