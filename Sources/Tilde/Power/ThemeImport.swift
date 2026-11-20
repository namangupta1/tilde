import AppKit
import UniformTypeIdentifiers

/// A palette saved in UserDefaults (hex strings), e.g. imported from iTerm2.
struct StoredPalette: Codable {
    var name: String
    var foreground: String
    var background: String
    var cursor: String
    var selection: String
    var ansi: [String]

    var palette: TerminalPalette? {
        guard ansi.count == 16 else { return nil }
        func c(_ s: String) -> NSColor { TerminalPalette.hex(UInt32(s, radix: 16) ?? 0) }
        return TerminalPalette(foreground: c(foreground), background: c(background), cursor: c(cursor),
                               selection: c(selection), ansi: ansi.map(c))
    }
}

@MainActor
enum ThemeImport {
    static func key(dark: Bool) -> String { dark ? "customPaletteDark" : "customPaletteLight" }

    static func stored(dark: Bool) -> StoredPalette? {
        UserDefaults.standard.data(forKey: key(dark: dark)).flatMap { try? JSONDecoder().decode(StoredPalette.self, from: $0) }
    }

    static func reset(dark: Bool) {
        UserDefaults.standard.removeObject(forKey: key(dark: dark))
        ThemeManager.shared.apply()
    }

    /// Picks an .itermcolors file; it becomes the dark or light palette depending on its background.
    static func importScheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "itermcolors") ?? .propertyList]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an iTerm2 colour scheme (.itermcolors)"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let p = try parse(url)
            let bg = TerminalPalette.hex(UInt32(p.background, radix: 16) ?? 0).usingColorSpace(.sRGB)!
            let lum = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
            let dark = lum < 0.5
            UserDefaults.standard.set(try JSONEncoder().encode(p), forKey: key(dark: dark))
            ThemeManager.shared.apply()
            let a = NSAlert()
            a.messageText = "Imported “\(p.name)”"
            a.informativeText = "It's now used whenever Tilde is in \(dark ? "dark" : "light") mode. Reset it in Settings ▸ Appearance."
            a.runModal()
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't import that file"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    struct ParseError: LocalizedError {
        var errorDescription: String?
    }

    static func parse(_ url: URL) throws -> StoredPalette {
        let data = try Data(contentsOf: url)
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ParseError(errorDescription: "Not an iTerm2 colour scheme.")
        }
        func hex(_ key: String) -> String? {
            guard let c = dict[key] as? [String: Any],
                  let r = (c["Red Component"] as? NSNumber)?.doubleValue,
                  let g = (c["Green Component"] as? NSNumber)?.doubleValue,
                  let b = (c["Blue Component"] as? NSNumber)?.doubleValue else { return nil }
            // Convert from the scheme's colour space (usually sRGB or P3/calibrated) to sRGB.
            let space = (c["Color Space"] as? String) ?? "sRGB"
            let src: NSColor = space == "P3"
                ? NSColor(displayP3Red: r, green: g, blue: b, alpha: 1)
                : space == "Calibrated" ? NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
                : NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
            let s = src.usingColorSpace(.sRGB) ?? src
            func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
            return String(format: "%02X%02X%02X", byte(s.redComponent), byte(s.greenComponent), byte(s.blueComponent))
        }
        var ansi: [String] = []
        for i in 0..<16 {
            guard let h = hex("Ansi \(i) Color") else { throw ParseError(errorDescription: "Missing “Ansi \(i) Color”.") }
            ansi.append(h)
        }
        guard let fg = hex("Foreground Color"), let bg = hex("Background Color") else {
            throw ParseError(errorDescription: "Missing foreground or background colour.")
        }
        return StoredPalette(name: url.deletingPathExtension().lastPathComponent, foreground: fg, background: bg,
                             cursor: hex("Cursor Color") ?? fg, selection: hex("Selection Color") ?? ansi[8], ansi: ansi)
    }
}
