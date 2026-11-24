import AppKit

/// The cup that empties during Auto's wind-down: `cup.and.saucer.fill` drawn over `cup.and.saucer`,
/// cut off at the coffee level, so it goes from today's filled cup to today's outlined one.
enum CupIcon {
    /// Where the coffee sits in the symbol, as a share of its height from the top: just under the
    /// rim down to the bottom of the saucer. Measured on the SF Symbol.
    private static let liquidTop = 0.34
    private static let liquidBottom = 0.94

    /// `level` 1 is full, 0 is empty. Template unless a color is given, so the menu bar tints it.
    static func image(level: Double, pointSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let color { config = config.applying(NSImage.SymbolConfiguration(paletteColors: [color])) }
        guard let outline = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Vigil")?.withSymbolConfiguration(config),
              let filled = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Vigil")?.withSymbolConfiguration(config)
        else { return nil }

        let size = NSSize(width: max(outline.size.width, filled.size.width), height: max(outline.size.height, filled.size.height))
        let level = min(max(level, 0), 1)
        let image = NSImage(size: size, flipped: false) { rect in
            func draw(_ symbol: NSImage) {
                let origin = NSPoint(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2)
                symbol.draw(in: NSRect(origin: origin, size: symbol.size))
            }
            if level < 1 { draw(outline) }
            if level > 0 {
                NSGraphicsContext.saveGraphicsState()
                if level < 1 {
                    let fromTop = liquidTop + (1 - level) * (liquidBottom - liquidTop)
                    NSRect(x: 0, y: 0, width: rect.width, height: rect.height * (1 - fromTop)).clip()
                }
                draw(filled)
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "Vigil"
        return image
    }
}
