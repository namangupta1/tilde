import AppKit
import SwiftUI
import SwiftTerm

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct TerminalPalette {
    var foreground: NSColor
    var background: NSColor
    var cursor: NSColor
    var selection: NSColor
    var ansi: [NSColor]   // 16 colours

    static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static let dark = TerminalPalette(
        foreground: hex(0xD8DEE9), background: hex(0x1E1F24), cursor: hex(0xE5C07B), selection: hex(0x3E4451),
        ansi: [0x2E3138, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xFF7A85, 0xB5E890, 0xFFD68A, 0x82C4FF, 0xDB9CF0, 0x7FD6E0, 0xFFFFFF].map(hex))

    static let light = TerminalPalette(
        foreground: hex(0x2B2E36), background: hex(0xFAFAFA), cursor: hex(0x526FFF), selection: hex(0xD6DEF5),
        ansi: [0x383A42, 0xD03A3A, 0x3F8F2F, 0x9A6B00, 0x2F6FD6, 0x9A3FB8, 0x0F8794, 0xA0A1A7,
               0x696C77, 0xE45649, 0x50A14F, 0xC18401, 0x4078F2, 0xA626A4, 0x0184BC, 0x2B2E36].map(hex))

    var swiftTermColors: [SwiftTerm.Color] {
        ansi.map { c in
            let s = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(s.redComponent * 65535), green: UInt16(s.greenComponent * 65535), blue: UInt16(s.blueComponent * 65535))
        }
    }
}

/// App-wide appearance + font settings.
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var modeRaw: String = UserDefaults.standard.string(forKey: "appearanceMode") ?? AppearanceMode.system.rawValue {
        didSet { UserDefaults.standard.set(modeRaw, forKey: "appearanceMode"); apply() }
    }
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 13 {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            NotificationCenter.default.post(name: .terminalThemeChanged, object: nil)
        }
    }

    private var appearanceObserver: NSKeyValueObservation?

    var mode: AppearanceMode {
        get { AppearanceMode(rawValue: modeRaw) ?? .system }
        set { modeRaw = newValue.rawValue }
    }

    var isDark: Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    var palette: TerminalPalette {
        ThemeImport.stored(dark: isDark)?.palette ?? (isDark ? .dark : .light)
    }

    /// macOS default monospaced font (SF Mono).
    var font: NSFont { NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular) }

    func start() {
        apply()
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
                NotificationCenter.default.post(name: .terminalThemeChanged, object: nil)
            }
        }
    }

    func apply() {
        NSApp?.appearance = mode.nsAppearance
        objectWillChange.send()
        NotificationCenter.default.post(name: .terminalThemeChanged, object: nil)
    }

    func bumpFont(_ delta: Double) { fontSize = min(36, max(8, fontSize + delta)) }
}

extension Notification.Name {
    static let terminalThemeChanged = Notification.Name("TildeTerminalThemeChanged")
}
