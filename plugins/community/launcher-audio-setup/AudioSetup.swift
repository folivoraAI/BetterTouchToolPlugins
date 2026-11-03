// BTT-Plugin-Name: Audio Setup
// BTT-Plugin-Identifier: com.loaysax.btt.set-audio-device
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: slider.horizontal.3

import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Launcher plugin

final class SetAudioDevicePlugin: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?
    private enum IDs {
        static let setup = "audio.setup"
        static let output = "audio.output"
        static let input = "audio.input"
        static let presets = "audio.presets"
        static let deviceControls = "audio.device.controls"
        static let presetControls = "audio.preset.controls"
        static let newPreset = "audio.preset.new"
        static let undo = "audio.preset.undo"
        static let help = "audio.help"
        static let comboPrefix = "audio.combo."
        static let show = "show-in-main-launcher"
        static let hide = "hide-from-main-launcher"
        static let switchDevice = "switch"
        static let mute = "mute"
        static let lockDevice = "default"
        static let pinVolume = "pin-volume"
        static let rename = "rename-preset"
        static let update = "save-combo"
        static let duplicate = "duplicate-preset"
        static let delete = "delete-preset"
    }
    private let audio = AudioDeviceController.shared
    private let settings = AudioDeviceSettings.shared
    private var volumeSurfaces: [String: AudioVolumeSurface] = [:]
    private var dialogIsOpen = false
    private var observer: NSObjectProtocol?
    private struct UndoEntry {
        let slot: Int
        let before: PresetSnapshot
        let after: AudioCombo?
        let label: String
    }
    private var undoEntries: [UndoEntry] = []

    override init() {
        super.init()
        AudioChangeMonitor.shared.start()
        AudioDeviceEnforcer.shared.start()
        observer = NotificationCenter.default.addObserver(forName: .audioSetupDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    static func launcherPluginName() -> String { "Audio Setup" }
    static func launcherPluginDescription() -> String {
        "Your audio control room: devices, exact volume, preferred-device locks, and reusable presets."
    }
    static func launcherPluginIcon() -> String { "slider.horizontal.3" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let root = row(IDs.setup, "Audio Setup", "Output • Input • Presets", "slider.horizontal.3", color: .controlAccentColor)
        root.keywords = ["audio", "setup", "sound", "volume", "microphone", "presets"]
        root.dynamicChildrenIdentifier = IDs.setup
        root.opensChildrenByDefault = true
        root.trailingHint = "Open"
        let shortcuts = sectionResults(context: context).filter {
            settings.showsInMainLauncher(itemID: $0.itemIdentifier ?? "", launcherID: context.launcherID)
        }
        let presets = sortedPresetIDs(context: context).filter {
            settings.showsInMainLauncher(itemID: presetID($0), launcherID: context.launcherID)
        }.map { comboResult(slot: $0, context: context) }
        return ordered([root] + shortcuts + presets)
    }

    private func sectionResults(context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult] {
        let output = row(IDs.output, "Audio Output", currentDeviceSubtitle(.output), "speaker.wave.2.fill", color: .systemBlue)
        output.keywords = ["audio", "output", "speaker", "headphones", "sound", "volume"]
        let input = row(IDs.input, "Audio Input", currentDeviceSubtitle(.input), "mic.fill", color: .systemPurple)
        input.keywords = ["audio", "input", "microphone", "mic", "gain"]
        let count = settings.presetIDs().count
        let presets = row(IDs.presets, "Audio Presets",
                          count == 0 ? "Create your first input + output setup" : "\(count) saved setup\(count == 1 ? "" : "s") • → options",
                          "square.stack.3d.up.fill", color: .systemOrange)
        presets.keywords = ["audio", "presets", "profile", "setup"]
        for result in [output, input, presets] {
            result.dynamicChildrenIdentifier = result.itemIdentifier
            result.opensChildrenByDefault = true
            result.trailingHint = "Browse"
            result.commands = [visibilityCommand(itemID: result.itemIdentifier ?? "", context: context)]
        }
        return ordered([output, input, presets])
    }

    func launcherChildren(forItemIdentifier itemIdentifier: String, childrenIdentifier: String?,
                          context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        switch itemIdentifier {
        case IDs.setup:
            let help = row(IDs.help, "How to Use Audio Setup", "Keyboard shortcuts, sorting, locks, and safe volume editing", "questionmark.circle", color: .secondaryLabelColor)
            help.surfaceIdentifier = "audio-guide"
            help.trailingHint = "Guide"
            return ordered(sectionResults(context: context) + [help])
        case IDs.output: return deviceResults(direction: .output)
        case IDs.input: return deviceResults(direction: .input)
        case IDs.presets: return presetResults(context: context)
        default:
            if let slot = presetSlot(itemIdentifier), childrenIdentifier == IDs.presetControls {
                return presetControlResults(slot: slot, context: context)
            }
            if let parsed = parseDeviceIdentifier(itemIdentifier), childrenIdentifier == IDs.deviceControls {
                guard let device = audio.device(uid: parsed.uid, direction: parsed.direction) else {
                    return [row(itemIdentifier + ":missing", "Device Disconnected", "Reconnect the device, or go back to choose another.", "exclamationmark.triangle", color: .systemOrange)]
                }
                return deviceControlResults(device: device, direction: parsed.direction)
            }
            return nil
        }
    }

    func launcherSurface(forItemIdentifier itemIdentifier: String, surfaceIdentifier: String?,
                         context: BTTLauncherPluginContext) -> (any BTTLauncherPluginSurfaceInterface)? {
        if surfaceIdentifier == "audio-guide" { return AudioGuideSurface() }
        guard surfaceIdentifier == "volume-editor", let parsed = parseDeviceIdentifier(itemIdentifier) else { return nil }
        let key = "\(parsed.direction.rawValue):\(parsed.uid)"
        if let surface = volumeSurfaces[key] { return surface }
        let surface = AudioVolumeSurface(uid: parsed.uid, direction: parsed.direction, audio: audio, settings: settings)
        // Bound retained device editors without evicting the currently requested editor.
        if volumeSurfaces.count >= 24 { volumeSurfaces.removeAll() }
        volumeSurfaces[key] = surface
        return surface
    }

    func performAction(forItemIdentifier itemIdentifier: String, actionIdentifier: String?,
                       context: BTTLauncherPluginContext) -> BTTLauncherPluginActionResult? {
        let slot = presetSlot(itemIdentifier)
        let baseID = slot.map(presetID) ?? itemIdentifier
        if actionIdentifier == IDs.show || actionIdentifier == IDs.hide {
            guard [IDs.output, IDs.input, IDs.presets].contains(baseID) || slot.flatMap({ settings.combo(slot: $0) }) != nil else {
                return result(false, "This item no longer exists.")
            }
            let show = actionIdentifier == IDs.show
            settings.setShowsInMainLauncher(show, itemID: baseID, launcherID: context.launcherID)
            refresh()
            return result(true, show ? "Shown at top level in this launcher." : "Hidden from top level; still available inside Audio Setup.")
        }
        if itemIdentifier == IDs.newPreset { return createPreset() }
        if itemIdentifier == IDs.undo { return undoLastChange() }
        if let parsed = parseDeviceIdentifier(itemIdentifier), let actionIdentifier {
            return performDeviceAction(uid: parsed.uid, direction: parsed.direction, action: actionIdentifier)
        }
        if let slot {
            return performComboAction(slot: slot, action: actionIdentifier ?? IDs.switchDevice)
        }
        return nil
    }

    // Shared native visual language; color always has a matching text label or icon.
    private func row(_ id: String, _ title: String, _ subtitle: String, _ icon: String,
                     color: NSColor = .labelColor, action: String? = nil) -> BTTLauncherPluginResult {
        let r = BTTLauncherPluginResult()
        r.itemIdentifier = id
        r.title = title
        r.subtitle = subtitle
        r.systemImageName = icon
        r.iconImage = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        r.primaryActionIdentifier = action
        return r
    }
    private func ordered(_ rows: [BTTLauncherPluginResult]) -> [BTTLauncherPluginResult] {
        for (index, row) in rows.enumerated() { row.sortOrder = NSNumber(value: index) }
        return rows
    }
    private func command(_ id: String, _ title: String, _ subtitle: String, _ icon: String,
                         key: String? = nil, destructive: Bool = false) -> BTTLauncherPluginCommand {
        let c = BTTLauncherPluginCommand()
        c.commandIdentifier = id; c.title = title; c.subtitle = subtitle; c.systemImageName = icon
        c.closesLauncherOnSuccess = false; c.destructive = destructive
        if let key {
            let shortcut = BTTLauncherPluginShortcut()
            shortcut.character = key; shortcut.modifierFlags = .command
            shortcut.displayKeys = ["⌘", key.uppercased()]
            c.shortcut = shortcut
        }
        return c
    }
    private func visibilityCommand(itemID: String, context: BTTLauncherPluginContext) -> BTTLauncherPluginCommand {
        let shown = settings.showsInMainLauncher(itemID: itemID, launcherID: context.launcherID)
        return command(shown ? IDs.hide : IDs.show, shown ? "Hide from Top Level" : "Show at Top Level",
                       "Only changes this launcher's shortcuts—not audio routing", shown ? "pin.slash" : "pin")
    }

    // MARK: Device browsing
    private func deviceResults(direction: AudioDirection) -> [BTTLauncherPluginResult] {
        let current = audio.defaultDevice(direction: direction)?.uid
        let locked = settings.pinnedDeviceUID(direction: direction)
        let pins = settings.allPinnedVolumes(direction: direction)
        let devices = audio.devices(direction: direction).sorted {
            let l = AudioUX.deviceRank(active: $0.uid == current, locked: $0.uid == locked, volumePinned: pins[$0.uid] != nil, builtIn: $0.transportType == kAudioDeviceTransportTypeBuiltIn)
            let r = AudioUX.deviceRank(active: $1.uid == current, locked: $1.uid == locked, volumePinned: pins[$1.uid] != nil, builtIn: $1.transportType == kAudioDeviceTransportTypeBuiltIn)
            if l != r { return l < r }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.uid < $1.uid : comparison == .orderedAscending
        }
        if devices.isEmpty {
            return [row("audio.no-devices.\(direction.rawValue)", "No \(direction == .output ? "Output" : "Input") Devices", "Connect an audio device to get started.", "cable.connector", color: .systemOrange)]
        }
        return ordered(devices.map { device in
            var tags = [device.transportLabel]
            if device.uid == current { tags.insert("Active", at: 0) }
            if device.uid == locked { tags.append("Default locked") }
            if let volume = audio.volume(deviceID: device.id, direction: direction) {
                tags.append("\(Int((volume * 100).rounded()))%" + (pins[device.uid] == nil ? "" : " pinned"))
            } else { tags.append("Hardware volume") }
            if audio.isMuted(deviceID: device.id, direction: direction) == true { tags.append("Muted") }
            let r = row(deviceIdentifier(uid: device.uid, direction: direction), device.name, tags.joined(separator: " • "),
                        device.iconName(direction: direction), color: device.uid == current ? .systemGreen : (direction == .output ? .systemBlue : .systemPurple))
            r.keywords = [device.name, device.transportLabel, direction.rawValue, "audio", "device"]
            r.trailingHint = device.uid == current ? "Active · →" : "Controls →"
            r.dynamicChildrenIdentifier = IDs.deviceControls; r.opensChildrenByDefault = true
            return r
        })
    }
    private func deviceControlResults(device: AudioDevice, direction: AudioDirection) -> [BTTLauncherPluginResult] {
        let base = deviceIdentifier(uid: device.uid, direction: direction)
        let active = audio.defaultDevice(direction: direction)?.uid == device.uid
        let locked = settings.pinnedDeviceUID(direction: direction) == device.uid
        let pinned = settings.pinnedVolume(uid: device.uid, direction: direction)
        var rows = [row(base + ":switch", active ? "Currently Active" : "Switch to This Device", device.name,
                        active ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath", color: active ? .systemGreen : .systemBlue, action: IDs.switchDevice)]
        let supportsVolume = audio.canSetVolume(deviceID: device.id, direction: direction)
        let volume = audio.volume(deviceID: device.id, direction: direction)
        let volumeRow = row(base + ":volume", direction == .output ? "Output Volume" : "Microphone Gain",
                            supportsVolume ? "Current: \(Int(((volume ?? 0) * 100).rounded()))% • changes apply only when saved" : "Controlled by this device; software adjustment unavailable",
                            direction == .output ? "slider.horizontal.3" : "mic.badge.plus", color: supportsVolume ? .controlAccentColor : .secondaryLabelColor)
        if supportsVolume { volumeRow.surfaceIdentifier = "volume-editor"; volumeRow.trailingHint = "Adjust" }
        else { volumeRow.trailingHint = "Hardware" }
        rows.append(volumeRow)
        if audio.canMute(deviceID: device.id, direction: direction),
           let muted = audio.isMuted(deviceID: device.id, direction: direction) {
            rows.append(row(base + ":mute", muted ? "Unmute" : "Mute", device.name, muted ? "speaker.wave.2" : "speaker.slash",
                            color: muted ? .systemOrange : .labelColor, action: IDs.mute))
        }
        if supportsVolume || pinned != nil {
            rows.append(row(base + ":pin", pinned == nil ? "Pin Current Volume" : "Unpin Volume",
                            pinned.map { "Keep this device at \(Int(($0 * 100).rounded()))%" } ?? "Keep the current level when another app changes it",
                            pinned == nil ? "pin" : "pin.slash", color: .systemOrange, action: IDs.pinVolume))
        }
        rows.append(row(base + ":lock", locked ? "Unlock Default Device" : "Lock as Default Device",
                        locked ? "Allow macOS to choose another device" : "Restore this device when macOS switches away; manual switches pause the lock for 60 seconds",
                        locked ? "lock.open" : "lock", color: .systemPurple, action: IDs.lockDevice))
        return ordered(rows)
    }

    // MARK: Preset browsing
    private func presetID(_ slot: Int) -> String { IDs.comboPrefix + String(slot) }
    private func presetSlot(_ identifier: String) -> Int? {
        guard identifier.hasPrefix(IDs.comboPrefix) else { return nil }
        return identifier.dropFirst(IDs.comboPrefix.count).split(separator: ":").first.flatMap { Int($0) }
    }
    private func isActive(_ combo: AudioCombo) -> Bool {
        AudioUX.presetIsActive(combo, output: audio.defaultDevice(direction: .output)?.uid, input: audio.defaultDevice(direction: .input)?.uid)
    }
    private func sortedPresetIDs(context: BTTLauncherPluginContext) -> [Int] {
        let output = audio.defaultDevice(direction: .output)?.uid
        let input = audio.defaultDevice(direction: .input)?.uid
        return settings.presetIDs().sorted {
            guard let l = settings.combo(slot: $0), let r = settings.combo(slot: $1) else { return $0 < $1 }
            let lr = AudioUX.presetRank(visible: settings.showsInMainLauncher(itemID: presetID($0), launcherID: context.launcherID), active: AudioUX.presetIsActive(l, output: output, input: input))
            let rr = AudioUX.presetRank(visible: settings.showsInMainLauncher(itemID: presetID($1), launcherID: context.launcherID), active: AudioUX.presetIsActive(r, output: output, input: input))
            if lr != rr { return lr < rr }
            let comparison = l.name.localizedStandardCompare(r.name)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
    }
    private func presetResults(context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult] {
        var rows = sortedPresetIDs(context: context).map { comboResult(slot: $0, context: context) }
        rows.append(row(IDs.newPreset, "New Preset…", "Name and save the current output + input", "plus.circle.fill", color: .systemOrange, action: IDs.newPreset))
        if let undo = undoEntries.last {
            rows.append(row(IDs.undo, "Undo \(undo.label)", "Restore the previous saved configuration; does not switch audio", "arrow.uturn.backward", action: IDs.undo))
        }
        return ordered(rows)
    }
    private func comboResult(slot: Int, context: BTTLauncherPluginContext) -> BTTLauncherPluginResult {
        guard let combo = settings.combo(slot: slot) else {
            return row(presetID(slot), "Unavailable Preset", "Saved data could not be read", "exclamationmark.triangle", color: .systemOrange)
        }
        let active = isActive(combo)
        let shown = settings.showsInMainLauncher(itemID: presetID(slot), launcherID: context.launcherID)
        let r = row(presetID(slot), combo.name, comboSubtitle(combo),
                    active ? "checkmark.circle.fill" : "square.stack.3d.up", color: active ? .systemGreen : .systemOrange, action: IDs.switchDevice)
        r.keywords = ["audio", "preset", "profile", "setup", combo.name]
        r.trailingHint = (active ? "Active" : "↩ Switch") + (shown ? " · Pinned" : "") + " · →"
        r.dynamicChildrenIdentifier = IDs.presetControls
        r.opensChildrenByDefault = false // Enter switches; Right Arrow opens management.
        r.commands = [
            command(IDs.switchDevice, "Switch to Preset", comboSubtitle(combo), "arrow.triangle.2.circlepath"),
            command(IDs.rename, "Rename Preset…", "Change the name without changing saved devices", "pencil", key: "r"),
            visibilityCommand(itemID: presetID(slot), context: context),
            command(IDs.duplicate, "Duplicate Preset", "Create an independent copy", "plus.square.on.square", key: "d"),
            command(IDs.update, "Update from Current Devices…", "Review before replacing the saved devices", "arrow.clockwise"),
            command(IDs.delete, "Delete Preset…", "Confirmation required; Undo is available", "trash", destructive: true)
        ]
        return r
    }
    private func presetControlResults(slot: Int, context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult] {
        guard let combo = settings.combo(slot: slot) else { return [] }
        let base = presetID(slot)
        let visible = settings.showsInMainLauncher(itemID: base, launcherID: context.launcherID)
        return ordered([
            row(base + ":switch", isActive(combo) ? "Reapply Preset" : "Switch to Preset", comboSubtitle(combo), "arrow.triangle.2.circlepath", color: .systemBlue, action: IDs.switchDevice),
            row(base + ":rename", "Rename Preset…", combo.name, "pencil", action: IDs.rename),
            row(base + ":visibility", visible ? "Hide from Top Level" : "Show at Top Level", "Launcher shortcut only—not an audio lock", visible ? "pin.slash" : "pin", color: .systemOrange, action: visible ? IDs.hide : IDs.show),
            row(base + ":duplicate", "Duplicate Preset", "Create a separate copy of \(combo.name)", "plus.square.on.square", action: IDs.duplicate),
            row(base + ":update", "Update from Current Devices…", "Review the new output + input before replacing this setup", "arrow.clockwise", action: IDs.update),
            row(base + ":delete", "Delete Preset…", "Confirmation required • reversible with Undo", "trash", color: .systemRed, action: IDs.delete)
        ])
    }
    private func comboSubtitle(_ combo: AudioCombo) -> String {
        func name(_ uid: String?, _ direction: AudioDirection) -> String {
            guard let uid else { return "Unchanged" }
            return audio.device(uid: uid, direction: direction)?.name ?? "Disconnected"
        }
        return "Out: \(name(combo.outputUID, .output)) • In: \(name(combo.inputUID, .input))"
    }

    // MARK: Safe actions
    private func performDeviceAction(uid: String, direction: AudioDirection, action: String) -> BTTLauncherPluginActionResult {
        guard let device = audio.device(uid: uid, direction: direction) else { return result(false, "Device disconnected. Reconnect it and try again.") }
        switch action {
        case IDs.switchDevice:
            if audio.defaultDevice(direction: direction)?.uid == uid {
                return result(true, "\(device.name) is already active. No settings changed.")
            }
            let ok = audio.setDefaultDevice(device.id, direction: direction)
            if ok { settings.setGracePeriod(seconds: 60, direction: direction) }
            refresh()
            return result(ok, ok ? "Using \(device.name). Device lock paused for 60 seconds." : "Could not switch to \(device.name).")
        case IDs.mute:
            guard audio.canMute(deviceID: device.id, direction: direction),
                  let muted = audio.isMuted(deviceID: device.id, direction: direction) else { return result(false, "This device does not support software mute.") }
            let ok = audio.setMuted(!muted, deviceID: device.id, direction: direction)
            refresh()
            return result(ok, ok ? (muted ? "Unmuted \(device.name)." : "Muted \(device.name).") : "Could not update every mute channel.")
        case IDs.lockDevice:
            if settings.pinnedDeviceUID(direction: direction) == uid {
                settings.setPinnedDeviceUID(nil, direction: direction); refresh()
                return result(true, "Default-device lock removed.")
            }
            guard audio.setDefaultDevice(device.id, direction: direction) else { return result(false, "Could not activate this device; no lock was saved.") }
            settings.setGracePeriod(seconds: -1, direction: direction)
            settings.setPinnedDeviceUID(uid, direction: direction); refresh()
            return result(true, "Locked \(device.name) as the default \(direction.rawValue).")
        case IDs.pinVolume:
            if settings.pinnedVolume(uid: uid, direction: direction) != nil {
                settings.setPinnedVolume(nil, uid: uid, direction: direction); refresh()
                return result(true, "Volume unpinned.")
            }
            guard audio.canSetVolume(deviceID: device.id, direction: direction),
                  let value = audio.volume(deviceID: device.id, direction: direction) else { return result(false, "Software volume is unavailable.") }
            settings.setPinnedVolume(value, uid: uid, direction: direction); refresh()
            return result(true, "Pinned at \(Int((value * 100).rounded()))%.")
        default: return result(false, "Choose a supported device control.")
        }
    }
    private func performComboAction(slot: Int, action: String) -> BTTLauncherPluginActionResult {
        guard let combo = settings.combo(slot: slot) else { return result(false, "This preset no longer exists.") }
        switch action {
        case IDs.rename:
            return scheduleDialog { [self] in presentNameDialog(slot: slot) }
        case IDs.update:
            return scheduleDialog { [self] in confirmUpdate(slot: slot) }
        case IDs.delete:
            return scheduleDialog { [self] in confirmDelete(slot: slot) }
        case IDs.duplicate:
            let name = uniqueName(String(combo.name.prefix(74)) + " Copy")
            let id = settings.nextPresetID()
            saveChange(AudioCombo(name: name, outputUID: combo.outputUID, inputUID: combo.inputUID), slot: id, label: "Duplicate Preset")
            return result(true, "Created “\(name)”.")
        case IDs.switchDevice:
            var succeeded: [String] = []
            var failed: [String] = []
            for (direction, uid) in [(AudioDirection.output, combo.outputUID), (.input, combo.inputUID)] {
                guard let uid else { continue }
                guard let device = audio.device(uid: uid, direction: direction) else { failed.append("\(direction.rawValue) disconnected"); continue }
                if audio.setDefaultDevice(device.id, direction: direction) {
                    succeeded.append(direction.rawValue)
                    settings.setGracePeriod(seconds: 60, direction: direction)
                } else { failed.append("\(direction.rawValue) switch failed") }
            }
            refresh()
            let outcome = AudioUX.switchOutcome(name: combo.name, succeeded: succeeded, failed: failed)
            return result(outcome.success, outcome.message)
        default: return result(false, "Unsupported preset action.")
        }
    }
    private func createPreset() -> BTTLauncherPluginActionResult {
        scheduleDialog { [self] in presentNameDialog(slot: nil) }
    }
    private func scheduleDialog(_ body: @escaping () -> Void) -> BTTLauncherPluginActionResult {
        guard !dialogIsOpen else { return result(false, "Finish the current dialog first.") }
        dialogIsOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            defer { dialogIsOpen = false }
            body()
        }
        return result(true, "Opening dialog…")
    }
    private func uniqueName(_ proposed: String) -> String {
        let names = settings.presetIDs().compactMap { settings.combo(slot: $0)?.name.lowercased() }
        var candidate = String(proposed.prefix(80)); var index = 2
        while names.contains(candidate.lowercased()) {
            let suffix = " \(index)"
            candidate = String(proposed.prefix(max(1, 80 - suffix.count))) + suffix
            index += 1
        }
        return candidate
    }
    private func presentNameDialog(slot: Int?) {
        let existing = slot.flatMap { settings.combo(slot: $0) }
        if slot != nil && existing == nil {
            showNotice("Preset Unavailable", "This preset was removed before the editor opened.")
            return
        }
        let capturedOutput = audio.defaultDevice(direction: .output)
        let capturedInput = audio.defaultDevice(direction: .input)
        if slot == nil && capturedOutput == nil && capturedInput == nil {
            showNotice("No Audio Devices", "Connect an input or output device before creating a preset.")
            return
        }
        let alert = NSAlert()
        alert.messageText = slot == nil ? "New Audio Preset" : "Rename Audio Preset"
        let description = slot == nil
            ? "Save output: \(capturedOutput?.name ?? "Unchanged")\nInput: \(capturedInput?.name ?? "Unchanged")"
            : "Only the name changes. Your saved devices stay unchanged."
        alert.informativeText = description
        alert.addButton(withTitle: slot == nil ? "Create Preset" : "Save Name")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: existing?.name ?? uniqueName("Audio Preset"))
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        field.placeholderString = "For example: Studio or Meeting"
        field.setAccessibilityLabel("Preset name")
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        let opened = Date()
        // A held opening Return must not immediately save the newly opened dialog.
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.window === alert.window, [UInt16(36), UInt16(76)].contains(event.keyCode),
               event.isARepeat || Date().timeIntervalSince(opened) < 0.35 { return nil }
            return event
        }
        defer { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let names = settings.presetIDs().filter { $0 != slot }.compactMap { settings.combo(slot: $0)?.name }
            if let issue = AudioUX.nameIssue(name, existingNames: names) {
                alert.informativeText = issue + "\n\n" + description
                continue
            }
            if let slot {
                guard let latest = settings.combo(slot: slot) else { return }
                saveChange(AudioCombo(name: name, outputUID: latest.outputUID, inputUID: latest.inputUID), slot: slot, label: "Rename Preset")
            } else {
                saveChange(AudioCombo(name: name, outputUID: capturedOutput?.uid, inputUID: capturedInput?.uid),
                           slot: settings.nextPresetID(), label: "Create Preset")
            }
            return
        }
    }
    private func confirmUpdate(slot: Int) {
        guard let old = settings.combo(slot: slot) else { return }
        let output = audio.defaultDevice(direction: .output)
        let input = audio.defaultDevice(direction: .input)
        guard output != nil || input != nil else {
            showNotice("No Audio Devices", "Connect an input or output device before updating this preset.")
            return
        }
        let replacement = AudioCombo(name: old.name, outputUID: output?.uid, inputUID: input?.uid)
        let alert = NSAlert()
        alert.messageText = "Update “\(old.name)”?"
        alert.informativeText = "Saved:\n\(comboSubtitle(old))\n\nReplace with:\n\(comboSubtitle(replacement))\n\nThe name stays unchanged. Undo will be available."
        alert.addButton(withTitle: "Update Preset"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, settings.combo(slot: slot) == old {
            saveChange(replacement, slot: slot, label: "Update Preset")
        }
    }
    private func confirmDelete(slot: Int) {
        guard let old = settings.combo(slot: slot) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete “\(old.name)”?"
        alert.informativeText = "The preset and its launcher shortcuts will be removed. Your audio devices will not change. Undo will be available."
        alert.addButton(withTitle: "Delete Preset"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, settings.combo(slot: slot) == old {
            saveChange(nil, slot: slot, label: "Delete Preset")
        }
    }
    private func showNotice(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    private func saveChange(_ combo: AudioCombo?, slot: Int, label: String) {
        let before = settings.snapshot(slot: slot)
        guard before.combo != combo else { return }
        settings.setCombo(combo, slot: slot)
        undoEntries.append(UndoEntry(slot: slot, before: before, after: combo, label: label))
        if undoEntries.count > 10 { undoEntries.removeFirst() }
        refresh()
    }
    private func undoLastChange() -> BTTLauncherPluginActionResult {
        guard let entry = undoEntries.last else { return result(false, "Nothing to undo.") }
        guard settings.combo(slot: entry.slot) == entry.after else {
            undoEntries.removeLast(); refresh()
            return result(false, "This preset changed elsewhere. Undo was skipped to protect newer changes.")
        }
        if entry.before.combo != nil && entry.after != nil {
            // Undo a rename/update without undoing a later visibility preference.
            settings.setCombo(entry.before.combo, slot: entry.slot)
        } else {
            settings.restore(entry.before, slot: entry.slot)
        }
        undoEntries.removeLast(); refresh()
        return result(true, "Undid \(entry.label.lowercased()). Audio routing was not changed.")
    }
    private func result(_ success: Bool, _ message: String) -> BTTLauncherPluginActionResult {
        let r = BTTLauncherPluginActionResult()
        r.success = success; r.message = message; r.closeLauncher = false
        return r
    }
    private func refresh() { delegate?.requestLauncherResultsRefresh() }
    private func currentDeviceSubtitle(_ direction: AudioDirection) -> String {
        guard let device = audio.defaultDevice(direction: direction) else { return "No active device • connect one to get started" }
        return device.name + (settings.pinnedDeviceUID(direction: direction) == device.uid ? " • Default locked" : "")
    }
    private func deviceIdentifier(uid: String, direction: AudioDirection) -> String {
        let encoded = Data(uid.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "device:\(direction.rawValue):\(encoded)"
    }
    private func parseDeviceIdentifier(_ identifier: String) -> (direction: AudioDirection, uid: String)? {
        let pieces = identifier.split(separator: ":").map(String.init)
        guard pieces.count >= 3, pieces[0] == "device", let direction = AudioDirection(rawValue: pieces[1]) else { return nil }
        var encoded = pieces[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded), let uid = String(data: data, encoding: .utf8), !uid.isEmpty else { return nil }
        return (direction, uid)
    }
}

// MARK: - Exact volume surface

private final class AudioVolumeSurface: NSObject, BTTLauncherPluginSurfaceInterface, NSTextFieldDelegate {
    weak var delegate: (any BTTLauncherPluginSurfaceDelegate)?
    private let uid: String
    private let direction: AudioDirection
    private let audio: AudioDeviceController
    private let settings: AudioDeviceSettings
    private let nameLabel = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "Changes are applied only when you choose Apply.")
    private let slider = NSSlider(value: 50, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueField = NSTextField(string: "50")
    private let pinButton = NSButton(checkboxWithTitle: "Keep this volume pinned", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply Volume", target: nil, action: nil)
    private var dirty = false
    private var appearedAt = Date.distantPast
    private var observer: NSObjectProtocol?
    private lazy var rootView = buildView()

    init(uid: String, direction: AudioDirection, audio: AudioDeviceController, settings: AudioDeviceSettings) {
        self.uid = uid; self.direction = direction; self.audio = audio; self.settings = settings
        super.init()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func makeLauncherSurfaceView() -> NSView { rootView }
    func launcherSurfaceDidAppear() {
        appearedAt = Date()
        dirty = false
        messageLabel.stringValue = "Adjust the value, then Apply. Nothing changes while you edit."
        messageLabel.textColor = .secondaryLabelColor
        refresh(resetDraft: true)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: .audioSetupDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh(resetDraft: false)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.valueField.window?.makeFirstResponder(self.valueField)
            self.valueField.selectText(nil)
        }
    }
    func launcherSurfaceWillDisappear() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        dirty = false
    }
    func launcherSurfacePlaceholderText() -> String? { direction == .output ? "Output volume" : "Microphone gain" }
    func launcherSurfaceFooterHint() -> String? { "↩ Apply • ⌘A select value • Esc back without applying" }
    func launcherSurfaceStatusText() -> String? { dirty ? "Unsaved changes" : "Audio Setup · exact control" }
    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 560, height: 330) }
    func launcherSurfaceMinimumContentSize() -> CGSize { CGSize(width: 460, height: 330) }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { true }
    func launcherSurfaceShouldBypassGlobalKeyboardHandling(for event: NSEvent) -> Bool {
        event.type != .keyDown || event.keyCode != 53
    }
    func handleLauncherInputCommand(_ command: BTTLauncherPluginInputCommand) -> BTTLauncherPluginSurfaceCommandResult? {
        guard command == .activateSelection else { return nil }
        if Date().timeIntervalSince(appearedAt) > 0.3 { applyVolume() }
        let r = BTTLauncherPluginSurfaceCommandResult()
        r.handled = true; r.closeLauncher = false; r.goBack = false
        return r
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === valueField else { return }
        dirty = true
        if let percent = AudioUX.percentage(valueField.stringValue) {
            slider.doubleValue = percent
            showMessage("Ready to apply \(AudioUX.formatPercent(percent))%.", error: false)
        } else { showMessage("Enter a number from 0 to 100. Decimals are allowed.", error: true) }
        updateAvailability()
        delegate?.requestLauncherSurfaceUpdate()
    }
    private func buildView() -> NSView {
        let root = NSView()
        let icon = NSImageView(image: NSImage(systemSymbolName: direction == .output ? "speaker.wave.2.circle.fill" : "mic.circle.fill", accessibilityDescription: direction == .output ? "Output volume" : "Microphone gain") ?? NSImage())
        icon.contentTintColor = direction == .output ? .systemBlue : .systemPurple
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        nameLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        currentLabel.font = .systemFont(ofSize: 12)
        currentLabel.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [nameLabel, currentLabel])
        titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 4
        let header = NSStackView(views: [icon, titles]); header.spacing = 12; header.alignment = .centerY
        valueField.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        valueField.alignment = .right
        valueField.delegate = self; valueField.target = self; valueField.action = #selector(returnPressed(_:))
        valueField.setAccessibilityLabel(direction == .output ? "Output volume percentage" : "Microphone gain percentage")
        valueField.widthAnchor.constraint(equalToConstant: 78).isActive = true
        slider.target = self; slider.action = #selector(sliderChanged(_:)); slider.isContinuous = true
        slider.setAccessibilityLabel("Draft percentage; apply to save")
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let percent = NSTextField(labelWithString: "%")
        percent.font = .systemFont(ofSize: 16); percent.textColor = .secondaryLabelColor
        let values = NSStackView(views: [slider, valueField, percent]); values.spacing = 10
        let quick = NSStackView(); quick.spacing = 8
        for (title, tag) in [("−5", -5), ("25%", 25), ("50%", 50), ("75%", 75), ("+5", -6)] {
            let button = NSButton(title: title, target: self, action: #selector(quickValue(_:)))
            button.bezelStyle = .rounded; button.tag = tag
            button.setAccessibilityLabel(tag < 0 ? (tag == -5 ? "Decrease draft by five percent" : "Increase draft by five percent") : "Set draft to \(tag) percent")
            quick.addArrangedSubview(button)
        }
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetDraft(_:)))
        reset.bezelStyle = .rounded
        reset.toolTip = "Discard the draft and reload the device's current volume"
        quick.addArrangedSubview(reset)
        pinButton.target = self; pinButton.action = #selector(pinChanged(_:))
        pinButton.toolTip = "Saved only when you apply; restores this level if another app changes it"
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        applyButton.bezelStyle = .rounded
        applyButton.target = self; applyButton.action = #selector(applyPressed(_:))
        let footer = NSStackView(views: [pinButton, NSView(), applyButton]); footer.spacing = 12
        let stack = NSStackView(views: [header, values, quick, messageLabel, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for view in [header, values, quick, messageLabel, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)
        ])
        return root
    }
    private func refresh(resetDraft: Bool) {
        // Always resolve the persistent UID again: Core Audio device IDs can change on reconnect.
        guard let device = audio.device(uid: uid, direction: direction) else {
            nameLabel.stringValue = "Device Disconnected"
            currentLabel.stringValue = "Reconnect it to continue; your draft is kept."
            applyButton.isEnabled = false; slider.isEnabled = false; pinButton.isEnabled = false
            return
        }
        nameLabel.stringValue = device.name
        let supported = audio.canSetVolume(deviceID: device.id, direction: direction)
        let current = audio.volume(deviceID: device.id, direction: direction)
        currentLabel.stringValue = current.map { "Current: \(AudioUX.formatPercent(Double($0) * 100))% · \(direction == .output ? "Output volume" : "Microphone gain")" } ?? "Volume controlled by this device"
        slider.isEnabled = supported; pinButton.isEnabled = supported
        if resetDraft || !dirty {
            if let current {
                slider.doubleValue = Double(current) * 100
                valueField.stringValue = AudioUX.formatPercent(Double(current) * 100)
            }
            pinButton.state = settings.pinnedVolume(uid: uid, direction: direction) == nil ? .off : .on
        }
        updateAvailability()
    }
    private func updateAvailability() {
        let device = audio.device(uid: uid, direction: direction)
        applyButton.isEnabled = AudioUX.percentage(valueField.stringValue) != nil &&
            device.map { audio.canSetVolume(deviceID: $0.id, direction: direction) } == true
    }
    private func showMessage(_ message: String, error: Bool) {
        messageLabel.stringValue = message
        messageLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }
    @objc private func sliderChanged(_ sender: NSSlider) {
        valueField.stringValue = AudioUX.formatPercent(sender.doubleValue)
        dirty = true; updateAvailability()
        showMessage("Draft only • choose Apply to save.", error: false)
        delegate?.requestLauncherSurfaceUpdate()
    }
    @objc private func quickValue(_ sender: NSButton) {
        let current = AudioUX.percentage(valueField.stringValue) ?? slider.doubleValue
        slider.doubleValue = sender.tag == -5 ? max(0, current - 5) : sender.tag == -6 ? min(100, current + 5) : Double(sender.tag)
        sliderChanged(slider)
    }
    @objc private func resetDraft(_ sender: NSButton) {
        dirty = false; refresh(resetDraft: true)
        showMessage("Draft reset. No audio settings changed.", error: false)
        delegate?.requestLauncherSurfaceUpdate()
    }
    @objc private func pinChanged(_ sender: NSButton) {
        dirty = true
        showMessage(sender.state == .on ? "Apply to save the level and pin it." : "Apply to save the level and remove its pin.", error: false)
        delegate?.requestLauncherSurfaceUpdate()
    }
    @objc private func returnPressed(_ sender: NSTextField) {
        if Date().timeIntervalSince(appearedAt) > 0.3 { applyVolume() }
    }
    @objc private func applyPressed(_ sender: NSButton) { applyVolume() }
    private func applyVolume() {
        guard let percent = AudioUX.percentage(valueField.stringValue) else {
            showMessage("Enter a number from 0 to 100. Nothing was applied.", error: true); return
        }
        guard let device = audio.device(uid: uid, direction: direction) else {
            showMessage("Device disconnected. Reconnect it and try again.", error: true); refresh(resetDraft: false); return
        }
        let value = Float(percent / 100)
        guard audio.setVolume(value, deviceID: device.id, direction: direction) else {
            showMessage("Could not update every volume channel. Check the device and try again.", error: true)
            refresh(resetDraft: false); return
        }
        settings.setPinnedVolume(pinButton.state == .on ? value : nil, uid: uid, direction: direction)
        dirty = false; refresh(resetDraft: true)
        showMessage("Saved \(AudioUX.formatPercent(percent))%" + (pinButton.state == .on ? " · volume pinned." : "."), error: false)
        delegate?.requestLauncherResultsRefresh()
        delegate?.requestLauncherSurfaceUpdate()
    }
}

// MARK: - Built-in guide

private final class AudioGuideSurface: NSObject, BTTLauncherPluginSurfaceInterface {
    func launcherSurfacePreferredContentSize() -> CGSize { CGSize(width: 580, height: 520) }
    func launcherSurfaceMinimumContentSize() -> CGSize { CGSize(width: 460, height: 520) }
    func launcherSurfaceFooterHint() -> String? { "← or Esc back • Audio Setup" }
    func launcherSurfaceKeepsLauncherPinned() -> Bool { true }
    func makeLauncherSurfaceView() -> NSView {
        let title = NSTextField(labelWithString: "Your Audio Control Room")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let stack = NSStackView(views: [title])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        for (icon, heading, detail) in [
            ("keyboard", "Fast navigation", "Enter switches a preset. Right Arrow opens its options. Rename: ⌘R. Duplicate: ⌘D."),
            ("line.3.horizontal.decrease", "Useful things first", "Devices: active, locked, volume-pinned, then built-in. Presets: top-level shortcuts, active setups, then name."),
            ("pin", "Shortcuts are not locks", "Show at Top Level adds a shortcut in this launcher. Device locks and volume pins change audio behavior."),
            ("slider.horizontal.3", "Safe volume editing", "Typing, quick values, and the slider only edit a draft. Apply saves both volume and pin state. Reset discards the draft."),
            ("lock", "Default-device locks", "Audio changes are monitored. A manual switch pauses its device lock for 60 seconds. Volume pins continue independently."),
            ("arrow.uturn.backward", "Reversible presets", "Create, rename, duplicate, update, and delete can be undone in Audio Presets. Up to 10 changes are kept for this plugin session.")
        ] {
            let symbol = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil) ?? NSImage())
            symbol.contentTintColor = .controlAccentColor
            symbol.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let label = NSTextField(wrappingLabelWithString: detail)
            label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
            let headingLabel = NSTextField(labelWithString: heading)
            headingLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            let text = NSStackView(views: [headingLabel, label]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 3
            let row = NSStackView(views: [symbol, text]); row.alignment = .top; row.spacing = 12
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let root = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18)
        ])
        return root
    }
}

