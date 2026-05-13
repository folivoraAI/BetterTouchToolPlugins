// BTT-Plugin-Name: Clipboard Change
// BTT-Plugin-Identifier: com.folivora.btt.trigger.clipboardchange
// BTT-Plugin-Type: Trigger
// BTT-Plugin-Icon: doc.on.clipboard

import Cocoa

/// A sample trigger plugin that fires whenever the system clipboard content changes.
///
/// When the trigger fires, the current clipboard text is passed as context
/// and becomes available as the BTT variable `TriggerPlugin_clipboardContent`.
class ClipboardChangeTrigger: NSObject, BTTTriggerPluginInterface {
    weak var delegate: (any BTTTriggerPluginDelegate)?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    // MARK: - Metadata

    static func triggerName() -> String { "Clipboard Change" }
    static func triggerDescription() -> String { "Fires when the system clipboard content changes" }
    static func triggerIcon() -> String { "doc.on.clipboard" }

    // MARK: - Configuration

    /// This plugin has no configuration options.
    /// Return a BTTPluginFormItem to add config fields (text fields, checkboxes, etc.)
    static func configurationFormItems() -> BTTPluginFormItem? { nil }

    func didReceiveNewConfigurationValues(_ config: [String: Any]?) {
        // Handle configuration changes here if you add config form items
    }

    // MARK: - Lifecycle

    func startObserving() {
        // Reset to current state so we don't fire immediately
        lastChangeCount = NSPasteboard.general.changeCount

        // Poll the pasteboard every second — macOS doesn't provide a notification for clipboard changes
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = NSPasteboard.general.changeCount
            if current != self.lastChangeCount {
                self.lastChangeCount = current
                let content = NSPasteboard.general.string(forType: .string) ?? ""
                // Fire the trigger and pass clipboard content as context.
                // BTT will store this as the variable "TriggerPlugin_clipboardContent".
                self.delegate?.triggerFired(self, withContext: ["clipboardContent": content])
            }
        }
    }

    func stopObserving() {
        timer?.invalidate()
        timer = nil
    }
}
