import SwiftUI
import AppKit

struct VigilApp: App {
    @StateObject private var model = VigilModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
                .environmentObject(model.updater)
        } label: {
            // Template icon + text: macOS tints both for light/dark menu bars automatically.
            // A red cup is a plain (non-template) image, the one way to color a menu-bar icon.
            HStack(spacing: 2) {
                if model.lidArmed, let red = Self.redSymbol(model.menuIcon) {
                    Image(nsImage: red)
                } else {
                    Image(systemName: model.menuIcon)
                }
                if let badge = model.menuBadge {
                    Text(badge).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private static func redSymbol(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Vigil")?.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }
}
