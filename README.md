# BetterTouchTool Plugins

This repository is the public home for BetterTouchTool plugin examples, reviewed
community plugins, and the older Xcode bundle development project.

For most new plugins, use a single Swift source file. Drop the `.swift` file onto
the BetterTouchTool preferences window, or copy it into the BetterTouchTool
Plugins folder. BetterTouchTool will ask before compiling and loading it.

## Repository Structure

```text
plugins/
  index.json                         Reviewed plugin registry
  official/                          Examples maintained by BetterTouchTool
  community/                         Reviewed user-submitted plugins
  _template/                         Starting point for pull requests

xcode-bundle-examples/               Advanced / legacy Xcode bundle project
  BetterTouchToolPluginDevelopment.xcodeproj
  BTTPluginSupport/
  BTTDisplayNotificationActionPlugin/
  BTTStreamDeckPluginCPUUsage/
  BTTTouchBar...

LICENSE
README.md
```

## Plugin Types

BetterTouchTool supports these plugin types:

| Type | Typical Use |
|---|---|
| `Launcher` | Add native rows, commands, saved instances, and surfaces to the BTT launcher |
| `Action` | Add a custom action to the action picker |
| `Trigger` | Observe external state and fire BTT triggers |
| `FloatingMenuWidget` | Add native widgets to floating menus |
| `StreamDeck` | Add Stream Deck widgets |
| `TouchBar` | Add Touch Bar widgets |

## Swift Source Plugins

A Swift source plugin is just a `.swift` file with metadata comments and a class
that conforms to one of the BTT plugin protocols.

```swift
// BTT-Plugin-Name: Hello Launcher
// BTT-Plugin-Identifier: com.example.hello-launcher
// BTT-Plugin-Type: Launcher
// BTT-Plugin-Icon: hand.wave

import Cocoa

final class HelloLauncher: NSObject, BTTLauncherPluginInterface {
    weak var delegate: (any BTTLauncherPluginDelegate)?

    static func launcherPluginName() -> String { "Hello Launcher" }
    static func launcherPluginDescription() -> String { "Shows one launcher result." }
    static func launcherPluginIcon() -> String { "hand.wave" }

    func launcherResults(for context: BTTLauncherPluginContext) -> [BTTLauncherPluginResult]? {
        let result = BTTLauncherPluginResult()
        result.itemIdentifier = "hello"
        result.title = "Hello from BetterTouchTool"
        result.subtitle = "This row came from a Swift source plugin."
        result.systemImageName = "hand.wave"
        return [result]
    }
}
```

### Install

Use one of these:

- drag the `.swift` file onto the BetterTouchTool preferences window
- use File > Open in BetterTouchTool and select the `.swift` file
- copy the file to `~/Library/Application Support/BetterTouchTool/Plugins/`

BetterTouchTool compiles source plugins with `swiftc`. Xcode Command Line Tools
must be installed.

## Official Examples

| Plugin | Type | What It Shows |
|---|---|---|
| [Sample Launcher](plugins/official/launcher-sample) | `Launcher` | Rows, children, commands, variables, named triggers, and a native surface |
| [Quick Links](plugins/official/launcher-quick-links) | `Launcher` | Saved plugin instances, editor surfaces, URL templates, and commands |
| [1Password Launcher Example](plugins/official/launcher-onepassword-example) | `Launcher` | Searching 1Password items through the `op` CLI |
| [Google Search Launcher](plugins/official/launcher-google-search) | `Launcher` | Opening launcher queries as Google searches |
| [Caffeinate](plugins/official/launcher-caffeinate) | `Launcher` | Toggling a background `caffeinate` process from the launcher |
| [Launcher Falling Blocks](plugins/official/launcher-falling-blocks) | `Launcher` | A SwiftUI game hosted in a launcher surface |
| [Launcher Pong](plugins/official/launcher-pong) | `Launcher` | Another interactive SwiftUI launcher-surface game |
| [Clipboard Change](plugins/official/trigger-clipboard-change) | `Trigger` | Firing BTT triggers when the clipboard changes |
| [File Watcher](plugins/official/trigger-file-watcher) | `Trigger` | Watching a configured file or folder and firing BTT triggers |
| [Compress Finder Selection](plugins/official/action-compress-finder-selection) | `Action` | Creating zip archives from Finder selections |
| [Finder Convert Selected Image to JPEG](plugins/official/action-finder-convert-selected-image-to-jpeg) | `Action` | Converting a selected Finder image to JPEG |
| [Analog Clock](plugins/official/floating-analog-clock) | `FloatingMenuWidget` | A native analog clock floating menu widget |

