# Code Launcher

Quick-open recent Visual Studio Code workspaces.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [VSCodeLauncher.swift](https://github.com/jhasubhash/btt-plugins/blob/main/VSCodeLauncher.swift)
- Imported from commit: `c8a095204b44e3fe8c5bb0e0455b24744453f916`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Install

Drop [VSCodeLauncher.swift](VSCodeLauncher.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Safety Notes

Declared permissions: `file-read`, `shell`, `open-url`, `finder-selection`

- Reads VS Code recent workspace storage from the user Library folder.
- Runs local `code`, `sqlite3`, and `git` command line tools when available.
- Can open Finder selections or recent workspaces in Visual Studio Code.
