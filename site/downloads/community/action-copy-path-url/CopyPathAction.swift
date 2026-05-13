// BTT-Plugin-Name: Copy Path / URL
// BTT-Plugin-Identifier: com.bttuserplugin.swift.copypathaction
// BTT-Plugin-Type: Action
// BTT-Plugin-Icon: doc.on.clipboard
// BTT-AI-Managed: true

import AppKit
import ApplicationServices

class CopyPathAction: NSObject, BTTActionPluginInterface {
    weak var delegate: (any BTTActionPluginDelegate)?

    private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
        "company.thebrowser.dia",
    ]

    static func configurationFormItems() -> BTTPluginFormItem? { nil }

    func executeAction(
        withConfiguration config: [AnyHashable: Any]?,
        completionBlock: ((@Sendable (Any?) -> Void)?)
    ) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            completionBlock?(nil)
            return
        }

        let bundleID = app.bundleIdentifier ?? ""
        let isBrowser = Self.browserBundleIDs.contains(bundleID)
        let isFinder  = bundleID == "com.apple.finder"

        let copiedText: String?

        if isBrowser {
            copiedText = getBrowserURL(bundleID: bundleID, pid: app.processIdentifier)
        } else if isFinder {
            copiedText = getFinderPath()
        } else {
            copiedText = getDocumentPath(bundleID: bundleID, pid: app.processIdentifier)
        }

        if let text = copiedText, !text.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            delegate?.setVariable("copypath_result", value: text)
        }

        completionBlock?(copiedText)
    }

    // MARK: - Browser

    private func getBrowserURL(bundleID: String, pid: pid_t) -> String? {
        let script: String
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            script = """
                tell application id "\(bundleID)"
                    if (count of windows) > 0 then
                        return URL of current tab of front window
                    end if
                end tell
                """
        case "org.mozilla.firefox":
            script = """
                tell application "System Events"
                    tell process "Firefox"
                        try
                            return value of text field 1 of toolbar "Navigation" of front window
                        on error
                            return ""
                        end try
                    end tell
                end tell
                """
        default:
            script = """
                tell application id "\(bundleID)"
                    if (count of windows) > 0 then
                        return URL of active tab of front window
                    end if
                end tell
                """
        }
        var candidates: [String] = []
        if let url = runAppleScript(script), !url.isEmpty {
            candidates.append(url)
        }
        // Chromium browsers (Chrome, Edge, Brave, Arc, Dia, Vivaldi, …) expose
        // the live page URL via AXURL on the AXWebArea element. This is the
        // most reliable source for SPA sites like YouTube.
        if let web = getWebAreaURL(pid: pid), !web.isEmpty {
            candidates.append(web)
        }
        // Address-bar text field (works when AXURL is unavailable).
        if let addr = getBrowserAddressBarURL(pid: pid), !addr.isEmpty {
            candidates.append(addr)
        }
        if let doc = getURLViaAX(pid: pid), !doc.isEmpty {
            candidates.append(doc)
        }
        return pickBestURL(candidates)
    }

    /// Picks the most "specific" URL from candidates: prefers ones with a
    /// query/fragment/real path over bare origins like https://www.youtube.com/.
    private func pickBestURL(_ candidates: [String]) -> String? {
        if candidates.isEmpty { return nil }
        if let full = candidates.first(where: { looksLikeFullURL($0) }) {
            return full
        }
        return candidates.first
    }

    /// Heuristic: a "full" URL typically has either a non-root path or a query
    /// string. A bare origin like "https://www.youtube.com/" while a video is
    /// playing usually indicates a stale/short value.
    private func looksLikeFullURL(_ s: String) -> Bool {
        guard let u = URL(string: s) else { return false }
        let path = u.path
        let hasQuery = (u.query?.isEmpty == false)
        let hasFragment = (u.fragment?.isEmpty == false)
        let hasRealPath = !path.isEmpty && path != "/"
        return hasQuery || hasFragment || hasRealPath
    }

    /// Walks the AX tree under the front window's toolbar and returns the
    /// value of the first text field found (the omnibox / address bar).
    private func getBrowserAddressBarURL(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        for windowAttr in ["AXFocusedWindow", "AXMainWindow"] {
            var windowCF: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, windowAttr as CFString, &windowCF) == .success,
                  let windowRef = windowCF,
                  CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { continue }
            let windowEl = windowRef as! AXUIElement
            if let v = findAddressBarValue(in: windowEl, depth: 0) {
                return normalizeURLString(v)
            }
        }
        return nil
    }

    /// Finds the AXWebArea descendant of the front window and reads its AXURL.
    /// Chromium browsers (including Dia, Arc, Chrome, Edge, Brave) expose the
    /// current page URL here, even on SPA navigations.
    private func getWebAreaURL(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        for windowAttr in ["AXFocusedWindow", "AXMainWindow"] {
            var windowCF: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, windowAttr as CFString, &windowCF) == .success,
                  let windowRef = windowCF,
                  CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { continue }
            let windowEl = windowRef as! AXUIElement
            if let s = findWebAreaURL(in: windowEl, depth: 0) { return s }
        }
        return nil
    }

    private func findWebAreaURL(in element: AXUIElement, depth: Int) -> String? {
        if depth > 12 { return nil }

        var roleCF: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleCF) == .success,
           let role = roleCF as? String,
           role == "AXWebArea" {
            var urlCF: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlCF) == .success,
               let ref = urlCF {
                if CFGetTypeID(ref) == CFURLGetTypeID() {
                    let u = ref as! CFURL as URL
                    let s = u.absoluteString
                    if !s.isEmpty { return s }
                } else if let s = ref as? String, !s.isEmpty {
                    return s
                }
            }
        }

        var childrenCF: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenCF) == .success,
              let children = childrenCF as? [AXUIElement] else { return nil }
        for child in children {
            if let r = findWebAreaURL(in: child, depth: depth + 1) { return r }
        }
        return nil
    }

    /// Depth-limited DFS for a text field / combo box whose value parses as a URL.
    private func findAddressBarValue(in element: AXUIElement, depth: Int) -> String? {
        if depth > 12 { return nil }

        var roleCF: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleCF) == .success,
           let role = roleCF as? String,
           role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String) {
            var valCF: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valCF) == .success,
               let val = valCF as? String,
               !val.isEmpty,
               looksLikeURLString(val) {
                return val
            }
        }

        var childrenCF: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenCF) == .success,
              let children = childrenCF as? [AXUIElement] else { return nil }
        for child in children {
            if let r = findAddressBarValue(in: child, depth: depth + 1) { return r }
        }
        return nil
    }

    private func looksLikeURLString(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        // Chromium browsers often hide the scheme; accept things like
        // "www.youtube.com/watch?v=..." or "youtube.com/watch...".
        if s.contains(" ") { return false }
        if s.contains(".") && (s.contains("/") || s.contains("?")) { return true }
        return false
    }

    private func normalizeURLString(_ s: String) -> String {
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return s }
        return "https://" + s
    }

    // MARK: - Finder

    private func getFinderPath() -> String? {
        let script = """
            tell application "Finder"
                set sel to selection
                if (count of sel) > 0 then
                    set pathList to {}
                    repeat with f in sel
                        set end of pathList to POSIX path of (f as alias)
                    end repeat
                    set AppleScript's text item delimiters to linefeed
                    set r to pathList as text
                    set AppleScript's text item delimiters to ""
                    return r
                else
                    try
                        return POSIX path of (target of front Finder window as alias)
                    on error
                        return ""
                    end try
                end if
            end tell
            """
        return runAppleScript(script)
    }

    // MARK: - Generic document

    private func getDocumentPath(bundleID: String, pid: pid_t) -> String? {
        // AX first — works for VS Code, Xcode, etc. without scripting permissions
        if let docStr = getURLViaAX(pid: pid), !docStr.isEmpty {
            if let url = URL(string: docStr), url.isFileURL {
                return url.path
            }
            return docStr
        }
        // AppleScript fallback for scriptable apps
        let script = """
            tell application id "\(bundleID)"
                try
                    set d to front document
                    try
                        return POSIX path of (file of d as alias)
                    on error
                        try
                            return POSIX path of (path of d as alias)
                        on error
                            return ""
                        end try
                    end try
                on error
                    return ""
                end try
            end tell
            """
        let r = runAppleScript(script)
        return (r?.isEmpty == false) ? r : nil
    }

    // MARK: - Accessibility API

    private func getURLViaAX(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        for windowAttr in ["AXFocusedWindow", "AXMainWindow"] {
            var windowCF: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, windowAttr as CFString, &windowCF) == .success,
                  let windowRef = windowCF,
                  CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { continue }
            let windowEl = windowRef as! AXUIElement
            var docCF: CFTypeRef?
            guard AXUIElementCopyAttributeValue(windowEl, "AXDocument" as CFString, &docCF) == .success,
                  let docStr = docCF as? String, !docStr.isEmpty else { continue }
            return docStr
        }
        return nil
    }

    // MARK: - AppleScript helper

    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return descriptor.stringValue
    }
}
