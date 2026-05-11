// BTT-Plugin-Name: Sample Launcher Plugin
// BTT-Plugin-Identifier: com.folivora.launcher.sample
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: sparkles.rectangle.stack

import AppKit
import Foundation

class SampleLauncherPlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    private enum IDs {
        static let root = "sample-root"
        static let increment = "increment"
        static let reset = "reset"
        static let fireTrigger = "fire-trigger"
        static let details = "details"
        static let copyValue = "copy-value"
        static let commandReset = "command-reset"
        static let commandTrigger = "command-trigger"
        static let panelItem = "panel-item"
        static let panelSurface = "panel-surface"
    }

    private let counterVariableName = "LauncherPluginSampleCounter"
    private let demoTriggerName = "Launcher Plugin Sample Trigger"
    private lazy var panelSurface = SampleLauncherPanelSurface(
        counterVariableName: counterVariableName,
        triggerName: demoTriggerName
    )

    static func launcherPluginName() -> String { "Sample Launcher Plugin" }
    static func launcherPluginDescription() -> String { "Demonstrates launcher results, child items, actions, item commands, and a native launcher surface." }
    static func launcherPluginIcon() -> String { "sparkles.rectangle.stack" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let count = currentCount
        let root = BTTLauncherPluginResult()
        root.itemIdentifier = IDs.root
        root.title = "Launcher Plugin Demo"
        root.subtitle = "Counter: \(count)"
        root.systemImageName = "sparkles.rectangle.stack"
        root.keywords = ["plugin", "demo", "counter", "launcher"]
        root.trailingHint = "↩"
        root.primaryActionIdentifier = IDs.increment
        root.opensChildrenByDefault = false
        root.children = [
            childResult(
                id: IDs.details,
                title: "Current Counter Value",
                subtitle: "The stored counter is \(count).",
                systemImageName: "number.circle"
            ),
            childResult(
                id: IDs.copyValue,
                title: "Copy Counter Value",
                subtitle: "Copies \(count) to the clipboard.",
                systemImageName: "doc.on.doc",
                actionIdentifier: IDs.copyValue
            ),
            childResult(
                id: IDs.fireTrigger,
                title: "Fire Named Trigger",
                subtitle: "Triggers \"\(demoTriggerName)\" if it exists.",
                systemImageName: "bolt.fill",
                actionIdentifier: IDs.fireTrigger
            ),
        ]

        let resetShortcut = BTTLauncherPluginShortcut()
        resetShortcut.character = "r"
        resetShortcut.modifierFlags = [.command]
        resetShortcut.displayKeys = ["⌘", "R"]

        let resetCommand = BTTLauncherPluginCommand()
        resetCommand.commandIdentifier = IDs.commandReset
        resetCommand.title = "Reset Counter"
        resetCommand.subtitle = "Set the sample counter back to zero."
        resetCommand.systemImageName = "arrow.counterclockwise"
        resetCommand.shortcut = resetShortcut
        resetCommand.closesLauncherOnSuccess = false

        let triggerShortcut = BTTLauncherPluginShortcut()
        triggerShortcut.character = "t"
        triggerShortcut.modifierFlags = [.command, .shift]
        triggerShortcut.displayKeys = ["⌘", "⇧", "T"]

        let triggerCommand = BTTLauncherPluginCommand()
        triggerCommand.commandIdentifier = IDs.commandTrigger
        triggerCommand.title = "Run Sample Trigger"
        triggerCommand.subtitle = "Executes a named BTT trigger from the command list."
        triggerCommand.systemImageName = "bolt.badge.a"
        triggerCommand.shortcut = triggerShortcut
        triggerCommand.closesLauncherOnSuccess = false

        root.commands = [resetCommand, triggerCommand]

        let panel = BTTLauncherPluginResult()
        panel.itemIdentifier = IDs.panelItem
        panel.title = "Open Sample Panel"
        panel.subtitle = "Shows a native launcher surface with live controls."
        panel.systemImageName = "rectangle.inset.filled.and.person.filled"
        panel.surfaceIdentifier = IDs.panelSurface
        panel.trailingHint = "Open"
        panel.keywords = ["panel", "surface", "native", "pinned"]

        if let query = context.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !query.isEmpty,
           "value".contains(query) {
            return [
                root,
                panel,
                childResult(
                    id: "direct-value",
                    title: "Counter Value \(count)",
                    subtitle: "Direct match for value-focused searches.",
                    systemImageName: "number.square"
                ),
            ]
        }

        return [root, panel]
    }

    func performAction(
        forItemIdentifier itemIdentifier: String,
        actionIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> BTTLauncherPluginActionResult? {
        let action = actionIdentifier ?? itemIdentifier
        switch action {
        case IDs.increment:
            currentCount += 1
            delegate?.requestLauncherResultsRefresh()
            return result(success: true, message: "Sample counter increased to \(currentCount).")

        case IDs.reset, IDs.commandReset:
            currentCount = 0
            delegate?.requestLauncherResultsRefresh()
            return result(success: true, message: "Sample counter reset.")

        case IDs.fireTrigger, IDs.commandTrigger:
            delegate?.executeNamedTrigger(demoTriggerName)
            return result(success: true, message: "Triggered \"\(demoTriggerName)\".")

        case IDs.copyValue:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("\(currentCount)", forType: .string)
            return result(success: true, message: "Copied counter value \(currentCount).")

        default:
            return result(success: false, message: "The sample launcher plugin does not know how to handle \(action).")
        }
    }

    func launcherSurface(
        forItemIdentifier itemIdentifier: String,
        surfaceIdentifier: String?,
        context: BTTLauncherPluginContext
    ) -> (any BTTLauncherPluginSurfaceInterface)? {
        guard itemIdentifier == IDs.panelItem, surfaceIdentifier == IDs.panelSurface else {
            return nil
        }

        panelSurface.updateFromStoredState()
        return panelSurface
    }

    private var currentCount: Int {
        get {
            if let number = delegate?.getVariable(counterVariableName) as? NSNumber {
                return number.intValue
            }
            if let string = delegate?.getVariable(counterVariableName) as? String,
               let number = Int(string) {
                return number
            }
            return 0
        }
        set {
            delegate?.setVariable(counterVariableName, value: NSNumber(value: newValue))
        }
    }

    private func childResult(
        id: String,
        title: String,
        subtitle: String,
        systemImageName: String,
        actionIdentifier: String? = nil
    ) -> BTTLauncherPluginResult {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = id
        result.title = title
        result.subtitle = subtitle
        result.systemImageName = systemImageName
        result.primaryActionIdentifier = actionIdentifier
        return result
    }

    private func result(success: Bool, message: String) -> BTTLauncherPluginActionResult {
        let result = BTTLauncherPluginActionResult()
        result.success = success
        result.message = message
        result.closeLauncher = false
        return result
    }
}