The registry for these plugins lives in [plugins/index.json](plugins/index.json).

## Community Plugins

`plugins/community` contains user-generated plugins submitted through pull
requests. Each accepted plugin has its own folder with source, metadata,
description, screenshots when useful, and safety notes.

Required folder shape:

```text
plugins/community/launcher-my-plugin/
  README.md
  plugin.json
  MyPlugin.swift
  screenshots/
    main.png
```

Start from [plugins/_template](plugins/_template) when creating a new
submission.

### Folder Naming

Plugin folders must start with a type prefix:

- `launcher-` for launcher plugins
- `floating-` for floating menu widget plugins
- `action-` for action plugins
- `trigger-` for trigger plugins
- `streamdeck-` for Stream Deck plugins
- `touchbar-` for Touch Bar plugins

## Review And Whitelisting

Native Swift plugins run inside BetterTouchTool's process, so community plugins
are reviewed before they are shown as trusted or installable.

In this repository, "whitelisted" means:

- the plugin was accepted into `plugins/community`
- the plugin has a `plugin.json` manifest
- the plugin is listed in `plugins/index.json`
- `reviewStatus` is `community-reviewed` or `official`
- the plugin README documents privacy-sensitive behavior

Review checklist:

- source code is readable and intentionally scoped
- plugin identifier is unique and stable
- metadata comments match `plugin.json`
- file, network, shell, AppleScript, clipboard, and accessibility behavior is documented
- plugin does not collect or transmit unnecessary data
- plugin does not auto-run destructive actions
- plugin has a screenshot or short explanation when the UI is not obvious
- plugin compiles in BetterTouchTool from a clean `.swift` file

Acceptance into the repository is not a full security audit. It is a curated
review that makes the plugin suitable for discovery by BetterTouchTool users.

## Plugin Manifest

Each plugin folder must include a `plugin.json` file:

```json
{
  "schemaVersion": 1,
  "name": "Plugin Name",
  "identifier": "com.example.btt.plugin-name",
  "type": "Launcher",
  "entry": "Plugin.swift",
  "author": {
    "name": "Your Name",
    "url": "https://example.com"
  },
  "description": "Short description of what this plugin does.",
  "minimumBetterTouchToolVersion": "TBD",
  "permissions": ["clipboard-read"],
  "screenshots": ["screenshots/main.png"],
  "reviewStatus": "submitted"
}
```

Allowed `reviewStatus` values:

- `submitted`: used in pull requests before review
- `community-reviewed`: accepted community plugin
- `official`: maintained by the BetterTouchTool project
- `deprecated`: kept for reference but hidden from normal discovery

Allowed permission labels:

- `clipboard-read`
- `clipboard-write`
- `file-read`
- `file-write`
- `network`
- `open-url`
- `shell`
- `apple-script`
- `accessibility`
- `btt-variables`
- `named-triggers`
- `launcher-plugin-instances`

## Submitting A Plugin

1. Copy `plugins/_template` to a type-prefixed folder such as `plugins/community/launcher-your-plugin-name`.
2. Rename `Plugin.swift` and update the metadata comments.
3. Fill out `plugin.json`.
4. Add screenshots if the plugin has visible UI.
5. Add safety notes to the plugin README.
6. Open a pull request.

Pull requests must keep plugin code self-contained. If your plugin needs an
Xcode project, explain why and place it in a clearly named subfolder.

## Xcode Bundle Plugins

The older multi-target Xcode project now lives in
[xcode-bundle-examples](xcode-bundle-examples).

Use the Xcode bundle path when a plugin needs:

- multiple source files
- bundled resources
- third-party dependencies
- custom framework setup
- explicit signing and notarization

Open:

```text
xcode-bundle-examples/BetterTouchToolPluginDevelopment.xcodeproj
```

Bundle plugins are still useful, but the single-file Swift source plugin path is
the default starting point for most users.

## License

See [LICENSE](LICENSE).
