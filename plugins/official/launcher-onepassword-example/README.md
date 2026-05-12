# 1Password Launcher Example

Launcher plugin example that searches 1Password items through the `op` command
line tool. It demonstrates async launcher loading, dynamic children, commands,
configuration form items, CLI integration, and result actions.

## Installation

Drop `OnePasswordLauncherExamplePlugin.swift` onto the BetterTouchTool
preferences window.

## Requirements

- 1Password app
- 1Password CLI (`op`)
- 1Password CLI integration enabled

## Safety Notes

This plugin runs the `op` CLI, opens URLs and apps through `NSWorkspace`, and can
copy usernames, passwords, or one-time passwords to the clipboard when the user
selects the matching command.
