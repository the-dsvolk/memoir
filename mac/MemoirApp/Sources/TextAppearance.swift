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

    // MARK: - The transcript window's background

    static let backgroundKey = "overlayBackground"  // a `backgrounds` tag
    static let customColorKey = "overlayCustomColor"  // "#RRGGBB"
    static let opacityKey = "overlayOpacity"  // 0.5…1, for anything but translucent
    static let defaultBackground = "material"
    static let defaultCustomColor = "#1F2A44"
    static let defaultOpacity = 0.95

    /// Tag, name — "material" is the system's translucent look, which follows light / dark mode.
    static let backgrounds: [(tag: String, name: String)] = [
        ("material", "Translucent (follows the system)"), ("dark", "Dark"), ("black", "Black"),
        ("light", "Light"), ("white", "White"), ("custom", "Custom colour"),
    ]

    /// The solid colour for a background setting; nil for translucent.
    static func backgroundColor(_ tag: String, custom: String) -> NSColor? {
        switch tag {
        case "dark": NSColor(white: 0.12, alpha: 1)
        case "black": .black
        case "light": NSColor(white: 0.95, alpha: 1)
        case "white": .white
        case "custom": color(hex: custom) ?? .black
        default: nil
        }
    }

    /// Light text on a dark colour, dark text on a light one.
    static func isDark(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }

    static func color(hex: String) -> NSColor? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return defaultCustomColor }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

/// The transcript window's background from Settings. In the overlay it also sets the panel's
/// appearance (light / dark), so all text — including the notes editor — stays readable on it.
struct OverlayBackground: ViewModifier {
    var setsWindowAppearance = true
    @AppStorage(TextAppearance.backgroundKey) private var tag = TextAppearance.defaultBackground
    @AppStorage(TextAppearance.customColorKey) private var custom = TextAppearance.defaultCustomColor
    @AppStorage(TextAppearance.opacityKey) private var opacity = TextAppearance.defaultOpacity

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        if let color = TextAppearance.backgroundColor(tag, custom: custom) {
            let dark = TextAppearance.isDark(color)
            content
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: color).opacity(opacity), in: shape)
                .background { if setsWindowAppearance { WindowAppearance(dark: dark) } }
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background { if setsWindowAppearance { WindowAppearance(dark: nil) } }
        }
    }
}

/// Sets the hosting window's light / dark appearance (nil: follow the system).
private struct WindowAppearance: NSViewRepresentable {
    let dark: Bool?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let dark = dark
        Task { @MainActor in  // after the view is in its window
            view.window?.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        }
    }
}

extension View {
    func overlayBackground(setsWindowAppearance: Bool = true) -> some View {
        modifier(OverlayBackground(setsWindowAppearance: setsWindowAppearance))
    }
}