final class SampleLauncherPanelSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?

    private let counterVariableName: String
    private let triggerName: String

    private var keepsPinned = true
    private var statusMessage: String?
    private var queryText: String = ""

    private lazy var counterLabel = NSTextField(labelWithString: "")
    private lazy var queryLabel = NSTextField(labelWithString: "")
    private lazy var pinLabel = NSTextField(labelWithString: "")
    private lazy var containerView = buildContainerView()

    init(counterVariableName: String, triggerName: String) {
        self.counterVariableName = counterVariableName
        self.triggerName = triggerName
        super.init()
    }

    func makeLauncherSurfaceView() -> NSView {
        refreshLabels()
        return containerView
    }

    func launcherSurfaceDidAppear() {
        refreshLabels()
    }

    func launcherSurfaceQueryDidChange(_ query: String?) {
        queryText = query ?? ""
        refreshLabels()
    }

    func launcherSurfacePlaceholderText() -> String? {
        "Sample Launcher Panel"
    }

    func launcherSurfaceFooterHint() -> String? {
        "↩ +1 counter • Esc results • Buttons can request pinning or close"
    }

    func launcherSurfaceStatusText() -> String? {
        statusMessage
    }

    func launcherSurfacePreferredContentSize() -> CGSize {
        CGSize(width: 540, height: 320)
    }

    func launcherSurfaceMinimumContentSize() -> CGSize {
        CGSize(width: 460, height: 280)
    }

    func launcherSurfaceKeepsLauncherPinned() -> Bool {
        keepsPinned
    }

    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        switch command.rawValue {
        case 7:
            incrementCounter()
            return handledResult()
        case 11:
            return nil
        default:
            return nil
        }
    }

    func updateFromStoredState() {
        refreshLabels()
        delegate?.requestLauncherSurfaceUpdate()
    }

    @objc private func incrementCounter() {
        currentCount += 1
        statusMessage = "Counter increased to \(currentCount)."
        refreshAndPublish()
    }

    @objc private func resetCounter() {
        currentCount = 0
        statusMessage = "Counter reset."
        refreshAndPublish()
    }

    @objc private func copyCounter() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(currentCount)", forType: .string)
        statusMessage = "Copied counter value \(currentCount)."
        refreshAndPublish()
    }

    @objc private func fireTrigger() {
        delegate?.executeNamedTrigger(triggerName)
        statusMessage = "Triggered \"\(triggerName)\"."
        refreshAndPublish()
    }

    @objc private func togglePinnedState() {
        keepsPinned.toggle()
        statusMessage = keepsPinned
            ? "The sample panel will stay pinned on outside click."
            : "The sample panel will close again on outside click."
        refreshAndPublish()
    }

    @objc private func goBack() {
        delegate?.requestLauncherSurfaceGoBack()
    }

    @objc private func closeLauncher() {
        delegate?.requestLauncherSurfaceClose()
    }

    private var currentCount: Int {
        get {
            if let number = delegate?.getVariable(counterVariableName) as? NSNumber {
                return number.intValue
            }
            if let string = delegate?.getVariable(counterVariableName) as? String,
               let number = Int(string) {
                return number
            }
            return 0
        }
        set {
            delegate?.setVariable(counterVariableName, value: NSNumber(value: newValue))
        }
    }

    private func refreshAndPublish() {
        refreshLabels()
        delegate?.requestLauncherResultsRefresh()
        delegate?.requestLauncherSurfaceUpdate()
    }

    private func refreshLabels() {
        counterLabel.stringValue = "Counter: \(currentCount)"
        queryLabel.stringValue = queryText.isEmpty ? "Surface query: empty" : "Surface query: \(queryText)"
        pinLabel.stringValue = keepsPinned ? "Outside click is pinned for this panel." : "Outside click will close the launcher again."
    }

    private func buildContainerView() -> NSView {
        counterLabel.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
        queryLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        queryLabel.textColor = .secondaryLabelColor
        pinLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        pinLabel.textColor = .secondaryLabelColor

        let summaryStack = NSStackView(views: [counterLabel, queryLabel, pinLabel])
        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = 8

        let primaryActions = NSStackView(views: [
            button(title: "Increment", action: #selector(incrementCounter)),
            button(title: "Reset", action: #selector(resetCounter)),
            button(title: "Copy", action: #selector(copyCounter)),
            button(title: "Trigger", action: #selector(fireTrigger)),
        ])
        primaryActions.orientation = .horizontal
        primaryActions.spacing = 10

        let launcherActions = NSStackView(views: [
            button(title: "Toggle Pin", action: #selector(togglePinnedState)),
            button(title: "Back", action: #selector(goBack)),
            button(title: "Close", action: #selector(closeLauncher)),
        ])
        launcherActions.orientation = .horizontal
        launcherActions.spacing = 10

        let rootStack = NSStackView(views: [summaryStack, primaryActions, launcherActions])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 16
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            rootStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
        ])

        return container
    }

    private func button(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func handledResult() -> BTTLauncherPluginSurfaceCommandResult {
        let result = BTTLauncherPluginSurfaceCommandResult()
        result.handled = true
        result.closeLauncher = false
        result.goBack = false
        return result
    }
}
