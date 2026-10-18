import AppKit
import SwiftUI

/// One font setting for the transcript and the notes (the overlay and the New Call notes editor).
/// Stored in the app's preferences — the CLI has nothing to style.
enum TextAppearance {
    static let fontKey = "textFont"  // "" = system, `systemMono` = system monospaced, else a font family
    static let sizeKey = "textSize"
    static let defaultSize = 14.0
    static let sizes: ClosedRange<Double> = 10 ... 28
    static let systemMono = "<system-monospaced>"

    static func font(_ name: String, size: Double, weight: Font.Weight = .regular) -> Font {
        switch name {
        case "": .system(size: size, weight: weight)
        case systemMono: .system(size: size, weight: weight, design: .monospaced)
        default: .custom(name, size: size).weight(weight)
        }
    }

    /// Installed font families, without the hidden system ones.
    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}
