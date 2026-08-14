import Foundation

/// Eine Regel des Regelwerks (SPEC §7). Geordnete Liste, erste
/// Übereinstimmung gewinnt.
struct Rule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var enabled: Bool
    /// Graph-Activity in exakter Schreibweise.
    var activity: String
    /// AGFEO-Rufprofil in exakter Schreibweise.
    var profileName: String

    init(id: UUID = UUID(), enabled: Bool = true, activity: String, profileName: String) {
        self.id = id
        self.enabled = enabled
        self.activity = activity
        self.profileName = profileName
    }

    /// Die Voreinstellungen in der Spec führen keine IDs. Fehlt eine, wird sie
    /// beim Laden erzeugt, statt das Laden der ganzen Datei scheitern zu lassen.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        activity = try container.decode(String.self, forKey: .activity)
        profileName = try container.decode(String.self, forKey: .profileName)
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

    /// Auslieferungszustand des Regelwerks.
    ///
    /// `Presenting` gehört zwingend dazu: Teilt man während eines Gesprächs den
    /// Bildschirm, **ersetzt** `Presenting` den Wert `InACall` — Graph liefert
    /// immer nur eine einzige Activity. Ohne diese Regel fiele das Rufprofil
    /// mitten in der Präsentation auf das Grundprofil zurück und das Telefon
    /// klingelte wieder durch (Nachtrag 01 §3).
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
