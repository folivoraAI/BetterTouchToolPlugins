// BTT-Plugin-Name: Plugin Name
// BTT-Plugin-Identifier: com.example.btt.plugin-name
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: puzzlepiece.extension

import Cocoa

final class PluginName: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    static func launcherPluginName() -> String { "Plugin Name" }
    static func launcherPluginDescription() -> String { "Short description of what this plugin does." }
    static func launcherPluginIcon() -> String { "puzzlepiece.extension" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = "example"
        result.title = "Example Result"
        result.subtitle = "Replace this with your plugin's behavior."
        result.systemImageName = "puzzlepiece.extension"
        return [result]
    }
}
