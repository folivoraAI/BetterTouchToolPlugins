# Finder Convert Selected Image to JPEG

Action plugin example that converts the currently selected Finder image to a
JPEG file next to the original. The action exposes configuration for JPEG
quality, overwriting, and revealing the result in Finder.

## Installation

Drop `FinderConvertSelectedImageToJPEG.swift` onto the BetterTouchTool
preferences window.

## Safety Notes

This plugin uses AppleScript to read Finder's selected item, reads the selected
image, writes a JPEG next to it, and can ask Finder to reveal the converted
file.
