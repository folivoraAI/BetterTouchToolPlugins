# Jira Issues

Browse issues assigned to, reported by, or watched by you, or run custom JQL.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [JiraLauncherPlugin.swift](https://github.com/jhasubhash/btt-plugins/blob/main/JiraLauncherPlugin.swift)
- Imported from commit: `60711f23ea559f150e0d1d1e65dd4e3633cd9d3e`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Features

- Four built-in tabs: **Assigned to me**, **Reported by me**, **Watching**, **Custom JQL**.
- Inline filter — start typing in the launcher search box; the list narrows
  live across key, summary, status, and type.
- `↑` / `↓` to navigate, **Return** to open the highlighted issue in the browser.
- `⌘C` copies the highlighted issue URL to the clipboard.
- `⌘R` refreshes; `⌘U` copies issue URL and `⌘K` copies issue key from the
  launcher's row action popover.
- Surface size is remembered across invocations.
- **Settings**: select the **Jira Issues** row in the launcher list and press
  `⌘P` to open BetterTouchTool's action popover, then pick **Settings** to
  configure the Jira base URL and personal access token. Authentication can
  also be supplied via the `JIRA_TOKEN` environment variable.

## Install

Drop [JiraLauncherPlugin.swift](JiraLauncherPlugin.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Screenshots

![Jira Issues screenshot](screenshots/jira-issues.png)

![Jira connection settings screenshot](screenshots/jira-settings.png)

## Safety Notes

Declared permissions: `network`, `clipboard-write`, `open-url`, `user-defaults`

- Connects to the configured Jira base URL using a Jira personal access token.
- Stores the Jira base URL, token, custom JQL, and surface size in UserDefaults.
- Writes Jira issue URLs/keys to the clipboard on demand.
- Opens issues in the default browser.
