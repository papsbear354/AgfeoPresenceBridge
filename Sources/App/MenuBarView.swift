import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusLine)
        if let availability = model.availabilityLine {
            Text(availability)
        }
        Text("Zuletzt gesendet: \(model.lastSentDescription)")

        if !model.isSignedIn {
            Button("Bei Microsoft anmelden…") {
                Task { await model.signIn() }
            }
            .disabled(model.authState == .working)
        }

        Divider()

        Menu("Grundprofil") {
            ForEach(model.settings.knownProfiles, id: \.self) { profile in
                Toggle(profile, isOn: Binding(
                    get: { model.settings.baseProfile == profile },
                    set: { if $0 { model.settings.baseProfile = profile } }))
            }
        }

        Menu("Jetzt schalten auf") {
            ForEach(model.settings.knownProfiles, id: \.self) { profile in
                Button(profile) {
                    Task { await model.send(profile: profile) }
                }
            }
        }
        .disabled(model.isSending)

        Divider()

        Toggle("Automatik aktiv", isOn: $model.settings.automationEnabled)

        if #available(macOS 14.0, *) {
            SettingsLink {
                Text("Einstellungen…")
            }
            .keyboardShortcut(",", modifiers: .command)
        } else {
            Button("Einstellungen…") { model.openSettingsWindow() }
                .keyboardShortcut(",", modifiers: .command)
        }

        Button("Log anzeigen") { model.revealLog() }

        Divider()

        Button("Beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
