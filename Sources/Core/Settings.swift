import Foundation

/// Was eine Regel auslöst.
///
/// In der Datei steht ein einzelner String: entweder eine Graph-Activity oder
/// ein Auslöser mit `local:`-Präfix. Ein Graph-Wert kann keinen Doppelpunkt
/// enthalten, die beiden können sich also nicht in die Quere kommen.
enum RuleTrigger: Equatable, Hashable, Sendable, Codable {
    /// Graph-Activity in exakter Schreibweise.
    case activity(String)
    /// Lokal erkannt: Bildschirm gesperrt, keine Eingabe oder Ruhezustand.
    case awayFromDesk

    static let awayToken = "local:awayFromDesk"

    init(rawValue: String) {
        self = rawValue == Self.awayToken ? .awayFromDesk : .activity(rawValue)
    }

    var rawValue: String {
        switch self {
        case .activity(let value): return value
        case .awayFromDesk: return Self.awayToken
        }
    }

    /// Beschriftung für die Oberfläche.
    var label: String {
        switch self {
        case .activity(let value): return GraphActivity.label(for: value)
        case .awayFromDesk: return "Nicht am Platz (lokal erkannt)"
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Eine Regel des Regelwerks (SPEC §7). Geordnete Liste, erste
/// Übereinstimmung gewinnt.
struct Rule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var enabled: Bool
    var trigger: RuleTrigger
    /// AGFEO-Rufprofil in exakter Schreibweise.
    var profileName: String

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        trigger: RuleTrigger,
        profileName: String
    ) {
        self.id = id
        self.enabled = enabled
        self.trigger = trigger
        self.profileName = profileName
    }

    init(id: UUID = UUID(), enabled: Bool = true, activity: String, profileName: String) {
        self.init(id: id, enabled: enabled, trigger: .activity(activity), profileName: profileName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, enabled, trigger, activity, profileName
    }

    /// Fehlt eine ID, wird sie erzeugt, statt das Laden der ganzen Datei
    /// scheitern zu lassen. Ältere Dateien führen statt `trigger` ein Feld
    /// `activity` — das wird weiterhin gelesen.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        profileName = try container.decode(String.self, forKey: .profileName)
        if let trigger = try container.decodeIfPresent(RuleTrigger.self, forKey: .trigger) {
            self.trigger = trigger
        } else {
            trigger = .activity(try container.decode(String.self, forKey: .activity))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(profileName, forKey: .profileName)
    }
}

enum GraphActivity {
    /// Auswählbare Activities im Regel-Editor.
    ///
    /// `Offline` und `PresenceUnknown` fehlen bewusst: der Poller bildet beide
    /// auf den Fall `.offline` ab, bevor das Regelwerk überhaupt greift (SPEC
    /// §6). Eine Regel darauf könnte nie auslösen und würde stumm nichts tun.
    static let selectable = [
        "Available",
        "Away",
        "BeRightBack",
        "Busy",
        "DoNotDisturb",
        "InACall",
        "InAConferenceCall",
        "Inactive",
        "InAMeeting",
        "OffWork",
        "OutOfOffice",
        "Presenting",
        "UrgentInterruptionsOnly",
    ]

    /// Deutsche Bezeichnung für die Anzeige. Der rohe Graph-Wert steht in der
    /// Oberfläche immer daneben — beim Beobachten zählt er, nicht die
    /// Übersetzung.
    static func label(for activity: String) -> String {
        switch activity {
        case "Available": return "Verfügbar"
        case "Away": return "Abwesend"
        case "BeRightBack": return "Bin gleich zurück"
        case "Busy": return "Beschäftigt"
        case "DoNotDisturb": return "Nicht stören"
        case "InACall": return "Im Gespräch"
        case "InAConferenceCall": return "In einer Telefonkonferenz"
        case "Inactive": return "Inaktiv"
        case "InAMeeting": return "In einer Besprechung"
        case "Offline": return "Offline"
        case "OffWork": return "Nicht im Dienst"
        case "OutOfOffice": return "Außer Haus"
        case "PresenceUnknown": return "Unbekannt"
        case "Presenting": return "Präsentiert"
        case "UrgentInterruptionsOnly": return "Nur dringende Unterbrechungen"
        default: return activity
        }
    }
}

/// Verhalten beim manuellen Schalten aus dem Menü (SPEC §8).
enum ManualMode: String, Codable, CaseIterable, Sendable {
    /// Gewähltes Profil wird gesendet, das Grundprofil bleibt unverändert.
    /// Die Automatik überschreibt die Auswahl beim nächsten Zyklus.
    case overwrite
    /// Gewähltes Profil wird zusätzlich zum neuen Grundprofil und überlebt
    /// damit den nächsten Anruf.
    case sticky

    var label: String {
        switch self {
        case .overwrite: return "Von der Automatik überschreibbar"
        case .sticky: return "Wird zum neuen Grundprofil"
        }
    }
}

/// Persistente Einstellungen (SPEC §10, Werte aus Nachtrag 01).
struct Settings: Codable, Equatable, Sendable {
    /// Öffentliche Bezeichner der Entra-App, keine Geheimnisse (Nachtrag 01 §1).
    var tenantId: String = "0d35eefe-cb7b-4411-af1e-cab10f60e02f"
    var clientId: String = "80f6f821-c617-4d54-8775-101394c0fbee"

    var baseProfile: String = "Anwesend"
    var knownProfiles: [String] = ["Anwesend", "Meeting"]
    var rules: [Rule] = Settings.defaultRules

    // MARK: Zeitkonstanten
    //
    // Der begrenzende Faktor beim Zurückschalten ist das Poll-Intervall, nicht
    // die Graph-Latenz: die Präsenz folgt Gesprächsbeginn und -ende nahezu
    // unmittelbar (Nachtrag 01 §4). Wer schneller zurückschalten will, senkt
    // `pollIntervalInCallSeconds` — nicht `resetDelaySeconds`.

    var pollIntervalSeconds: Int = 5
    /// Während ein Regelprofil aktiv ist, damit das Zurückschalten schneller kommt.
    var pollIntervalInCallSeconds: Int = 3
    /// Verhindert nur noch, dass das Profil bei zwei direkt aufeinander
    /// folgenden Anrufen kurz hin- und herspringt.
    var resetDelaySeconds: Int = 5
    /// Nach so langer Blindphase (`.unknown`) fällt die App einmalig auf das
    /// Grundprofil zurück, damit das Telefon nicht umgeleitet bleibt.
    var blindTimeoutSeconds: Int = 300

    var manualMode: ManualMode = .overwrite
    var automationEnabled: Bool = true
    var launchAtLogin: Bool = true

    // MARK: Abwesenheit am Platz
    //
    // Wird nur überwacht, wenn eine aktive Regel den Auslöser „Nicht am Platz“
    // benutzt. Ohne solche Regel läuft nichts davon.

    /// Bildschirmsperre gilt sofort als abwesend, Entsperren sofort als zurück.
    var awayOnScreenLock: Bool = true
    /// Keine Tastatur- oder Mauseingabe für die eingestellte Dauer.
    var awayOnIdle: Bool = true
    var idleThresholdSeconds: Int = 600

    /// Zeitfenster, in dem die Automatik überhaupt arbeitet.
    var workingHours = WorkingHours()

    // MARK: Tastenkurzbefehl
    //
    // Schaltet auf ein festes Profil und hält es, bis dieselbe Taste erneut
    // gedrückt wird. Gedacht für „ich bin gleich zurück“, ohne die Menüleiste
    // anzusteuern.

    /// Nummer aus `HotKeyChoice`; 0 heißt: kein Kurzbefehl.
    var hotKeyChoice: Int = 0
    /// Profil, auf das der Kurzbefehl schaltet. Leer heißt: aus.
    var hotKeyProfile: String = ""

    /// Auslieferungszustand des Regelwerks.
    ///
    /// `Presenting` gehört zwingend dazu: Teilt man während eines Gesprächs den
    /// Bildschirm, **ersetzt** `Presenting` den Wert `InACall` — Graph liefert
    /// immer nur eine einzige Activity. Ohne diese Regel fiele das Rufprofil
    /// mitten in der Präsentation auf das Grundprofil zurück und das Telefon
    /// klingelte wieder durch (Nachtrag 01 §3).
    ///
    /// Am 14.08.2026 im Betrieb bestätigt: `Busy` / `InACall` wechselt beim
    /// Teilen auf `DoNotDisturb` / `Presenting` und danach zurück. Die
    /// `availability` wechselt also mit — ausgewertet wird trotzdem nur die
    /// Activity.
    ///
    /// `InAMeeting` ist bewusst nicht vorbelegt: Teams setzt das häufig allein
    /// wegen eines Kalendereintrags, auch ohne laufendes Gespräch.
    ///
    /// Gemessen am 14.08.2026 im Zieltenant: ein reiner Kalendertermin ohne
    /// Gespräch liefert `Busy` / `Busy` — nicht `InAMeeting`, wie ursprünglich
    /// angenommen. Die gefährliche Regel ist hier also `Busy`; sie würde bei
    /// jedem Termin und bei jedem von Hand gesetzten „Beschäftigt“ umleiten.
    static let defaultRules: [Rule] = [
        Rule(activity: "InACall", profileName: "Meeting"),
        Rule(activity: "InAConferenceCall", profileName: "Meeting"),
        Rule(activity: "Presenting", profileName: "Meeting"),
    ]

    init() {}

    /// Jedes Feld einzeln mit Rückfall auf die Voreinstellung, damit eine
    /// ältere oder von Hand gekürzte Datei nicht das ganze Laden verhindert.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        tenantId = try c.decodeIfPresent(String.self, forKey: .tenantId) ?? d.tenantId
        clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? d.clientId
        baseProfile = try c.decodeIfPresent(String.self, forKey: .baseProfile) ?? d.baseProfile
        knownProfiles = try c.decodeIfPresent([String].self, forKey: .knownProfiles) ?? d.knownProfiles
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? d.rules
        pollIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? d.pollIntervalSeconds
        pollIntervalInCallSeconds = try c.decodeIfPresent(Int.self, forKey: .pollIntervalInCallSeconds) ?? d.pollIntervalInCallSeconds
        resetDelaySeconds = try c.decodeIfPresent(Int.self, forKey: .resetDelaySeconds) ?? d.resetDelaySeconds
        blindTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .blindTimeoutSeconds) ?? d.blindTimeoutSeconds
        manualMode = try c.decodeIfPresent(ManualMode.self, forKey: .manualMode) ?? d.manualMode
        automationEnabled = try c.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? d.automationEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        awayOnScreenLock = try c.decodeIfPresent(Bool.self, forKey: .awayOnScreenLock) ?? d.awayOnScreenLock
        awayOnIdle = try c.decodeIfPresent(Bool.self, forKey: .awayOnIdle) ?? d.awayOnIdle
        idleThresholdSeconds = try c.decodeIfPresent(Int.self, forKey: .idleThresholdSeconds) ?? d.idleThresholdSeconds
        workingHours = try c.decodeIfPresent(WorkingHours.self, forKey: .workingHours) ?? d.workingHours
        hotKeyChoice = try c.decodeIfPresent(Int.self, forKey: .hotKeyChoice) ?? d.hotKeyChoice
        hotKeyProfile = try c.decodeIfPresent(String.self, forKey: .hotKeyProfile) ?? d.hotKeyProfile
    }

