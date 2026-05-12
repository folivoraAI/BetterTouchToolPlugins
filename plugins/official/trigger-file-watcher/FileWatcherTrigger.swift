// BTT-Plugin-Name: File Watcher
// BTT-Plugin-Identifier: com.folivora.btt.trigger.filewatcher
// BTT-Plugin-Type: Trigger
// BTT-Plugin-Icon: doc.badge.clock

import Cocoa

/// A sample trigger plugin that fires when a specific file or folder changes.
///
/// The user configures the path to watch via the plugin configuration form.
/// When a change is detected, the trigger fires with the path as context,
/// available as the BTT variable `TriggerPlugin_changedPath`.
class FileWatcherTrigger: NSObject, BTTTriggerPluginInterface {
    weak var delegate: (any BTTTriggerPluginDelegate)?
    private var watchedPath: String = ""
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?

    // MARK: - Metadata

    static func triggerName() -> String { "File Watcher" }
    static func triggerDescription() -> String { "Fires when a file or folder changes" }
    static func triggerIcon() -> String { "doc.badge.clock" }

    // MARK: - Configuration

    static func configurationFormItems() -> BTTPluginFormItem? {
        let group = BTTPluginFormItem()
        group.formFieldType = BTTFormTypeFormGroup

        let pathField = BTTPluginFormItem()
        pathField.formFieldType = BTTFormTypeTextField
        pathField.formFieldID = "plugin_var_watchPath"
        pathField.formLabel1 = "Path to watch"
        pathField.defaultValue = "~/Desktop" as NSString
        pathField.dataType = .string

        group.formOptions = [pathField]
        return group
    }

    func didReceiveNewConfigurationValues(_ config: [String: Any]?) {
        let newPath = (config?["plugin_var_watchPath"] as? String ?? "~/Desktop")
            .replacingOccurrences(of: "~", with: NSHomeDirectory())
        if newPath != watchedPath {
            // Path changed — restart watching if we're currently observing
            let wasObserving = dispatchSource != nil
            if wasObserving { stopObserving() }
            watchedPath = newPath
            if wasObserving { startObserving() }
        }
    }

    // MARK: - Lifecycle

    func startObserving() {
        guard !watchedPath.isEmpty else { return }

        let path = watchedPath
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main
        )

        dispatchSource?.setEventHandler { [weak self] in
            guard let self else { return }
            self.delegate?.triggerFired(self, withContext: ["changedPath": path])
        }

        dispatchSource?.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        dispatchSource?.resume()
    }

    func stopObserving() {
        dispatchSource?.cancel()
        dispatchSource = nil
        // fileDescriptor is closed in the cancel handler
    }
}
