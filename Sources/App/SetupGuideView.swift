import AppKit
import SwiftUI

/// Einrichtung von null an — von der Entra-Anwendung bis zum AGFEO Klick.
///
/// Steht im Programm selbst, weil sie sonst genau dann fehlt, wenn man sie
/// braucht: auf einem fremden Rechner, ohne die Datei, in der sie stünde.
struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    Step(number: 1, title: "Anwendung in Entra registrieren") {
                        Text("Im Azure-Portal unter **Microsoft Entra ID → App-Registrierungen "
                             + "→ Neue Registrierung**:")
                        Bullets([
                            "Ein Name nach Wahl, etwa „AGFEO Presence Bridge“.",
                            "Kontotyp: nur Konten in diesem Organisationsverzeichnis (Single Tenant).",
                            "Plattform: **Mobile Geräte- und Desktopanwendungen**.",
                        ])
                        Copyable(label: "Umleitungs-URI", value: AuthClient.redirectURI)
                        Text("Anschließend unter **Authentifizierung** die Option "
                             + "„Öffentliche Clientflows zulassen“ auf **Ja** stellen. "
                             + "Ohne das schlägt die Anmeldung fehl.")
                    }

                    Step(number: 2, title: "Berechtigungen erteilen") {
                        Text("Unter **API-Berechtigungen** drei delegierte "
                             + "Microsoft-Graph-Berechtigungen hinzufügen:")
                        Bullets([
                            "`Presence.Read` — die eigene Teams-Präsenz lesen. Ohne sie geht nichts.",
                            "`User.Read` — nur für die Anzeige des angemeldeten Benutzers.",
                            "`Presence.ReadWrite` — nur nötig, wenn ein Gespräch am Telefon "
                            + "den Teams-Status setzen soll.",
                        ])
                        Text("Danach **Administratorzustimmung erteilen**. Fehlt sie, "
                             + "erscheint beim ersten Anmelden ein Zustimmungsdialog — oder "
                             + "die Anmeldung wird abgewiesen, je nach Tenant-Richtlinie.")
                    }

                    Step(number: 3, title: "IDs eintragen und anmelden") {
                        Text("Tenant-ID und Client-ID stehen in der Übersicht der "
                             + "Registrierung. Beide sind öffentliche Bezeichner, keine "
                             + "Geheimnisse. Im Tab **Konto** eintragen und anmelden.")
                        Text("Wird eine der IDs später geändert, ist eine neue Anmeldung "
                             + "nötig — ebenso, wenn Berechtigungen hinzukommen.")
                    }

                    Step(number: 4, title: "Rufprofile eintragen") {
                        Text("Im Tab **Profile** die Namen der Rufprofile eintragen, "
                             + "**exakt** so geschrieben wie in der Telefonanlage. Das "
                             + "Dashboard meldet Fehler nicht zurück; der Knopf „Testen“ "
                             + "schaltet sofort und deckt Tippfehler auf.")
                        Text("Danach im Tab **Regeln** festlegen, welcher Zustand auf "
                             + "welches Profil führt. Die Reihenfolge entscheidet: Die "
                             + "erste zutreffende Regel gewinnt.")
                    }

                    Divider()

                    Step(number: 5, title: "Optional: Rückmeldung der Telefonanlage") {
                        Text("Damit ein Gespräch am Festnetz den Teams-Status setzt, "
                             + "braucht es die kostenpflichtige Funktion **AGFEO Klick**. "
                             + "Ohne sie funktioniert alles Übrige unverändert.")
                        Text("Im AGFEO Dashboard unter **Einstellungen → Konten** ein Konto "
                             + "vom Typ **AGFEO Klick** anlegen und dort eintragen:")
                        Copyable(label: "Auszuführendes Programm", value: KlickScript.installedURL.path)
                        Text("Als **Parameter** genau diese vier, in dieser Reihenfolge:")
                        Copyable(label: "Parameter",
                                 value: "%INVOKED_FROM%  %NUMBER%  %OUTBOUND%  %CONNECTION_UID%",
                                 multiline: true)
                        Text("Und die Option **„Automatisch zur Rufverfolgung aufrufen“** "
                             + "einschalten — ohne sie passiert nur etwas, wenn man von "
                             + "Hand auf eine Schaltfläche klickt.")
                        Text("Zuletzt im Tab **Konto** den Schalter „Gespräch am Telefon "
                             + "setzt den Teams-Status“ aktivieren.")
                    }

                    footer
                }
                .padding(26)
            }

            Divider()
            HStack {
                Link("Azure-Portal öffnen",
                     destination: URL(string: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade")!)
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Einrichtung").font(.title2).bold()
            Text("Die Schritte 1 bis 4 sind für den Betrieb nötig, Schritt 5 ist "
                 + "optional. Alles bleibt auf diesem Rechner: Präsenzdaten werden "
                 + "nirgendwohin gesendet.")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Wenn etwas nicht funktioniert").font(.headline)
            Text("Das Protokoll unter „Log anzeigen“ im Menü nennt jeden Statuswechsel, "
                 + "jeden gesendeten Profilbefehl mit Grund und jeden Fehler im Klartext. "
                 + "Es enthält keine Tokens.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Bausteine

private struct Step<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.system(.body, design: .rounded).bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.tint))

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
            }
        }
    }
}

private struct Bullets: View {
    let items: [String]

    init(_ items: [String]) {
        self.items = items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 7) {
                    Text("•")
                    Text(.init(item))
                }
            }
        }
    }
}

/// Wert mit Knopf zum Kopieren — abtippen wäre bei einem Pfad oder einer URI
/// die häufigste Fehlerquelle.
private struct Copyable: View {
    let label: String
    let value: String
    var multiline = false

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(multiline ? nil : 1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(copied ? "Kopiert" : "Kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        }
    }
}
