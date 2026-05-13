# News Search

Search Google News from the launcher with a rich preview surface.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [NewsSearchPlugin.swift](https://github.com/jhasubhash/btt-plugins/blob/main/NewsSearchPlugin.swift)
- Imported from commit: `c8a095204b44e3fe8c5bb0e0455b24744453f916`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Install

Drop [NewsSearchPlugin.swift](NewsSearchPlugin.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Screenshots

![News Search screenshot](screenshots/news-search.png)

## Safety Notes

Declared permissions: `network`, `open-url`, `user-defaults`

- Fetches Google News RSS results and optional publisher logo images from the network.
- Opens selected news articles in the browser.
- Stores image display preference and surface size in UserDefaults.
