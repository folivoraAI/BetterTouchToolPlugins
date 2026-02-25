# BetterTouchTool Plugins

BetterTouchTool supports four types of plugins: **Touch Bar**, **Stream Deck**, **Floating Menu Widget**, and **Action** plugins.

There are two ways to develop plugins:
1. **Swift Source Plugins** (new) — Drop a single `.swift` file into the Plugins folder. BTT compiles and loads it automatically. No Xcode project required.
2. **Xcode Bundle Plugins** — Build a plugin bundle in Xcode with full control over project structure, multiple files, and third-party dependencies.

Plugins are installed at: `/Library/Application Support/BetterTouchTool/Plugins`

---

## Swift Source Plugins (No Xcode Required)

The simplest way to create a plugin. Write a single `.swift` file, drop it into the Plugins folder, and BTT handles compilation and loading.

### Requirements

- Xcode Command Line Tools must be installed (`xcode-select --install`)
- The `.swift` file must contain a class conforming to one of the BTT plugin protocols

### Metadata Comments

Add metadata comments at the top of your `.swift` file (all optional — defaults will be inferred):

```swift
// BTT-Plugin-Name: My Widget
// BTT-Plugin-Identifier: com.myname.mywidget
// BTT-Plugin-Type: FloatingMenuWidget
// BTT-Plugin-Icon: star.fill
```

| Comment | Default if omitted |
|---|---|
| `BTT-Plugin-Name` | Filename without extension |
| `BTT-Plugin-Identifier` | `com.btt.swift.<filename>` |
| `BTT-Plugin-Type` | Inferred from protocol conformance, or `FloatingMenuWidget` |
| `BTT-Plugin-Icon` | None (SF Symbol name) |

Supported `BTT-Plugin-Type` values: `FloatingMenuWidget`, `Action`, `StreamDeck`, `TouchBar`

### How It Works

1. Drop your `.swift` file into `/Library/Application Support/BetterTouchTool/Plugins/`
2. BTT detects the file and asks: *"Compile & Load?"*
3. On approval, BTT compiles it with `swiftc` into a plugin bundle in the same folder
4. The compiled bundle is loaded and the plugin becomes available

If you edit the `.swift` file, BTT will detect the change and offer to recompile. If you delete the `.swift` file, the compiled bundle is removed automatically.

You can also drop `.swift` files onto the BTT preferences window or open them via File > Open — BTT will copy them to the Plugins folder and compile them.

### Available Protocols and Delegate Methods

All plugin protocols are defined in `BTTSwiftPluginHeader.h` (shipped inside the app bundle). The bridging header is automatically provided during compilation — you don't need to import it.

Every plugin delegate provides access to **BTT variables**:

```swift
// Set a BTT variable (accessible via {variable_name} in BTT)
delegate?.setVariable("my_var", value: "hello")

// Read a BTT variable
let value = delegate?.getVariable("my_var")
```

### Floating Menu Widget Example

```swift
// BTT-Plugin-Name: Hello Widget
// BTT-Plugin-Type: FloatingMenuWidget
// BTT-Plugin-Icon: hand.wave.fill

import Cocoa

class HelloWidget: NSObject, BTTFloatingMenuWidgetInterface {
    weak var delegate: (any BTTFloatingMenuWidgetDelegate)?

    static func widgetName() -> String { "Hello Widget" }
    static func widgetDescription() -> String { "A simple greeting widget" }
    static func widgetIcon() -> String { "hand.wave.fill" }

    func makeWidgetView() -> NSView {
        let label = NSTextField(labelWithString: "Hello from BTT!")
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.textColor = .white
        return label
    }

    func widgetDidAppear() {
        // Called when the widget becomes visible
    }

    func widgetWillDisappear() {
        // Called when the widget is hidden
    }
}
```

### Floating Menu Widget Example (SwiftUI)

Floating menu widgets can use SwiftUI — just wrap your SwiftUI view in an `NSHostingView`:

