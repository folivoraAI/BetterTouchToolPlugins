# GitHub PR Monitor

Lists open pull requests and review requests for a configured GitHub repository.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [GitHubPRMonitor.swift](https://github.com/jhasubhash/btt-plugins/blob/main/GitHubPRMonitor.swift)
- Imported from commit: `60711f23ea559f150e0d1d1e65dd4e3633cd9d3e`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: MIT (see https://github.com/jhasubhash/btt-plugins/blob/main/LICENSE).

## Features

- Two sections inside the surface: **My Open PRs** and **Review Requested**.
- Type in the launcher search box to filter by title, number, or author.
- `↑` / `↓` to navigate, **Return** to open the PR in the browser.
- `⌘C` copies the highlighted PR URL to the clipboard.
- `⌘R` refreshes; the surface remembers its size across invocations.
- **Settings**: select the **GitHub PRs** row in the launcher list and press
  `⌘P` to open BetterTouchTool's action popover, then pick **Settings** to
  configure the target repository as `owner/repo`.

## Install

Drop [GitHubPRMonitor.swift](GitHubPRMonitor.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Screenshots

![GitHub PR Monitor screenshot](screenshots/github-prs.png)

## Safety Notes

Declared permissions: `shell`, `network`, `open-url`, `clipboard-write`, `user-defaults`

- Runs the local `gh` CLI and uses its existing GitHub authentication.
- Stores the configured repository in UserDefaults.
- Writes the highlighted PR URL to the clipboard when `⌘C` is pressed.
- Opens selected pull requests in the browser.
