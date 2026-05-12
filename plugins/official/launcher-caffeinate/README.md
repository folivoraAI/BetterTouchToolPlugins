# Caffeinate

Launcher plugin example that starts or stops `/usr/bin/caffeinate` to keep the
Mac awake.

## Installation

Drop `Caffeinate.swift` onto the BetterTouchTool preferences window.

## Safety Notes

This plugin starts a background `caffeinate` process and writes a PID file in the
BetterTouchTool Plugins folder so it can stop the process later.
