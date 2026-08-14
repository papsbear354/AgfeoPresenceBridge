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
        .frame(width: 540, height: 460)
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

            Picker("", selection: $rule.activity) {
                ForEach(activityOptions, id: \.self) { Text($0).tag($0) }
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

    /// Ein von Hand eingetragener Wert soll nicht stillschweigend verschwinden,
    /// nur weil er nicht in der Auswahlliste steht.
    private var activityOptions: [String] {
        GraphActivity.selectable.contains(rule.activity)
            ? GraphActivity.selectable
            : GraphActivity.selectable + [rule.activity]
    }

    private var profileOptions: [String] {
        model.settings.knownProfiles.contains(rule.profileName)
            ? model.settings.knownProfiles
            : model.settings.knownProfiles + [rule.profileName]
    }
}

// MARK: - Verhalten

private struct BehaviourTab: View {
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
