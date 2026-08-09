import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PasteboardHelper

/// Cross-platform clipboard copy.
/// - macOS: `NSPasteboard`
/// - iOS: `UIPasteboard`
enum PasteboardHelper {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - FilePresenter

/// Cross-platform file/directory reveal.
///
/// macOS reveals the file in Finder via `NSWorkspace`. iOS has no Finder, so
/// the first-launch strategy is a no-op (data export via share sheet is a
/// separate concern handled by the iOS-only export flow).
enum FilePresenter {
    /// Reveal `url` in the platform file manager. Returns true when supported.
    @discardableResult
    static func reveal(_ url: URL) -> Bool {
        #if os(macOS)
        if url.hasDirectoryPath {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return true
        #else
        // iOS: no Finder. Data export is handled separately.
        return false
        #endif
    }
}
