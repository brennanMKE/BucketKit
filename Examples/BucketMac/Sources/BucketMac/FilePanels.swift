import AppKit
import Foundation

/// Tiny wrappers over `NSOpenPanel`/`NSSavePanel` so SwiftUI views can
/// invoke the native panels without importing AppKit themselves.
///
/// `runModal()` is a synchronous AppKit API; we surface it here as a
/// `@MainActor` function returning the chosen URL (or `nil`).
@MainActor
enum FilePanels {
    /// Presents an open panel for picking a single existing file.
    /// Returns the chosen `URL` or `nil` if the user cancelled.
    static func chooseOpenFile(message: String = "Choose a file to upload") -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Presents a save panel for picking a destination file URL.
    /// `suggestedName` becomes the default filename in the dialog.
    /// Returns the chosen `URL` or `nil` if the user cancelled.
    static func chooseSaveFile(
        message: String = "Choose where to save the download",
        suggestedName: String = "download.bin"
    ) -> URL? {
        let panel = NSSavePanel()
        panel.message = message
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
