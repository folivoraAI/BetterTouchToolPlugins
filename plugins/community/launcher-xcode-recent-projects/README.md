# Xcode Recent Projects

Search and open recently used Xcode projects and workspaces.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [XcodeRecentProjects.swift](https://github.com/jhasubhash/btt-plugins/blob/main/XcodeRecentProjects.swift)
- Imported from commit: `c8a095204b44e3fe8c5bb0e0455b24744453f916`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Install

Drop [XcodeRecentProjects.swift](XcodeRecentProjects.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Safety Notes

Declared permissions: `file-read`, `spotlight`, `open-url`

- Uses Spotlight metadata to find recently used `.xcodeproj` and `.xcworkspace` files.
- Can open projects in Xcode or reveal them in Finder.
- Reads project paths from the user home search scope.
