import SwiftUI

/// Sechs Tabs statt drei: Vorher lag alles, was kein Konto und kein Profil war,
/// in einem einzigen „Verhalten“-Tab mit acht Abschnitten. Die Gliederung folgt
/// jetzt der Frage, die man beim Öffnen im Kopf hat — nicht der Reihenfolge, in
/// der die Funktionen entstanden sind.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            AccountTab(model: model)
                .tabItem { Label("Konto", systemImage: "person.crop.circle") }
            ProfilesTab(model: model)
                .tabItem { Label("Profile", systemImage: "phone") }
            RulesTab(model: model)
                .tabItem { Label("Regeln", systemImage: "list.bullet") }
            PresenceTab(model: model)
                .tabItem { Label("Anwesenheit", systemImage: "figure.walk") }
            ControlsTab(model: model)
                .tabItem { Label("Bedienung", systemImage: "hand.tap") }
            TimingTab(model: model)
                .tabItem { Label("Zeiten", systemImage: "timer") }
        }
        .frame(width: 580, height: 560)
    }
}

/// Kleinschrift unter einem Abschnitt.
private struct Note: View {
    let lines: [String]
    var warning: String?

    init(_ lines: String..., warning: String? = nil) {
        self.lines = lines
        self.warning = warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Konto

private struct AccountTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Angemeldet als", value: model.accountDescription)

                HStack {
                    if model.isSignedIn {
                        Button("Abmelden") {
                            Task { await model.signOut() }
                        }
                    } else {
                        Button("Bei Microsoft anmelden…") {
                            Task { await model.signIn() }
                        }
                        .disabled(model.settings.tenantId.isEmpty
                                  || model.settings.clientId.isEmpty
                                  || model.authState == .working)
                    }
                    if model.authState == .working {
                        ProgressView().controlSize(.small)
                    }
                }
            } header: {
                Text("Anmeldung")
            } footer: {
                Note("Die App liest ausschließlich die eigene Teams-Präsenz. Der "
                     + "Refresh Token liegt in der Keychain, das Zugriffstoken nur im "
                     + "Arbeitsspeicher. Präsenzdaten verlassen den Rechner nicht.")
            }

            Section {
                Toggle("Gespräch am Telefon setzt den Teams-Status",
                       isOn: $model.settings.setTeamsStatusOnCall)
            } header: {
                Text("Telefonanlage meldet an Teams")
            } footer: {
                Note("Während eines Gesprächs an der Anlage steht dein Teams-Status auf "
                     + "„Beschäftigt“, damit dich niemand parallel dort anruft. Danach "
                     + "wird er freigegeben — Teams bestimmt ihn dann wieder selbst.",
                     "Setzt ein Klick-Konto im AGFEO Dashboard voraus, das auf "
                     + "klick-bridge.sh zeigt. Der Status verfällt nach zwei Stunden von "
                     + "selbst, falls die App vorher abstürzt.",
                     warning: model.teamsStatusProblem)
            }

