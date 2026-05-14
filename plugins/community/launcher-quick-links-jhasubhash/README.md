# Quick Links

Save reusable URL or filesystem-path templates and open them with the right app.

## Origin

- Original repository: [jhasubhash/btt-plugins](https://github.com/jhasubhash/btt-plugins)
- Original source: [QuickLinkLauncherPlugin.swift](https://github.com/jhasubhash/btt-plugins/blob/main/QuickLinkLauncherPlugin.swift)
- Imported from commit: `60711f23ea559f150e0d1d1e65dd4e3633cd9d3e`
- Copyright: Copyright (c) Subhash Jha and contributors to jhasubhash/btt-plugins.
- Upstream license: No explicit upstream license file was present in the upstream repository at import time.

## Features

- **Create Quick Link** opens a dedicated editor surface for saving a new
  URL or filesystem-path template as a launcher plugin instance.
- Saved links surface as their own searchable rows in the launcher, each
  with its own icon, keywords, and "Open With" target.
- **Manage Quick Links** appears in the launcher when at least one quick
  link is saved; it opens a centralized list surface where you can edit,
  duplicate, or delete any saved link.
- Each saved row exposes per-row actions (edit, duplicate, copy, delete)
  through BetterTouchTool's native `⌘P` action popover.

## Install

Drop [QuickLinkLauncherPlugin.swift](QuickLinkLauncherPlugin.swift) onto the BetterTouchTool preferences window, or copy it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Screenshots

![Quick Links list screenshot](screenshots/quick-links.png)

![Manage Quick Links surface screenshot](screenshots/quick-links-manage.png)

## Safety Notes

Declared permissions: `clipboard-read`, `clipboard-write`, `open-url`, `file-read`, `launcher-plugin-instances`, `user-defaults`

- Reads the clipboard to suggest URL/path templates and can copy resolved links back to the clipboard.
- Uses BTT launcher plugin instances to save quick links.
- Opens URLs, files, and folders with the selected or default application.