    /// Ist ein Kurzbefehl vollständig eingerichtet?
    var hasHotKey: Bool {
        hotKeyChoice != 0 && !hotKeyProfile.isEmpty
    }

    /// Wird der Auslöser „Nicht am Platz“ überhaupt gebraucht? Ohne aktive
    /// Regel wird nichts überwacht.
    var watchesDesk: Bool {
        rules.contains { $0.enabled && $0.trigger == .awayFromDesk }
    }

    /// Profil der ersten aktiven Abwesenheitsregel — das Ziel beim Einschlafen.
    var awayProfile: String? {
        rules.first { $0.enabled && $0.trigger == .awayFromDesk }?.profileName
    }
}

/// Laden und atomares Schreiben von `Settings.json`.
enum SettingsStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("de.baz.agfeopresence", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("Settings.json")
    }

    /// Liest die Datei. Existiert sie nicht oder ist sie unlesbar, gelten die
    /// Voreinstellungen — die App startet in jedem Fall.
    static func load() -> Settings {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.info(.settings, "Keine Einstellungsdatei gefunden, Voreinstellungen aktiv")
            return Settings()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            Log.error(.settings, "Einstellungen konnten nicht gelesen werden: \(error.localizedDescription)")
            return Settings()
        }
    }

    static func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }
}
