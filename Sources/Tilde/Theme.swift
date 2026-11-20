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

    static func make(fg: UInt32, bg: UInt32, cursor: UInt32, sel: UInt32, _ ansi: [UInt32]) -> TerminalPalette {
        TerminalPalette(foreground: hex(fg), background: hex(bg), cursor: hex(cursor), selection: hex(sel), ansi: ansi.map(hex))
    }

    var isDarkBackground: Bool {
        let c = background.usingColorSpace(.sRGB) ?? background
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }

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

    @Published var themeRaw: String = UserDefaults.standard.string(forKey: "theme") ?? BuiltinTheme.tilde.rawValue {
        didSet { UserDefaults.standard.set(themeRaw, forKey: "theme"); apply() }
    }
    @Published var fontName: String = UserDefaults.standard.string(forKey: "fontName") ?? "" {
        didSet { UserDefaults.standard.set(fontName, forKey: "fontName"); NotificationCenter.default.post(name: .terminalThemeChanged, object: nil) }
    }
    @Published var cursorRaw: String = UserDefaults.standard.string(forKey: "cursorStyle") ?? "blinkBlock" {
        didSet { UserDefaults.standard.set(cursorRaw, forKey: "cursorStyle"); NotificationCenter.default.post(name: .terminalThemeChanged, object: nil) }
    }
    @Published var optionAsMeta: Bool = UserDefaults.standard.bool(forKey: "optionAsMeta") {
        didSet { UserDefaults.standard.set(optionAsMeta, forKey: "optionAsMeta"); NotificationCenter.default.post(name: .terminalThemeChanged, object: nil) }
    }

    var theme: BuiltinTheme { BuiltinTheme(rawValue: themeRaw) ?? .tilde }

    /// An imported iTerm2 scheme wins; otherwise the built-in theme for the current mode.
    var palette: TerminalPalette {
        ThemeImport.stored(dark: isDark)?.palette ?? theme.palette(dark: isDark)
    }

    var cursorStyle: CursorStyle {
        switch cursorRaw {
        case "steadyBlock": return .steadyBlock
        case "blinkBar": return .blinkBar
        case "steadyBar": return .steadyBar
        case "blinkUnderline": return .blinkUnderline
        case "steadyUnderline": return .steadyUnderline
        default: return .blinkBlock
        }
    }

    /// macOS default monospaced font (SF Mono).
    var font: NSFont {
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: CGFloat(fontSize)) { return f }
        return NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
    }

    static let monospacedFonts: [String] = {
        let names = NSFontManager.shared.availableFontFamilies.filter { fam in
            guard let f = NSFont(name: fam, size: 12) else { return false }
            return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono") || fam.localizedCaseInsensitiveContains("code")
        }
        return names.sorted()
    }()

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

/// Built-in colour themes. Some follow light/dark mode, others look the same in both.
enum BuiltinTheme: String, CaseIterable, Identifiable {
    case tilde, solarized, gruvbox, nord, dracula, paper
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tilde: return "Tilde (follows light/dark)"
        case .solarized: return "Solarized (follows light/dark)"
        case .gruvbox: return "Gruvbox (follows light/dark)"
        case .nord: return "Nord (dark)"
        case .dracula: return "Dracula (dark)"
        case .paper: return "Paper (light)"
        }
    }

    func palette(dark: Bool) -> TerminalPalette {
        switch self {
        case .tilde: return dark ? .dark : .light
        case .paper: return .light
        case .solarized:
            let ansi: [UInt32] = [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                                  0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]
            return dark ? .make(fg: 0x839496, bg: 0x002B36, cursor: 0x93A1A1, sel: 0x073642, ansi)
                        : .make(fg: 0x657B83, bg: 0xFDF6E3, cursor: 0x586E75, sel: 0xEEE8D5, ansi)
        case .gruvbox:
            return dark
                ? .make(fg: 0xEBDBB2, bg: 0x282828, cursor: 0xEBDBB2, sel: 0x504945,
                        [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                         0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2])
                : .make(fg: 0x3C3836, bg: 0xFBF1C7, cursor: 0x3C3836, sel: 0xEBDBB2,
                        [0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
                         0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836])
        case .nord:
            return .make(fg: 0xD8DEE9, bg: 0x2E3440, cursor: 0xD8DEE9, sel: 0x434C5E,
                         [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                          0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])
        case .dracula:
            return .make(fg: 0xF8F8F2, bg: 0x282A36, cursor: 0xF8F8F2, sel: 0x44475A,
                         [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                          0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])
        }
    }
}
