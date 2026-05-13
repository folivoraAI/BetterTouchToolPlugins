# Kill Process

Browse running processes and force-kill or gracefully terminate them.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [KillProcess.swift](https://github.com/jhasubhash/btt-plugins/blob/main/KillProcess.swift)
- Imported from commit: `c8a095204b44e3fe8c5bb0e0455b24744453f916`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Install

Drop [KillProcess.swift](KillProcess.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Screenshots

![Kill Process screenshot](screenshots/kill-process.png)

## Safety Notes

Declared permissions: `shell`, `process-control`, `user-defaults`

- Runs `ps ax` to list processes.
- Can send SIGKILL or SIGTERM to selected processes.
- Stores the preferred surface size in UserDefaults.
