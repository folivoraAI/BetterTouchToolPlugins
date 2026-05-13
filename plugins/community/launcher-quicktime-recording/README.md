# QuickTime Recording

Start QuickTime screen, audio, or movie recordings from the launcher.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [QuickTimeRecording.swift](https://github.com/jhasubhash/btt-plugins/blob/main/QuickTimeRecording.swift)
- Imported from commit: `c8a095204b44e3fe8c5bb0e0455b24744453f916`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Install

Drop [QuickTimeRecording.swift](QuickTimeRecording.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Safety Notes

Declared permissions: `apple-script`, `accessibility`, `open-url`

- Activates QuickTime Player.
- Uses AppleScript/System Events to trigger QuickTime recording menu items.
- Requires the usual macOS automation/accessibility permissions for menu control.
