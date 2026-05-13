# BetterTouchTool Plugin Gallery

This folder contains the static plugin gallery for GitHub Pages or any other
static host.

## Update The Catalog

Run this from the repository root after adding or editing plugin metadata:

```sh
node tools/build-site-catalog.mjs
```

The generator reads `plugins/official/**/plugin.json` and
`plugins/community/**/plugin.json`, then writes:

- `site/catalog.json`
- `site/plugins.generated.js`
- `site/downloads/`

The page itself has no framework or runtime dependencies.
