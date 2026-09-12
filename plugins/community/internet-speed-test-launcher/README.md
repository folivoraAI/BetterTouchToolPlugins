# Internet Speed Test — BetterTouchTool Launcher Plugin

![Internet Speed Test screenshot](https://raw.githubusercontent.com/loaykhalifa/BetterTouchToolPlugins/master/plugins/community/internet-speed-test-launcher/Screenshot.jpg)

A Raycast-inspired **Internet Speed Test** plugin for **BetterTouchTool Launcher**. It runs macOS's built-in `networkQuality` command and shows a compact dashboard directly inside the BTT Launcher.

## Features

- Large circular **Download** and **Upload** speed meters
- Live throughput animation while the test is running
- Live peak graphs for download and upload
- Final parsed `networkQuality` results
- Ping / base RTT
- Responsiveness score
- Network interface name
- Apple test endpoint
- Data transferred summary
- Right-side scrollable details section
- Refresh / test-again button beside the status area
- No third-party CLI dependency required

## Screenshot

![Screenshot](https://raw.githubusercontent.com/loaykhalifa/BetterTouchToolPlugins/master/plugins/community/internet-speed-test-launcher/Screenshot.jpg)

Screenshot file in this repository:

`Screenshot.jpg`

GitHub URL:

https://github.com/loaykhalifa/BetterTouchToolPlugins/blob/master/plugins/community/internet-speed-test-launcher/Screenshot.jpg

## Requirements

- BetterTouchTool with Swift plugin support
- macOS with `/usr/bin/networkQuality` available
- Internet connection
- Apple Command Line Tools may be required if BTT needs to compile Swift source plugins

## Installation

1. Download or clone this folder.
2. Copy this file:

   `SpeedTestLauncherPlugin.swift`

   to:

   `~/Library/Application Support/BetterTouchTool/Plugins/`

3. Restart BetterTouchTool, or wait until BTT reloads Swift plugins.
4. Open **BTT Launcher**.
5. Search for:

   `Test Internet Speed`

6. Press Enter to run the test.

## How it works

The plugin uses Apple's built-in command:

`/usr/bin/networkQuality -c`

During the test, it samples the active network interface using `netstat` so the meters and peak graphs can animate with live traffic. When `networkQuality` finishes, the final JSON output is parsed and displayed.

## Notes

- Results depend on Apple's `networkQuality` test endpoints.
- The live meter uses interface throughput, so other network traffic during the test can affect the live animation.
- Final download/upload/latency/responsiveness values come from `networkQuality`.

## Files

- `SpeedTestLauncherPlugin.swift` — the BetterTouchTool Swift Launcher plugin
- `plugin.json` — metadata for community/gallery publishing
- `README.md` — this documentation
- `Screenshot.jpg` — screenshot used by the README and plugin metadata

## License

MIT — feel free to modify and share.
