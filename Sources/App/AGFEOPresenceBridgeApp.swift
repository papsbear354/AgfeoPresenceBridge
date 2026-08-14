import SwiftUI

/// Nimmt URLs entgegen, die das Klick-Skript schickt.
///
/// Über einen Delegaten statt `onOpenURL`: Die App hat als Menüleisten-Programm
/// kein reguläres Fenster, an dem die Scene-Variante zuverlässig hängt.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        for url in urls {
            guard let event = CallEvent(url: url) else { continue }
            Task { @MainActor in model.handleCallEvent(event) }
        }
    }
}

@main
struct AGFEOPresenceBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // Bei pausierter Automatik gedimmt (SPEC §11).
            Image(systemName: model.statusSymbol)
                .opacity(model.statusSymbolIsDimmed ? 0.5 : 1)
                .onAppear { delegate.model = model }
        }
        .menuBarExtraStyle(.menu)

        // Qualifiziert, weil `Settings` hier auch das eigene Einstellungsmodell ist.
        SwiftUI.Settings {
            SettingsView(model: model)
        }
    }
}
