import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    static let durations: [(minutes: Int, label: String)] = [
        (15, "15 Minuten"),
        (30, "30 Minuten"),
        (60, "1 Stunde"),
        (120, "2 Stunden"),
    ]

    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        Text(model.statusLine)
        if let availability = model.availabilityLine {
            Text(availability)
        }
        if let desk = model.deskLine {
            Text(desk)
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

        Menu("Befristet schalten") {
            ForEach(Self.durations, id: \.minutes) { duration in
                Menu(duration.label) {
                    ForEach(model.settings.knownProfiles, id: \.self) { profile in
                        Button(profile) {
                            Task {
                                await model.send(
                                    profile: profile,
                                    for: TimeInterval(duration.minutes * 60))
                            }
                        }
                    }
                }
            }
        }
        .disabled(model.isSending)

        if let held = model.heldProfile {
            let suffix = model.holdUntil.map { " bis \(Self.time.string(from: $0))" } ?? ""
            Button("„\(held)“ gehalten\(suffix) — Automatik übernehmen lassen") {
                Task { await model.endHold() }
            }
        }

        if !model.history.isEmpty {
            Menu("Verlauf") {
                ForEach(model.history) { record in
                    Text("\(Self.time.string(from: record.at))  \(record.profile)"
                         + "\(record.delivered ? "" : " (fehlgeschlagen)")"
                         + " — \(record.reason)")
                }
            }
        }

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
