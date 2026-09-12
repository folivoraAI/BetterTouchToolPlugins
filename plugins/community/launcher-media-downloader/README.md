# Media Downloader — BetterTouchTool Launcher Plugin

![Media Downloader screenshot](https://raw.githubusercontent.com/loaykhalifa/BetterTouchToolPlugins/master/plugins/community/launcher-media-downloader/thumbnail.jpg)

A minimal **Media Downloader** plugin for **BetterTouchTool Launcher**. It uses **yt-dlp** and FFmpeg to download video or audio from YouTube, Facebook, Instagram, TikTok and many other yt-dlp supported sites.

## Features

- One-page BetterTouchTool Launcher interface
- Video / Audio mode switch
- Format dropdown
- Thumbnail preview
- Live horizontal progress bar with speed and ETA
- Playlist URLs save into a playlist-named folder
- Downloaded filenames use `Title - Channel Name.ext`
- Choose destination folder
- Update yt-dlp / FFmpeg from inside the plugin
- Copy last log for troubleshooting
- Keyboard hints:
  - `Enter` starts download
  - `Tab` changes format
  - `Command` switches Video / Audio mode

## Screenshot

![Screenshot](https://raw.githubusercontent.com/loaykhalifa/BetterTouchToolPlugins/master/plugins/community/launcher-media-downloader/thumbnail.jpg)

Screenshot file in this repository:

`thumbnail.jpg`

GitHub URL:

https://github.com/loaykhalifa/BetterTouchToolPlugins/blob/master/plugins/community/launcher-media-downloader/thumbnail.jpg

## Requirements

- BetterTouchTool with Swift plugin support
- Apple Command Line Tools if BTT asks to compile Swift plugins
- Homebrew at:

  `/opt/homebrew/bin/brew`

- yt-dlp at:

  `/opt/homebrew/bin/yt-dlp`

- FFmpeg and ffprobe at:

  `/opt/homebrew/bin/ffmpeg`  
  `/opt/homebrew/bin/ffprobe`

The plugin includes an **Update** button that can install or update yt-dlp and FFmpeg using Homebrew.

## Installation

1. Download or clone this folder.
2. Copy this file:

   `BTTMediaDownloader.swift`

   to:

   `~/Library/Application Support/BetterTouchTool/Plugins/`

3. Restart BetterTouchTool, or wait until BTT reloads Swift plugins.
4. Open **BTT Launcher**.
5. Search for:

   `Media Downloader`

6. Paste a supported media URL, choose Video or Audio, choose a format and press **Download**.

## How it works

The plugin validates that the entered URL is an HTTP(S) URL with a non-empty host, then passes it to yt-dlp using an end-of-options marker (`--`) to avoid option injection.

For downloads, it uses yt-dlp with FFmpeg for merging or audio extraction. For previews, it asks yt-dlp for the first thumbnail and displays it inside the BTT Launcher UI.

## Output

Default downloads folder:

`~/Downloads/BTT Media Downloads`

Single items are named like:

`Video Title - Channel Name.ext`

Playlist URLs are saved into a playlist-named subfolder:

`Playlist Name/Video Title - Channel Name.ext`

Last log file:

`~/Library/Logs/BTTMediaDownloader.log`

## Security and permissions

This plugin:

- Runs `/opt/homebrew/bin/yt-dlp` for metadata, thumbnails and downloads
- Uses FFmpeg / ffprobe through yt-dlp for processing
- Runs Homebrew only when the **Update** button is pressed
- Reads the clipboard only to prefill a possible URL when opening the plugin
- Writes downloads to the selected folder
- Writes troubleshooting logs to `~/Library/Logs/BTTMediaDownloader.log`

## Notes

- Supported sites depend on yt-dlp.
- Some sites may require cookies or additional yt-dlp configuration; this plugin intentionally keeps the UI minimal.
- The current package documents the Apple Silicon Homebrew path (`/opt/homebrew`).

## Disclaimer

Only download media you own, created, or have permission to download. Respect copyright laws and each platform's terms of service.

## Files

- `BTTMediaDownloader.swift` — the BetterTouchTool Swift Launcher plugin
- `plugin.json` — metadata for community/gallery publishing
- `README.md` — this documentation
- `thumbnail.jpg` — screenshot used by the README and plugin metadata

## License

MIT — feel free to modify and share.
