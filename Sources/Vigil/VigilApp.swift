import SwiftUI

struct VigilApp: App {
    @StateObject private var model = VigilModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(model)
                .environmentObject(model.updater)
        } label: {
            // Template icon + text: macOS tints both for light/dark menu bars automatically.
            HStack(spacing: 2) {
                Image(systemName: model.menuIcon)
                if let badge = model.menuBadge {
                    Text(badge).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
