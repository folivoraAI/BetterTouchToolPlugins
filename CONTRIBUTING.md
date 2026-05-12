# Contributing BetterTouchTool Plugins

Community plugins are accepted through pull requests.

## New Plugin Checklist

- Copy `plugins/_template` to a type-prefixed folder such as `plugins/community/launcher-your-plugin-name`
- Keep the plugin source code readable and self-contained
- Use a unique reverse-domain `BTT-Plugin-Identifier`
- Make `plugin.json` match the Swift metadata comments
- Include a screenshot when the plugin has visible UI
- Document file, network, shell, AppleScript, clipboard, accessibility, or privacy-sensitive behavior
- Test the plugin by dropping the `.swift` file onto BetterTouchTool

Use these folder prefixes:

- `launcher-` for launcher plugins
- `floating-` for floating menu widget plugins
- `action-` for action plugins
- `trigger-` for trigger plugins
- `streamdeck-` for Stream Deck plugins
- `touchbar-` for Touch Bar plugins

Native Swift plugins run inside BetterTouchTool's process, so maintainers may ask
for changes before a plugin is listed in `plugins/index.json`.
