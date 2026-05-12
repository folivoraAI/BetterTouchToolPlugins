// BTT-Plugin-Name: Finder Convert Selected Image to JPEG
// BTT-Plugin-Identifier: com.folivora.btt.action.finderconvertselectedimagetojpeg
// BTT-Plugin-Type: Action
// BTT-Plugin-Icon: photo.fill
// BTT-AI-Managed: true

import Cocoa
import UniformTypeIdentifiers

class FinderConvertSelectedImageToJPEG: NSObject, BTTActionPluginInterface {
    weak var delegate: (any BTTActionPluginDelegate)?

    static func configurationFormItems() -> BTTPluginFormItem? {
        let group = BTTPluginFormItem()
        group.formFieldType = BTTFormTypeFormGroup

        let quality = BTTPluginFormItem()
        quality.formFieldType = BTTFormTypeSlider
        quality.formLabel1 = "JPEG Quality"
        quality.formFieldID = "jpegQuality"
        quality.dataType = BTTFormDataNumber
        quality.minValue = 0.1
        quality.maxValue = 1.0
        quality.defaultValue = 0.9

        let overwrite = BTTPluginFormItem()
        overwrite.formFieldType = BTTFormTypeCheckbox
        overwrite.formLabel1 = "Overwrite existing JPEG file if present"
        overwrite.formFieldID = "overwriteExisting"
        overwrite.defaultValue = false

        let reveal = BTTPluginFormItem()
        reveal.formFieldType = BTTFormTypeCheckbox
        reveal.formLabel1 = "Reveal converted file in Finder"
        reveal.formFieldID = "revealInFinder"
        reveal.defaultValue = true

        let description = BTTPluginFormItem()
        description.formFieldType = BTTFormTypeDescription
        description.formLabel1 = "Converts the currently selected Finder file to a JPEG next to the original file if it is a supported image."

        group.formOptions = [description, quality, overwrite, reveal]
        return group
    }

    static func actionName(withConfiguration config: [AnyHashable: Any]?) -> String? {
        let quality = config?["plugin_var_jpegQuality"] as? Double ?? 0.9
        return String(format: "Convert Selected Finder Image to JPEG (%.0f%%)", quality * 100)
    }

    func executeAction(
        withConfiguration config: [AnyHashable: Any]?,
        completionBlock: ((@Sendable (Any?) -> Void)?)
    ) {
        let quality = config?["plugin_var_jpegQuality"] as? Double ?? 0.9
        let overwriteExisting = config?["plugin_var_overwriteExisting"] as? Bool ?? false
        let revealInFinder = config?["plugin_var_revealInFinder"] as? Bool ?? true

        guard let selectedFileURL = currentlySelectedFinderItem() else {
            showAlert(title: "No Finder selection", message: "Please select exactly one image file in Finder and run the action again.")
            completionBlock?("no_selection")
            return
        }

        guard isSupportedImageFile(at: selectedFileURL) else {
            showAlert(title: "Unsupported file", message: "The selected item is not a supported image file.")
            completionBlock?("unsupported_file")
            return
        }

        guard let image = NSImage(contentsOf: selectedFileURL) else {
            showAlert(title: "Image could not be read", message: "BetterTouchTool could not load the selected image.")
            completionBlock?("load_failed")
            return
        }

        guard let jpegData = jpegData(from: image, quality: quality) else {
            showAlert(title: "Conversion failed", message: "The image could not be converted to JPEG.")
            completionBlock?("conversion_failed")
            return
        }

        let outputURL = outputJPEGURL(for: selectedFileURL)
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: outputURL.path) {
            if overwriteExisting {
                do {
                    try fileManager.removeItem(at: outputURL)
                } catch {
                    showAlert(title: "Overwrite failed", message: "Existing JPEG could not be replaced: \(error.localizedDescription)")
                    completionBlock?("overwrite_failed")
                    return
                }
            } else {
                showAlert(title: "JPEG already exists", message: "A JPEG with the same name already exists next to the original file.")
                completionBlock?("target_exists")
                return
            }
        }

        do {
            try jpegData.write(to: outputURL, options: .atomic)
            if revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            }
            completionBlock?(outputURL.path)
        } catch {
            showAlert(title: "Save failed", message: "The JPEG could not be saved: \(error.localizedDescription)")
            completionBlock?("save_failed")
        }
    }

    private func currentlySelectedFinderItem() -> URL? {
        let script = """
        tell application \"Finder\"
            if not (exists Finder window 1) and (count of selection) is 0 then
                return ""
            end if
            set theSelection to selection
            if (count of theSelection) is not 1 then
                return ""
            end if
            return POSIX path of (theSelection's item 1 as alias)
        end tell
        """

        var errorDict: NSDictionary?
        if let scriptObject = NSAppleScript(source: script),
           let output = scriptObject.executeAndReturnError(&errorDict).stringValue,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: output)
        }
        return nil
    }

    private func isSupportedImageFile(at url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .image) {
                return true
            }
        }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            return false
        }
        return true
    }

    private func jpegData(from image: NSImage, quality: Double) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        let clampedQuality = max(0.0, min(1.0, quality))
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: clampedQuality])
    }

    private func outputJPEGURL(for sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent(baseName).appendingPathExtension("jpg")
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
