import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            AccountTab(model: model)
                .tabItem { Label("Konto", systemImage: "person.crop.circle") }
            ProfilesTab(model: model)
                .tabItem { Label("Rufprofile", systemImage: "phone") }
            BehaviourTab(model: model)
                .tabItem { Label("Verhalten", systemImage: "slider.horizontal.3") }
        }
        // Höher als nötig wirkt luftig; zu niedrig versteckt ganze Abschnitte
        // hinter einem Scrollbalken, den im Einstellungsfenster niemand sucht.
        .frame(width: 560, height: 600)
    }
}

// MARK: - Konto

private struct AccountTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                TextField("Tenant-ID", text: $model.settings.tenantId)
                TextField("Client-ID", text: $model.settings.clientId)
            } footer: {
                Text("Beides sind öffentliche Bezeichner der Entra-Anwendung, keine Geheimnisse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
            } footer: {
                Text("Die App liest ausschließlich die eigene Teams-Präsenz. "
                     + "Der Refresh Token liegt in der Keychain, das Zugriffstoken "
                     + "nur im Arbeitsspeicher. Präsenzdaten verlassen den Rechner nicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Rufprofile

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
                Text("Die Namen müssen exakt so geschrieben sein wie in der Anlage. "
                     + "Das Dashboard meldet keine Fehler zurück — „Testen“ schaltet "
                     + "sofort und zeigt damit Tippfehler jetzt statt beim ersten Anruf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach($model.settings.rules) { $rule in
                    RuleRow(rule: $rule, model: model)
                }
                .onMove { model.moveRules(from: $0, to: $1) }

                Button("Regel hinzufügen") { model.addRule() }
            } header: {
                Text("Regeln — erste Übereinstimmung gewinnt")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("„Nicht am Platz“ wird lokal erkannt — über Bildschirmsperre, "
                         + "fehlende Eingaben und den Ruhezustand, ohne Teams. Steht eine "
                         + "Gesprächsregel darüber, gewinnt das Gespräch.")
                    Text("`Busy` nicht als Regel verwenden: ein reiner Kalendertermin ohne "
                         + "Gespräch liefert genau diesen Wert — ebenso ein von Hand "
                         + "gesetztes „Beschäftigt“. Beides würde das Telefon umleiten, "
                         + "obwohl niemand telefoniert.")
                    Text("`InAMeeting` ist aus demselben Grund nicht vorbelegt: Teams setzt "
                         + "das teils allein wegen eines Kalendereintrags.")
                    Text("`Presenting` sollte aktiviert bleiben. Beim Bildschirmteilen "
                         + "ersetzt dieser Wert `InACall` — ohne die Regel fiele das "
                         + "Rufprofil mitten in der Präsentation zurück.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        model.addProfile(newProfile)
        newProfile = ""
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

    /// Activities in exakter Schreibweise — darauf kommt es an. Der lokale
    /// Auslöser hat keinen Graph-Namen und steht deshalb im Klartext da.
    static func label(for trigger: RuleTrigger) -> String {
        switch trigger {
        case .activity(let value): return value
        case .awayFromDesk: return "Nicht am Platz (lokal)"
        }
    }

    private var profileOptions: [String] {
        model.settings.knownProfiles.contains(rule.profileName)
            ? model.settings.knownProfiles
            : model.settings.knownProfiles + [rule.profileName]
    }
}

// MARK: - Verhalten

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

private struct BehaviourTab: View {
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
            // Bewusst ganz oben: das ist der übergeordnete Schalter, alles
            // Weitere gilt nur innerhalb dieses Fensters.
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Außerhalb dieser Zeit wird nichts abgefragt, nichts erkannt und "
                         + "nichts geschaltet. Beim Feierabend geht das Rufprofil einmal "
                         + "auf das Grundprofil zurück, danach ist Ruhe.")
                    Text("Manuelles Schalten aus dem Menü funktioniert weiterhin jederzeit.")
                    if model.settings.workingHours.enabled {
                        Text("Derzeit: \(model.withinWorkingHours ? "innerhalb" : "außerhalb") "
                             + "der Arbeitszeit.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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
                Text("Zeiten")
            } footer: {
                Text("Der begrenzende Faktor beim Zurückschalten ist das Abfrage-Intervall, "
                     + "nicht Microsoft Graph. Wer schneller zurückschalten will, senkt das "
                     + "Intervall während eines Gesprächs — nicht die Rückschalt-Verzögerung.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $model.settings.blindTimeoutSeconds, in: 60...3600, step: 60) {
                    Text("Blind-Timeout: \(model.settings.blindTimeoutSeconds / 60) min")
                }
            } footer: {
                Text("Ist der Teams-Status länger als diese Zeit unbekannt und ein "
                     + "Regelprofil aktiv, fällt die App einmalig auf das Grundprofil "
                     + "zurück. Sonst bliebe das Telefon umgeleitet, weil das WLAN weg war.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                VStack(alignment: .leading, spacing: 4) {
                    if model.settings.watchesDesk {
                        Text("Derzeit erkannt: \(model.deskLine ?? "am Platz").")
                    } else {
                        Text("Wird erst wirksam, wenn im Tab „Rufprofile“ eine Regel den "
                             + "Auslöser „Nicht am Platz“ benutzt.")
                    }
                    Text("Der Ruhezustand zählt immer als abwesend: Deckel zu heißt weg "
                         + "vom Platz. Die Erkennung läuft rein lokal und braucht keine "
                         + "Berechtigung.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Tastenkurzbefehl", selection: $model.settings.hotKeyChoice) {
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
                Text("Ein Druck schaltet auf das gewählte Profil und hält es — die "
                     + "Automatik bleibt so lange außen vor. Ein zweiter Druck gibt sie "
                     + "wieder frei. Funktioniert systemweit und ohne Freigabe unter "
                     + "„Bedienungshilfen“.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Manuelles Schalten") {
                Picker("Ein manuell gewähltes Profil", selection: $model.settings.manualMode) {
                    ForEach(ManualMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Section {
                Toggle("Automatik aktiv", isOn: $model.settings.automationEnabled)
                Toggle("Beim Anmelden starten", isOn: $model.settings.launchAtLogin)
            } footer: {
                if let problem = model.launchAtLoginProblem {
                    Label("Autostart nicht eingetragen: \(problem)",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Der Autostart lässt sich erst eintragen, wenn die App in "
                         + "„/Programme“ liegt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