```swift
// BTT-Plugin-Name: Timer Widget
// BTT-Plugin-Type: FloatingMenuWidget
// BTT-Plugin-Icon: timer

import Cocoa
import SwiftUI

class TimerWidget: NSObject, BTTFloatingMenuWidgetInterface {
    weak var delegate: (any BTTFloatingMenuWidgetDelegate)?

    static func widgetName() -> String { "Timer Widget" }
    static func widgetDescription() -> String { "A simple countdown timer" }
    static func widgetIcon() -> String { "timer" }

    func makeWidgetView() -> NSView {
        return NSHostingView(rootView: TimerView())
    }
}

struct TimerView: View {
    @State private var secondsLeft = 60
    @State private var running = false

    var body: some View {
        VStack(spacing: 12) {
            Text("\(secondsLeft)s")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(secondsLeft <= 10 ? .red : .white)

            HStack(spacing: 16) {
                Button(running ? "Stop" : "Start") {
                    running.toggle()
                }
                Button("Reset") {
                    running = false
                    secondsLeft = 60
                }
            }
        }
        .padding()
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            guard running, secondsLeft > 0 else { return }
            secondsLeft -= 1
            if secondsLeft == 0 { running = false }
        }
    }
}
```

### Action Plugin Example

```swift
// BTT-Plugin-Name: Show Greeting
// BTT-Plugin-Type: Action
// BTT-Plugin-Icon: bubble.left.fill

import Cocoa

class ShowGreeting: NSObject, BTTActionPluginInterface {
    weak var delegate: (any BTTActionPluginDelegate)?

    static func configurationFormItems() -> BTTPluginFormItem? { nil }

    func executeAction(
        withConfiguration config: [String: Any]?,
        completionBlock: @escaping (Any?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Hello from a BTT Action Plugin!"
        alert.runModal()
        completionBlock("done")
    }
}
```

### Stream Deck Plugin Example

```swift
// BTT-Plugin-Name: Counter
// BTT-Plugin-Type: StreamDeck
// BTT-Plugin-Icon: number.circle.fill

import Cocoa

class Counter: NSObject, BTTStreamDeckPluginInterface {
    weak var delegate: (any BTTStreamDeckPluginDelegate)?
    private var count = 0

    static func configurationFormItems() -> BTTPluginFormItem? { nil }

    func widgetTitleStrings() -> [String]? {
        return ["\(count)"]
    }

    func buttonDown(_ identifier: String) -> Bool {
        count += 1
        delegate?.requestUpdate(self)
        return false // return true to cancel assigned BTT actions
    }

    func buttonUp(_ identifier: String) -> Bool {
        return false
    }
}
```

### Touch Bar Plugin Example

```swift
// BTT-Plugin-Name: Clock Text
// BTT-Plugin-Type: TouchBar
// BTT-Plugin-Icon: clock

import Cocoa

class ClockText: NSObject, BTTPluginInterface {
    weak var delegate: (any BTTTouchBarPluginDelegate)?

    static func configurationFormItems() -> BTTPluginFormItem? { nil }

    func touchBarTitleString() -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
```

---

## Xcode Bundle Plugins

For more complex plugins with multiple source files, resources, or third-party dependencies, use a standard Xcode project.

### Bundle Extensions

| Plugin Type | Extension | Protocol |
|---|---|---|
| Touch Bar | `.btttouchbarplugin` | `BTTPluginInterface` |
| Stream Deck | `.bttstreamdeckplugin` | `BTTStreamDeckPluginInterface` |
| Floating Menu Widget | `.bttwidget` | `BTTFloatingMenuWidgetInterface` |
| Action | `.bttactionplugin` | `BTTActionPluginInterface` |

### Info.plist Keys

Every plugin bundle's `Info.plist` must contain:

| Key | Description |
|---|---|
| `BTTPluginName` | Display name shown in BTT |
| `BTTPluginIdentifier` | Unique reverse-domain identifier |
| `BTTPluginType` | One of: `TouchBar`, `StreamDeck`, `FloatingMenuWidget`, `Action` |
| `BTTPluginIcon` | SF Symbol name (optional) |
| `NSPrincipalClass` | Fully qualified class name (`ModuleName.ClassName` for Swift) |

### Requirements

- Must link against `BTTPluginSupport.framework`
- Must conform to the appropriate protocol from `BTTPluginInterface.h`
- For Swift: set `NSPrincipalClass` to `$(PRODUCT_MODULE_NAME).ClassName`