// MARK: - Models and persistence

private enum AudioDirection: String, Codable {
    case output
    case input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }
}

private struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32

    var transportLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Display"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        default: return "Audio"
        }
    }

    func iconName(direction: AudioDirection) -> String {
        if direction == .input { return transportType == kAudioDeviceTransportTypeBuiltIn ? "mic.fill" : "waveform.badge.mic" }
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeBuiltIn: return "speaker.wave.2.fill"
        default: return "speaker.wave.2.fill"
        }
    }

    func isMuted(direction: AudioDirection, audio: AudioDeviceController) -> Bool {
        audio.isMuted(deviceID: id, direction: direction) ?? false
    }
}

private struct AudioCombo: Codable, Equatable {
    let name: String
    let outputUID: String?
    let inputUID: String?
}

private final class AudioDeviceSettings {
    static let shared = AudioDeviceSettings()
    private let store = UserDefaults(suiteName: "com.loaysax.btt.set-audio-device") ?? .standard
    private let lock = NSLock()

    private init() {}

    func showsInMainLauncher(itemID: String, launcherID: String?) -> Bool {
        let scope = Data((launcherID ?? "default").utf8).base64EncodedString()
        return store.bool(forKey: "mainLauncher.\(scope).\(itemID)")
    }

    func setShowsInMainLauncher(_ show: Bool, itemID: String, launcherID: String?) {
        let scope = Data((launcherID ?? "default").utf8).base64EncodedString()
        store.set(show, forKey: "mainLauncher.\(scope).\(itemID)")
    }

