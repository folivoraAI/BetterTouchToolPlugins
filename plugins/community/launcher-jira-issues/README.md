# Jira Issues

Browse issues assigned to, reported by, or watched by you, or run custom JQL.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [JiraLauncherPlugin.swift](https://github.com/jhasubhash/btt-plugins/blob/main/JiraLauncherPlugin.swift)
- Imported from commit: `c8a095204b44e3fe8c5bb0e0455b24744453f916`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Install

Drop [JiraLauncherPlugin.swift](JiraLauncherPlugin.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Screenshots

![Jira Issues screenshot](screenshots/jira-issues.png)

![Jira Issues screenshot](screenshots/jira-settings.png)

## Safety Notes

Declared permissions: `network`, `clipboard-write`, `open-url`, `user-defaults`

- Connects to the configured Jira base URL using a personal access token.
- Stores Jira base URL, token, custom JQL, and surface size in UserDefaults.
- Can copy Jira issue URLs/keys to the clipboard and open issues in the browser.
