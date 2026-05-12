# Compress Finder Selection

Action plugin example that reads the current Finder selection and creates a zip
archive next to the selected item, or on the Desktop when multiple selected items
come from different folders.

## Installation

Drop `CompressFinderSelection.swift` onto the BetterTouchTool preferences window.

## Safety Notes

This plugin uses AppleScript to read Finder's selected files, reads the selected
items, writes a zip archive, creates temporary staging folders for multi-item
archives, and runs `/usr/bin/ditto`.