    func pinnedDeviceUID(direction: AudioDirection) -> String? {
        store.string(forKey: "pinnedDevice.\(direction.rawValue)")
    }

    func setPinnedDeviceUID(_ uid: String?, direction: AudioDirection) {
        if let uid { store.set(uid, forKey: "pinnedDevice.\(direction.rawValue)") }
        else { store.removeObject(forKey: "pinnedDevice.\(direction.rawValue)") }
    }

    func pinnedVolume(uid: String, direction: AudioDirection) -> Float? {
        lock.lock(); defer { lock.unlock() }
        let values = store.dictionary(forKey: "pinnedVolumes.\(direction.rawValue)") as? [String: NSNumber] ?? [:]
        guard let value = values[uid]?.floatValue, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    func setPinnedVolume(_ volume: Float?, uid: String, direction: AudioDirection) {
        lock.lock(); defer { lock.unlock() }
        let key = "pinnedVolumes.\(direction.rawValue)"
        var values = store.dictionary(forKey: key) as? [String: NSNumber] ?? [:]
        if let volume, volume.isFinite { values[uid] = NSNumber(value: min(max(volume, 0), 1)) }
        else { values.removeValue(forKey: uid) }
        store.set(values, forKey: key)
    }

    func allPinnedVolumes(direction: AudioDirection) -> [String: Float] {
        lock.lock(); defer { lock.unlock() }
        let values = store.dictionary(forKey: "pinnedVolumes.\(direction.rawValue)") as? [String: NSNumber] ?? [:]
        return values.compactMapValues { number in
            let value = number.floatValue
            return value.isFinite ? min(max(value, 0), 1) : nil
        }
    }

    func setGracePeriod(seconds: TimeInterval, direction: AudioDirection) {
        store.set(Date().addingTimeInterval(seconds).timeIntervalSince1970, forKey: "graceUntil.\(direction.rawValue)")
    }

    func isInGracePeriod(direction: AudioDirection) -> Bool {
        Date().timeIntervalSince1970 < store.double(forKey: "graceUntil.\(direction.rawValue)")
    }

    func combo(slot: Int) -> AudioCombo? {
        guard let data = store.data(forKey: "combo.\(slot)") else { return nil }
        return try? JSONDecoder().decode(AudioCombo.self, from: data)
    }

    func presetIDs() -> [Int] {
        if let stored = store.array(forKey: "presetIDs") as? [NSNumber] {
            return Array(Set(stored.map(\.intValue))).sorted()
        }

        // One-time migration: preserve configured presets from older versions,
        // but discard the old empty placeholder slots 1, 2 and 3.
        let legacyMaximum = max(3, store.integer(forKey: "presetCount"))
        let migrated = (1...legacyMaximum).filter { store.data(forKey: "combo.\($0)") != nil }
        store.set(migrated, forKey: "presetIDs")
        return migrated
    }

    func nextPresetID() -> Int {
        max(store.integer(forKey: "lastPresetID"), presetIDs().max() ?? 0) + 1
    }

    func setCombo(_ combo: AudioCombo?, slot: Int) {
        guard let combo else { deletePreset(slot: slot); return }
        guard let data = try? JSONEncoder().encode(combo) else { return }
        store.set(data, forKey: "combo.\(slot)")
        var ids = presetIDs()
        if !ids.contains(slot) { ids.append(slot); store.set(ids.sorted(), forKey: "presetIDs") }
        store.set(max(slot, store.integer(forKey: "lastPresetID")), forKey: "lastPresetID")
    }

    private func visibilityKeys(slot: Int) -> [String] {
        store.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("mainLauncher.") && $0.hasSuffix(".audio.combo.\(slot)")
        }
    }