            Section {
                TextField("Tenant-ID", text: $model.settings.tenantId)
                TextField("Client-ID", text: $model.settings.clientId)
            } header: {
                Text("Entra-Anwendung")
            } footer: {
                Note("Beides sind öffentliche Bezeichner, keine Geheimnisse. Nach einer "
                     + "Änderung ist eine neue Anmeldung nötig.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Profile

private struct ProfilesTab: View {
    @ObservedObject var model: AppModel
    @State private var newProfile = ""

    var body: some View {
        Form {
            Section("Grundprofil") {
                Picker("Grundprofil", selection: $model.settings.baseProfile) {
                    ForEach(model.settings.knownProfiles, id: \.self) { profile in
                        Text(profile).tag(profile)
                    }
                }
                .labelsHidden()
            }

            Section {
                ForEach(Array(model.settings.knownProfiles.enumerated()), id: \.offset) { index, profile in
                    HStack {
                        TextField("Profilname", text: Binding(
                            get: { profile },
                            set: { model.renameProfile(at: index, to: $0) }))
                        Button("Testen") {
                            Task { await model.test(profile: profile) }
                        }
                        .disabled(model.isSending)
                        Button {
                            model.removeProfile(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(profile == model.settings.baseProfile)
                    }
                }

                HStack {
                    TextField("Neues Profil", text: $newProfile)
                        .onSubmit(add)
                    Button("Hinzufügen", action: add)
                        .disabled(newProfile.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Bekannte Profile")
            } footer: {
                Note("Die Namen müssen exakt so geschrieben sein wie in der Anlage. Das "
                     + "Dashboard meldet keine Fehler zurück — „Testen“ schaltet sofort "
                     + "und zeigt Tippfehler jetzt statt beim ersten Anruf.")
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        model.addProfile(newProfile)
        newProfile = ""
    }
}

// MARK: - Regeln

private struct RulesTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach($model.settings.rules) { $rule in
                    RuleRow(rule: $rule, model: model)
                }
                .onMove { model.moveRules(from: $0, to: $1) }

                Button("Regel hinzufügen") { model.addRule() }
            } header: {
                Text("Erste Übereinstimmung gewinnt — Reihenfolge per Ziehen ändern")
            } footer: {
                Note("Trifft keine Regel zu, gilt das Grundprofil.",
                     "„Nicht am Platz“ wird lokal erkannt, ohne Teams. Steht eine "
                     + "Gesprächsregel darüber, gewinnt das Gespräch.")
            }

            Section("Fallstricke") {
                Note("`Busy` eignet sich nicht als Auslöser: Ein reiner Kalendertermin "
                     + "ohne Gespräch liefert genau diesen Wert, ebenso ein von Hand "
                     + "gesetztes „Beschäftigt“. Beides würde umleiten, obwohl niemand "
                     + "telefoniert.",
                     "`InAMeeting` ist aus demselben Grund nicht vorbelegt.",
                     "`Presenting` sollte aktiviert bleiben: Beim Bildschirmteilen "
                     + "ersetzt dieser Wert `InACall` — ohne die Regel fiele das "
                     + "Rufprofil mitten in der Präsentation zurück.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct RuleRow: View {
    @Binding var rule: Rule
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Toggle("", isOn: $rule.enabled)
                .labelsHidden()

            Picker("", selection: $rule.trigger) {
                ForEach(triggerOptions, id: \.self) { trigger in
                    Text(Self.label(for: trigger)).tag(trigger)
                }
            }
            .labelsHidden()

            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)

            Picker("", selection: $rule.profileName) {
                ForEach(profileOptions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()

            Button {
                let id = rule.id
                model.settings.rules.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Der lokale Auslöser steht oben, danach die Graph-Activities. Ein von
    /// Hand eingetragener Wert soll nicht stillschweigend verschwinden, nur
    /// weil er nicht in der Auswahlliste steht.
    private var triggerOptions: [RuleTrigger] {
        var options: [RuleTrigger] = [.awayFromDesk]
        options += GraphActivity.selectable.map { RuleTrigger.activity($0) }
        if !options.contains(rule.trigger) { options.append(rule.trigger) }
        return options
    }

    private var profileOptions: [String] {
        model.settings.knownProfiles.contains(rule.profileName)
            ? model.settings.knownProfiles
            : model.settings.knownProfiles + [rule.profileName]
    }

    /// Activities in exakter Schreibweise — darauf kommt es an. Der lokale
    /// Auslöser hat keinen Graph-Namen und steht deshalb im Klartext da.
    static func label(for trigger: RuleTrigger) -> String {
        switch trigger {
        case .activity(let value): return value
        case .awayFromDesk: return "Nicht am Platz (lokal)"
        }
    }
}

// MARK: - Anwesenheit

/// Wochentage als Reihe von Schaltern. `Calendar` zählt ab Sonntag; die
/// Anzeige beginnt bei dem Tag, den das System als Wochenanfang führt.
private struct WeekdayPicker: View {
    @Binding var days: [Int]

    private var order: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(order, id: \.self) { day in
                Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                    get: { days.contains(day) },
                    set: { isOn in
                        if isOn {
                            if !days.contains(day) { days.append(day) }
                        } else {
                            days.removeAll { $0 == day }
                        }
                        days.sort()
                    }))
                .toggleStyle(.button)
            }
        }
    }
}

private struct PresenceTab: View {
    @ObservedObject var model: AppModel

    /// Übersetzt zwischen „Minuten seit Mitternacht“ und dem `Date`, das
    /// `DatePicker` erwartet. Das Datum selbst ist bedeutungslos.
    private func minuteBinding(_ path: WritableKeyPath<WorkingHours, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = model.settings.workingHours[keyPath: path]
                return Calendar.current.date(
                    bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0,
                    of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.settings.workingHours[keyPath: path] =
                    (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Nur während der Arbeitszeit", isOn: $model.settings.workingHours.enabled)

                if model.settings.workingHours.enabled {
                    WeekdayPicker(days: $model.settings.workingHours.days)
                    DatePicker("Von", selection: minuteBinding(\.startMinute),
                               displayedComponents: .hourAndMinute)
                    DatePicker("Bis", selection: minuteBinding(\.endMinute),
                               displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Arbeitszeit")
            } footer: {
                Note("Außerhalb dieser Zeit wird nichts abgefragt, nichts erkannt und "
                     + "nichts geschaltet. Zum Feierabend geht das Rufprofil einmal auf "
                     + "das Grundprofil zurück, danach ist Ruhe.",
                     model.settings.workingHours.enabled
                        ? "Derzeit: \(model.withinWorkingHours ? "innerhalb" : "außerhalb") der Arbeitszeit."
                        : "Manuelles Schalten aus dem Menü funktioniert jederzeit.")
            }

            Section {
                Toggle("Bildschirmsperre zählt als abwesend",
                       isOn: $model.settings.awayOnScreenLock)
                Toggle("Fehlende Eingaben zählen als abwesend",
                       isOn: $model.settings.awayOnIdle)
                Stepper(value: $model.settings.idleThresholdSeconds, in: 60...3600, step: 60) {
                    Text("Nach \(model.settings.idleThresholdSeconds / 60) min ohne Eingabe")
                }
                .disabled(!model.settings.awayOnIdle)
            } header: {
                Text("Nicht am Platz")
            } footer: {
                Note(model.settings.watchesDesk
                        ? "Derzeit erkannt: \(model.deskLine ?? "am Platz")."
                        : "Wird erst wirksam, wenn im Tab „Regeln“ eine Regel den Auslöser "
                          + "„Nicht am Platz“ benutzt.",
                     "Der Ruhezustand zählt immer als abwesend: Deckel zu heißt weg vom "
                     + "Platz. Die Erkennung läuft lokal und braucht keine Berechtigung.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Bedienung

private struct ControlsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Automatik aktiv", isOn: $model.settings.automationEnabled)
                Toggle("Beim Anmelden starten", isOn: $model.settings.launchAtLogin)
            } footer: {
                Note("Ohne Automatik schaltet nichts von allein; das Menü funktioniert "
                     + "weiter.",
                     warning: model.launchAtLoginProblem.map { "Autostart nicht eingetragen: \($0)" })
            }

            Section {
                Picker("Ein manuell gewähltes Profil", selection: $model.settings.manualMode) {
                    ForEach(ManualMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            } header: {
                Text("Manuelles Schalten")
            } footer: {
                Note("Gilt für die Auswahl unter „Jetzt schalten auf“. Befristetes "
                     + "Schalten hält das Profil unabhängig davon bis zum Ablauf.")
            }

            Section {
                Picker("Kombination", selection: $model.settings.hotKeyChoice) {
                    ForEach(HotKeyChoice.all) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                if model.settings.hotKeyChoice != 0 {
                    Picker("Schaltet auf", selection: $model.settings.hotKeyProfile) {
                        Text("— kein Profil —").tag("")
                        ForEach(model.settings.knownProfiles, id: \.self) { profile in
                            Text(profile).tag(profile)
                        }
                    }
                }
            } header: {
                Text("Tastenkurzbefehl")
            } footer: {
                Note("Ein Druck schaltet auf das gewählte Profil und hält es — die "
                     + "Automatik bleibt so lange außen vor. Ein zweiter Druck gibt sie "
                     + "wieder frei. Wirkt systemweit, ohne Freigabe unter "
                     + "„Bedienungshilfen“.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Zeiten

private struct TimingTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Stepper(value: $model.settings.pollIntervalSeconds, in: 2...60) {
                    Text("Abfrage-Intervall: \(model.settings.pollIntervalSeconds) s")
                }
                Stepper(value: $model.settings.pollIntervalInCallSeconds, in: 1...30) {
                    Text("Während eines Gesprächs: \(model.settings.pollIntervalInCallSeconds) s")
                }
                Stepper(value: $model.settings.resetDelaySeconds, in: 0...60) {
                    Text("Rückschalt-Verzögerung: \(model.settings.resetDelaySeconds) s")
                }
            } header: {
                Text("Abfrage und Rückschaltung")
            } footer: {
                Note("Der begrenzende Faktor beim Zurückschalten ist das Abfrage-"
                     + "Intervall, nicht Microsoft Graph. Wer schneller zurückschalten "
                     + "will, senkt das Intervall während eines Gesprächs — nicht die "
                     + "Rückschalt-Verzögerung.")
            }

            Section {
                Stepper(value: $model.settings.blindTimeoutSeconds, in: 60...3600, step: 60) {
                    Text("Blind-Timeout: \(model.settings.blindTimeoutSeconds / 60) min")
                }
            } header: {
                Text("Unbekannter Status")
            } footer: {
                Note("Ist der Teams-Status länger als diese Zeit unbekannt und ein "
                     + "Regelprofil aktiv, fällt die App einmalig auf das Grundprofil "
                     + "zurück. Sonst bliebe das Telefon umgeleitet, weil das WLAN weg war.")
            }
        }
        .formStyle(.grouped)
    }
}
