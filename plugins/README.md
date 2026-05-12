# Plugin Folders

This folder contains Swift source plugins that can be installed by dropping the
`.swift` file onto BetterTouchTool or copying it into:

```text
~/Library/Application Support/BetterTouchTool/Plugins/
```

## Layout

- `official/` contains plugins maintained by the BetterTouchTool project.
- `community/` contains user-submitted plugins that have been reviewed and accepted.
- `_template/` contains the recommended folder shape for new pull requests.
- `index.json` is a lightweight registry that can be used by documentation, tooling, or an in-app gallery.

## Per-Plugin Folder Contract

Each plugin folder should include:

- `README.md` with a description, screenshots, install notes, and safety notes
- `plugin.json` with machine-readable metadata
- one or more `.swift` source files, with a clear main entry file
- `screenshots/` when the plugin has visible UI

Folder names should start with a type prefix: `launcher-`, `floating-`,
`action-`, `trigger-`, `streamdeck-`, or `touchbar-`.

Prefer single-file Swift plugins unless the plugin genuinely needs resources,
multiple compiled targets, or third-party dependencies.