    func snapshot(slot: Int) -> PresetSnapshot {
        PresetSnapshot(combo: combo(slot: slot),
                       visibility: Dictionary(uniqueKeysWithValues: visibilityKeys(slot: slot).map { ($0, store.bool(forKey: $0)) }))
    }

    func restore(_ snapshot: PresetSnapshot, slot: Int) {
        for key in visibilityKeys(slot: slot) { store.removeObject(forKey: key) }
        setCombo(snapshot.combo, slot: slot)
        for (key, value) in snapshot.visibility { store.set(value, forKey: key) }
    }

    func deletePreset(slot: Int) {
        // Keep the high-water mark so a deleted preset's identity is never recycled.
        store.set(max(slot, max(store.integer(forKey: "lastPresetID"), presetIDs().max() ?? 0)), forKey: "lastPresetID")
        store.removeObject(forKey: "combo.\(slot)")
        store.set(presetIDs().filter { $0 != slot }, forKey: "presetIDs")
        for key in visibilityKeys(slot: slot) { store.removeObject(forKey: key) }
    }
}

// MARK: - Shared, testable presentation rules

private struct PresetSnapshot {
    let combo: AudioCombo?
    let visibility: [String: Bool]
}

private enum AudioUX {
    static func percentage(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("%") { value.removeLast(); value = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard value.range(of: #"^(?:[0-9]+(?:[.,][0-9]*)?|[.,][0-9]+)$"#, options: .regularExpression) != nil,
              let number = Double(value.replacingOccurrences(of: ",", with: ".")),
              number.isFinite, (0...100).contains(number) else { return nil }
        return number
    }
    static func formatPercent(_ number: Double) -> String {
        let text = String(format: "%.1f", number)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
    static func nameIssue(_ name: String, existingNames: [String]) -> String? {
        guard !name.isEmpty else { return "Enter a name for this preset." }
        guard name.count <= 80 else { return "Use a name of 80 characters or fewer." }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else { return "Use a single-line name without control characters." }
        guard !existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return "Another preset already uses that name." }
        return nil
    }
    static func deviceRank(active: Bool, locked: Bool, volumePinned: Bool, builtIn: Bool) -> Int {
        active ? 0 : locked ? 1 : volumePinned ? 2 : builtIn ? 3 : 4
    }
    static func presetRank(visible: Bool, active: Bool) -> Int { visible ? (active ? 0 : 1) : active ? 2 : 3 }
    static func presetIsActive(_ combo: AudioCombo, output: String?, input: String?) -> Bool {
        guard combo.outputUID != nil || combo.inputUID != nil else { return false }
        return (combo.outputUID == nil || combo.outputUID == output) && (combo.inputUID == nil || combo.inputUID == input)
    }
    static func switchOutcome(name: String, succeeded: [String], failed: [String]) -> (success: Bool, message: String) {
        if !failed.isEmpty {
            let prefix = succeeded.isEmpty ? "Could not apply “\(name)”" : "Partially applied “\(name)” (\(succeeded.joined(separator: " + ")) switched)"
            return (false, prefix + ": " + failed.joined(separator: "; ") + ".")
        }
        guard !succeeded.isEmpty else { return (false, "This preset has no saved devices. Update it from the current devices.") }
        return (true, "Applied “\(name)”.")
    }
}

// MARK: - Live changes and lock enforcement

private extension Notification.Name {
    static let audioSetupDidChange = Notification.Name("com.loaysax.btt.audio.hardware-change")
}
private struct AudioObservation {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress
}
private final class AudioChangeMonitor {
    static let shared = AudioChangeMonitor()
    private var observations: [AudioObservation] = []
    private var started = false
    private var pending: DispatchWorkItem?
    private var needsRebuild = false
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        let rebuild = (0..<Int(count)).contains { addresses[$0].mSelector == kAudioHardwarePropertyDevices }
        self?.schedule(rebuild: rebuild)
    }
    private init() {}
    func start() {
        guard !started else { return }
        started = true
        rebuild()
    }
    deinit {
        pending?.cancel()
        removeListeners()
    }
    private func removeListeners() {
        for var item in observations {
            AudioObjectRemovePropertyListenerBlock(item.object, &item.address, .main, listener)
        }
        observations.removeAll()
    }
    private func rebuild() {
        removeListeners()
        var addresses = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice].map {
            AudioObservation(object: AudioObjectID(kAudioObjectSystemObject),
                             address: AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain))
        }
        addresses += AudioDeviceController.shared.observationAddresses()
        for var item in addresses {
            if AudioObjectAddPropertyListenerBlock(item.object, &item.address, .main, listener) == noErr {
                observations.append(item)
            }
        }
    }
    private func schedule(rebuild: Bool) {
        needsRebuild = needsRebuild || rebuild
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.needsRebuild { self.needsRebuild = false; self.rebuild() }
            NotificationCenter.default.post(name: .audioSetupDidChange, object: nil)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
private final class AudioDeviceEnforcer {
    static let shared = AudioDeviceEnforcer()
    private let audio = AudioDeviceController.shared
    private let settings = AudioDeviceSettings.shared
    private let queue = DispatchQueue(label: "com.loaysax.btt.set-audio-device.enforcer", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var lastAttempt: [String: Date] = [:]
    private init() {}
    func start() {
        guard !started else { return }
        started = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 30, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in self?.enforce() }
        timer.resume(); self.timer = timer
        observers.append(NotificationCenter.default.addObserver(forName: .audioSetupDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.enforce() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.enforce() }
        })
    }
    deinit {
        timer?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
    private func canAttempt(_ key: String) -> Bool {
        guard Date().timeIntervalSince(lastAttempt[key] ?? .distantPast) >= 2 else { return false }
        lastAttempt[key] = Date()
        return true
    }
    private func enforce() {
        for direction in [AudioDirection.output, .input] {
            if !settings.isInGracePeriod(direction: direction),
               let uid = settings.pinnedDeviceUID(direction: direction),
               let desired = audio.device(uid: uid, direction: direction),
               audio.defaultDevice(direction: direction)?.uid != uid,
               canAttempt("device.\(direction.rawValue)") {
                _ = audio.setDefaultDevice(desired.id, direction: direction)
            }
            for (uid, target) in settings.allPinnedVolumes(direction: direction) {
                guard target.isFinite, (0...1).contains(target),
                      let device = audio.device(uid: uid, direction: direction),
                      let current = audio.volume(deviceID: device.id, direction: direction),
                      abs(current - target) >= 0.02,
                      canAttempt("volume.\(direction.rawValue).\(uid)") else { continue }
                _ = audio.setVolume(target, deviceID: device.id, direction: direction)
            }
        }
    }
}

// MARK: - Core Audio

private final class AudioDeviceController {
    static let shared = AudioDeviceController()
    private let queue = DispatchQueue(label: "com.loaysax.btt.set-audio-device.coreaudio")

    private init() {}

    func devices(direction: AudioDirection) -> [AudioDevice] {
        allDeviceIDs()
            .filter { channelCount(deviceID: $0, direction: direction) > 0 && isAlive(deviceID: $0) }
            .compactMap(makeDevice)
            .sorted { lhs, rhs in
                if lhs.transportType == kAudioDeviceTransportTypeBuiltIn && rhs.transportType != kAudioDeviceTransportTypeBuiltIn { return true }
                if rhs.transportType == kAudioDeviceTransportTypeBuiltIn && lhs.transportType != kAudioDeviceTransportTypeBuiltIn { return false }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func device(uid: String, direction: AudioDirection) -> AudioDevice? {
        devices(direction: direction).first { $0.uid == uid }
    }

    func defaultDevice(direction: AudioDirection) -> AudioDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return makeDevice(id)
    }

    func setDefaultDevice(_ deviceID: AudioDeviceID, direction: AudioDirection) -> Bool {
        queue.sync {
            var id = deviceID
            let selectors: [AudioObjectPropertySelector] = direction == .output
                ? [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice]
                : [kAudioHardwarePropertyDefaultInputDevice]
            var primarySucceeded = false
            for (index, selector) in selectors.enumerated() {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<AudioDeviceID>.size),
                    &id
                )
                // The main default must change. System-alert output is best-effort:
                // some virtual devices expose the property but reject writes to it.
                if index == 0 {
                    primarySucceeded = status == noErr
                    if !primarySucceeded { break }
                }
            }
            return primarySucceeded
        }
    }

    func volume(deviceID: AudioDeviceID, direction: AudioDirection) -> Float? {
        let elements = volumeElements(deviceID: deviceID, direction: direction, settableOnly: false)
        guard !elements.isEmpty else { return nil }
        let values = elements.compactMap { readFloatProperty(
            selector: kAudioDevicePropertyVolumeScalar,
            deviceID: deviceID,
            scope: direction.scope,
            element: $0
        ) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    func canSetVolume(deviceID: AudioDeviceID, direction: AudioDirection) -> Bool {
        !volumeElements(deviceID: deviceID, direction: direction, settableOnly: true).isEmpty
    }

    func setVolume(_ volume: Float, deviceID: AudioDeviceID, direction: AudioDirection) -> Bool {
        guard volume.isFinite else { return false }
        let clamped = min(max(volume, 0), 1)
        let elements = volumeElements(deviceID: deviceID, direction: direction, settableOnly: true)
        guard !elements.isEmpty else { return false }
        return queue.sync {
            elements.reduce(true) { allSucceeded, element in
                var value = clamped
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: direction.scope,
                    mElement: element
                )
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &value
                )
                return status == noErr && allSucceeded
            }
        }
    }

    func canMute(deviceID: AudioDeviceID, direction: AudioDirection) -> Bool {
        !muteElements(deviceID: deviceID, direction: direction, settableOnly: true).isEmpty
    }

    func isMuted(deviceID: AudioDeviceID, direction: AudioDirection) -> Bool? {
        let elements = muteElements(deviceID: deviceID, direction: direction, settableOnly: false)
        guard !elements.isEmpty else { return nil }
        let values = elements.compactMap { readUInt32Property(
            selector: kAudioDevicePropertyMute,
            deviceID: deviceID,
            scope: direction.scope,
            element: $0
        ) }
        guard !values.isEmpty else { return nil }
        return values.contains { $0 != 0 }
    }

    func setMuted(_ muted: Bool, deviceID: AudioDeviceID, direction: AudioDirection) -> Bool {
        let elements = muteElements(deviceID: deviceID, direction: direction, settableOnly: true)
        guard !elements.isEmpty else { return false }
        return queue.sync {
            elements.reduce(true) { allSucceeded, element in
                var value: UInt32 = muted ? 1 : 0
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: direction.scope,
                    mElement: element
                )
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<UInt32>.size),
                    &value
                )
                return status == noErr && allSucceeded
            }
        }
    }

    func observationAddresses() -> [AudioObservation] {
        var observations: [AudioObservation] = []
        for direction in [AudioDirection.output, .input] {
            for device in devices(direction: direction) {
                for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
                    for element in availableElements(selector: selector, deviceID: device.id, direction: direction, settableOnly: false) {
                        observations.append(AudioObservation(object: device.id,
                            address: AudioObjectPropertyAddress(mSelector: selector, mScope: direction.scope, mElement: element)))
                    }
                }
            }
        }
        return observations
    }

    private func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func makeDevice(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = readStringProperty(selector: kAudioDevicePropertyDeviceUID, deviceID: id),
              let name = readStringProperty(selector: kAudioObjectPropertyName, deviceID: id) else { return nil }
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            transportType: readUInt32Property(
                selector: kAudioDevicePropertyTransportType,
                deviceID: id,
                scope: kAudioObjectPropertyScopeGlobal,
                element: kAudioObjectPropertyElementMain
            ) ?? 0
        )
    }

    private func isAlive(deviceID: AudioDeviceID) -> Bool {
        (readUInt32Property(
            selector: kAudioDevicePropertyDeviceIsAlive,
            deviceID: deviceID,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        ) ?? 1) != 0
    }

    private func channelCount(deviceID: AudioDeviceID, direction: AudioDirection) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func volumeElements(deviceID: AudioDeviceID, direction: AudioDirection, settableOnly: Bool) -> [AudioObjectPropertyElement] {
        availableElements(
            selector: kAudioDevicePropertyVolumeScalar,
            deviceID: deviceID,
            direction: direction,
            settableOnly: settableOnly
        )
    }

    private func muteElements(deviceID: AudioDeviceID, direction: AudioDirection, settableOnly: Bool) -> [AudioObjectPropertyElement] {
        availableElements(
            selector: kAudioDevicePropertyMute,
            deviceID: deviceID,
            direction: direction,
            settableOnly: settableOnly
        )
    }

    private func availableElements(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        direction: AudioDirection,
        settableOnly: Bool
    ) -> [AudioObjectPropertyElement] {
        let channels = max(channelCount(deviceID: deviceID, direction: direction), 2)
        let candidates = [AudioObjectPropertyElement(kAudioObjectPropertyElementMain)] + (1...channels).map(AudioObjectPropertyElement.init)
        let available = candidates.filter { element in
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: direction.scope, mElement: element)
            guard AudioObjectHasProperty(deviceID, &address) else { return false }
            if !settableOnly { return true }
            var settable = DarwinBoolean(false)
            return AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
        }
        if available.contains(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return available
    }

    private func readStringProperty(selector: AudioObjectPropertySelector, deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let value = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer { value.deinitialize(count: 1); value.deallocate() }
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, value) == noErr,
              let result = value.pointee else { return nil }
        // Core Audio's name and UID property contracts transfer ownership to the caller.
        return result.takeRetainedValue() as String
    }

    private func readUInt32Property(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func readFloatProperty(
        selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
