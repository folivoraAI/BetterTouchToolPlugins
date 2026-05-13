# Copy Path / URL

Copies the front app's document path or the active browser tab's URL.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [CopyPathAction.swift](https://github.com/jhasubhash/btt-plugins/blob/main/CopyPathAction.swift)
- Imported from commit: `c8a095204b44e3fe8c5bb0e0455b24744453f916`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Install

Drop [CopyPathAction.swift](CopyPathAction.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Safety Notes

Declared permissions: `clipboard-write`, `apple-script`, `accessibility`, `file-read`, `btt-variables`

- Reads the frontmost app and uses AppleScript/accessibility fallbacks to resolve browser URLs and document paths.
- Reads Finder selection paths when Finder is frontmost.
- Writes the resolved path or URL to the clipboard and to the BTT variable `copypath_result`.
