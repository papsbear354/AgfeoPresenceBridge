import SwiftUI

@main
struct AGFEOPresenceBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // Bei pausierter Automatik gedimmt (SPEC §11).
            Image(systemName: model.statusSymbol)
                .opacity(model.statusSymbolIsDimmed ? 0.5 : 1)
        }
        .menuBarExtraStyle(.menu)

        // Qualifiziert, weil `Settings` hier auch das eigene Einstellungsmodell ist.
        SwiftUI.Settings {
            SettingsView(model: model)
        }
    }
}