### Stream Deck Plugins

Four rendering options (implement one):

1. **`widgetTitleStrings`** — Return an array of strings, rendered with user-configured BTT appearance
2. **`widgetAttributedTitleStrings`** — Return attributed strings with custom styling
3. **`widgetDictionaries`** — Return rendering description dictionaries (background color, images, SF Symbols, etc.)
4. **`widgetImages`** — Return pre-rendered NSImage instances (~140x140, BTT resizes to fit)

Stream Deck delegate methods:
- `executeAssignedBTTActions:` — Execute the BTT actions assigned to this trigger
- `executeNamedTrigger:withReply:` — Execute a named trigger
- `executeScriptCommand:withParameters:asyncReply:` — Execute a script command
- `requestUpdate:` — Request BTT to re-render the plugin
- `setVariable:value:` — Set a BTT variable
- `getVariable:` — Read a BTT variable

### Touch Bar Plugins

Three rendering options (implement one):

1. **`touchBarTitleString`** — Return a string, rendered with BTT's standard Touch Bar widget
2. **`touchBarButton`** — Return a custom NSButton instance (always return the same instance)
3. **`touchBarViewController`** — Return a custom NSViewController (always return the same instance)

Touch Bar delegate methods:
- `executeAssignedBTTActions:` — Execute assigned BTT actions
- `updateWithString:sender:` — Update the button title
- `setVariable:value:` — Set a BTT variable
- `getVariable:` — Read a BTT variable

### Floating Menu Widget Plugins

Must implement `makeWidgetView` returning an NSView.

Widget delegate methods:
- `executeAssignedBTTActions:` — Execute assigned BTT actions
- `requestWidgetUpdate:` — Request a UI refresh
- `setVariable:value:` — Set a BTT variable
- `getVariable:` — Read a BTT variable
- `executeNamedTrigger:` — Execute a named trigger
- `executeActionCategory:forSender:` — Execute a plugin-defined action category

### Action Plugins

Must implement `executeActionWithConfiguration:completionBlock:`.

Action delegate methods:
- `setVariable:value:` — Set a BTT variable
- `getVariable:` — Read a BTT variable

---

## Get Started (Xcode Bundle Plugins)

1. Clone this project: `git clone git@github.com:folivoraAI/BetterTouchToolPlugins.git`
2. Open the project in Xcode
3. Run the project — it loads sample plugins and renders them to the Touch Bar
4. Find built bundles under the "Products" group in Xcode (right-click > Show in Finder)

## Installing Plugins

- **Double-click** a plugin bundle (`.bttwidget`, `.bttactionplugin`, etc.) to install
- **Drag and drop** a plugin bundle or `.swift` file onto the BTT preferences window
- **Copy manually** to `/Library/Application Support/BetterTouchTool/Plugins/`

Touch Bar and Stream Deck plugins appear in their respective widget selectors. Floating Menu Widget plugins appear in the widget picker. Action plugins appear in the standard action selector.

## Distributing Xcode Bundle Plugins

Plugins distributed to other users must be notarized (requires an Apple developer account).

### 1. Build/Archive
```bash
xcodebuild archive -scheme BTTStreamDeckPluginCPUUsage -configuration Release \
  -archivePath ./build/streamdeckcpuusage.xcarchive
cd build/streamdeckcpuusage.xcarchive/Products/Library/Bundles/
```

### 2. Code Sign
```bash
codesign --deep -s "Developer ID Application: Your Name (TEAMID)" -f YourPlugin.bttstreamdeckplugin
```

### 3. Zip for Notarization
```bash
ditto -c -k --keepParent --rsrc YourPlugin.bttstreamdeckplugin YourPlugin.notarize.zip
```

### 4. Submit for Notarization
```bash
xcrun notarytool submit YourPlugin.notarize.zip --apple-id "your@email.com" \
  --team-id TEAMID --password "@keychain:notarization" --wait
```

### 5. Staple
```bash
xcrun stapler staple YourPlugin.bttstreamdeckplugin
```

### 6. Zip for Distribution
```bash
ditto -c -k --keepParent --rsrc YourPlugin.bttstreamdeckplugin YourPlugin.zip
```
