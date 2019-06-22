# Note: This is experimental, the API may still change. You need BTT alpha 3.086 or later to run the plugins.

# BetterTouchTool Plguins

This repository will contain examples on how to create BetterTouchTool plugins. 
Starting with version 3.086 BetterTouchTool supports Touch Bar plugins. Soon there will also be other types of plugins (e.g. action plugins)


## Touch Bar Plugin Development

Currently there are three types of Touch Bar plugins:
Plugins that
* return a string that is then rendered and customizable using the standard BTT mechanisms
* returning a custom NSButton instance that you can style and modify
* returning a custom NSViewController instance with a custom view attached to it.

This repository contains basic example plugins for all three of these types.

## Touch Bar Plugin Requirements

A BetterTouchTool Touch Bar plugin must fulfil these requirements:
* its wrapper extension must be ".btttouchbarplugin"
* its info.plist must contain these three keys: BTTPluginName, BTTPluginIdentifier, BTTPluginIcon
* it must conform to the BTTTouchBarPluginInterface protocol (https://github.com/folivoraAI/BetterTouchToolPlugins/blob/master/BetterTouchToolPluginDevelopment/BTTTouchBarPluginInterface.h )
* it must link against the BTTPluginSupport.framework

## Get Started

1. Clone this project (```git clone git@github.com:folivoraAI/BetterTouchToolPlugins.git```)
2. Open the project in Xcode
3. Run the project.
4. Running it will open a simple sample application that loads the three sample plugins and renders them to the Touch Bar - however it does not offer the customization options BTT offers.
To see the plugin bundles, select the "Products" group in the XCode side-bar - you can then right-click them and select "Show in Finder".

## Installing Plugins into BTT

You can install the plugins into BTT by double-clicking them or by copying them to ~/Library/Application Support/BetterTouchTool
You can configure these plugins in BetterTouchTool - they will be listed under "Touch Bar Plugins" in the Touch Bar widget selector popover.

