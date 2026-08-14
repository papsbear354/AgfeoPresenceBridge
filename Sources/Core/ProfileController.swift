import Foundation

/// Zeitquelle des Controllers. In Tests injiziert, damit die Abnahmekriterien
/// aus SPEC §13 ohne echtes Warten prüfbar sind.
protocol TimeSource: Sendable {
    func now() -> Date
}

struct SystemTimeSource: TimeSource {
    func now() -> Date { Date() }
}

/// Ergebnis eines manuellen Schaltvorgangs.
struct ManualSendOutcome: Equatable, Sendable {
    /// Konnte der Befehl abgesetzt werden? Eine Bestätigung, dass die Anlage
    /// ihn umgesetzt hat, gibt es prinzipbedingt nicht.
    var delivered: Bool
    /// Im Modus `sticky` das neue Grundprofil. Der Aufrufer muss es
    /// persistieren — der Controller schreibt selbst keine Einstellungen.
    var newBaseProfile: String?
}

/// Zustandsautomat aus SPEC §8 — das Herzstück.
///
/// Er kennt genau eine relevante Größe: `lastSentProfile`, das Profil, das die
/// App zuletzt selbst an das Dashboard geschickt hat. Was in der Anlage
/// tatsächlich aktiv ist, kann niemand auslesen.
///
/// Die Rückschalt-Verzögerung ist bewusst kein Timer, sondern ein Vergleich von
/// Zeitstempeln beim jeweils nächsten Poll. Das macht das Verhalten ohne echtes
/// Warten testbar und entspricht der Realität: der begrenzende Faktor ist
/// ohnehin das Poll-Intervall.
///
/// Bewusst frei von AppKit und SwiftUI.
actor ProfileController {
    private let bridge: any ProfileActivating
    private let time: any TimeSource
    /// Zuletzt gesendetes Profil und Grundprofil liegen hier, damit das
    /// Sicherheitsnetz sie beim Einschlafen synchron lesen kann.
    private let safety: SafetyNet

    private(set) var lastSentAt: Date?
    /// Letzter Sendeversuch fehlgeschlagen — speist den Warnzustand des Icons.
    private(set) var lastSendFailed = false

    var lastSentProfile: String? { safety.lastSentProfile }
    var baseProfile: String { safety.baseProfile }

    private var manualMode: ManualMode
    private var automationEnabled: Bool
    private var rules: [Rule]
    private var resetDelay: TimeInterval
    private var blindTimeout: TimeInterval

    /// Beginn der laufenden Blindphase, solange der Status unbekannt ist.
    private(set) var blindSince: Date?
    /// Seit wann steht das Zielprofil durchgehend auf dem Grundprofil?
    private(set) var resetPendingSince: Date?

    /// Zuletzt bekannte Graph-Activity; `nil` heißt, Teams ist offline.
    private var lastKnownActivity: String?
    /// Lokal erkannt, unabhängig von Teams.
    private(set) var awayFromDesk = false

    init(
        bridge: any ProfileActivating,
        time: any TimeSource = SystemTimeSource(),
        settings: Settings,
        safetyNet: SafetyNet? = nil
    ) {
        self.bridge = bridge
        self.time = time
        safety = safetyNet ?? SafetyNet(baseProfile: settings.baseProfile)
        safety.setAwayProfile(settings.awayProfile)
        manualMode = settings.manualMode
        automationEnabled = settings.automationEnabled
        rules = settings.rules
        resetDelay = TimeInterval(settings.resetDelaySeconds)
        blindTimeout = TimeInterval(settings.blindTimeoutSeconds)
    }

    /// Übernimmt geänderte Einstellungen aus dem UI.
    func apply(_ settings: Settings) {
        safety.setBaseProfile(settings.baseProfile)
        safety.setAwayProfile(settings.awayProfile)
        manualMode = settings.manualMode
        automationEnabled = settings.automationEnabled
        rules = settings.rules
        resetDelay = TimeInterval(settings.resetDelaySeconds)
        blindTimeout = TimeInterval(settings.blindTimeoutSeconds)
    }

    /// Steht gerade ein Regelprofil? Steuert das kürzere Poll-Intervall.
    var isOnRuleProfile: Bool {
        guard let lastSentProfile else { return false }
        return lastSentProfile != baseProfile
    }

    // MARK: Automatik

    func handle(_ result: PresenceResult) async {
        // Pausierte Automatik heißt: keinerlei automatisches Senden. Manuelles
        // Schalten aus dem Menü bleibt möglich.
        guard automationEnabled else { return }

        switch result {
        case .presence(_, let activity):
            blindSince = nil
            lastKnownActivity = activity
            await evaluate(reason: "Activity \(activity)")

        case .offline:
            // Teams aus bedeutet real, dass nicht telefoniert wird. Lokale
            // Auslöser können trotzdem greifen.
            blindSince = nil
            lastKnownActivity = nil
            await evaluate(reason: "Teams offline")

        case .unknown(let failure):
            await stayBlind(failure)
        }
    }

    /// Zweiter Eingang neben der Teams-Präsenz: lokal erkannte Abwesenheit.
    ///
    /// Wirkt sofort, nicht erst beim nächsten Poll — eine Bildschirmsperre soll
    /// nicht fünf Sekunden nachhängen.
    func setDeskPresence(_ presence: DeskPresence) async {
        guard awayFromDesk != presence.isAway else { return }
        awayFromDesk = presence.isAway

        switch presence {
        case .away(let reason):
            Log.info(.controller, "Nicht am Platz (\(reason.text))")
        case .atDesk:
            Log.info(.controller, "Wieder am Platz")
        }

        // Während einer Blindphase wird auch hier nicht geschaltet: ob gerade
        // ein Gespräch läuft, ist dann unbekannt — und das entscheidet, welche
        // Regel gewinnt. Der Zustand ist gemerkt und greift beim nächsten
        // bekannten Poll.
        guard automationEnabled, blindSince == nil else { return }
        await evaluate(reason: presence.isAway ? "nicht am Platz" : "wieder am Platz")
    }

    private func evaluate(reason: String) async {
        let engine = RuleEngine(rules: rules, baseProfile: baseProfile)
        let target = engine.targetProfile(
            activity: lastKnownActivity, awayFromDesk: awayFromDesk)
        await aim(at: target, reason: reason)
    }

    private func aim(at target: String, reason: String) async {
        guard target == baseProfile else {
            // Ein Regelprofil greift: sofort schalten, ohne Verzögerung.
            resetPendingSince = nil
            guard lastSentProfile != target else { return }
            await send(target, reason: reason)
            return
        }

        // Zurück auf das Grundprofil, aber erst, wenn der Zustand durchgehend
        // angehalten hat. Kommt zwischendurch wieder ein Treffer, wird der
        // angefangene Zeitraum oben verworfen.
        //
        // Hat die App noch gar nichts gesendet, bleibt sie still: sie weiß dann
        // nicht, was in der Anlage steht, und hat auch nichts zu korrigieren.
        // Ein von Hand am Telefon gesetztes Profil überlebt so einen App-Start.
        guard let lastSent = lastSentProfile, lastSent != baseProfile else {
            resetPendingSince = nil
            return
        }

        let now = time.now()
        guard let since = resetPendingSince else {
            resetPendingSince = now
            return
        }
        guard now.timeIntervalSince(since) >= resetDelay else { return }

        await send(baseProfile, reason: "\(reason), Verzögerung abgelaufen")
        resetPendingSince = nil
    }

    /// Bei unbekanntem Status wird **nicht** geschaltet. Das ist die wichtigste
    /// Regel der ganzen App.
    private func stayBlind(_ failure: PollFailure) async {
        // Ein angefangener Rückschalt-Zeitraum zählt nicht weiter: sonst würde
        // nach einem Netzausfall blind geschaltet.
        resetPendingSince = nil

        let now = time.now()
        guard let since = blindSince else {
            blindSince = now
            return
        }
        guard now.timeIntervalSince(since) >= blindTimeout else { return }
        // Steht bereits das Grundprofil, gibt es nichts zu retten.
        guard let last = lastSentProfile, last != baseProfile else { return }

        let minutes = Int(now.timeIntervalSince(since) / 60)
        Log.notice(.controller, """
            Sicherheitsrückfall: Status seit \(minutes) min unbekannt (\(failure.text)), \
            zurück auf "\(baseProfile)" — sonst bliebe das Telefon umgeleitet
            """)
        await send(baseProfile, reason: "Sicherheitsrückfall nach Blindphase")
    }

    /// Ende der Arbeitszeit: einmal aufräumen, danach schweigen.
    ///
    /// Was die App selbst verstellt hat, wird zurückgenommen — sonst bliebe das
    /// Telefon über Nacht umgeleitet. Anschließend werden die Signalquellen
    /// abgeschaltet, es kommt also ohnehin nichts mehr an.
    func standDown() async {
        resetPendingSince = nil
        blindSince = nil
        lastKnownActivity = nil
        awayFromDesk = false

        guard let lastSent = lastSentProfile, lastSent != baseProfile else { return }
        await send(baseProfile, reason: "Ende der Arbeitszeit")
    }

    // MARK: Manuelles Schalten

    @discardableResult
    func sendManual(profile: String) async -> ManualSendOutcome {
        let delivered = await send(profile, reason: "manuell, Modus \(manualMode.rawValue)")
        var outcome = ManualSendOutcome(delivered: delivered, newBaseProfile: nil)

        // Nach einer manuellen Auswahl darf kein alter Rückschalt-Zeitraum
        // nachwirken.
        resetPendingSince = nil

        guard delivered, manualMode == .sticky, profile != baseProfile else { return outcome }
        safety.setBaseProfile(profile)
        outcome.newBaseProfile = profile
        Log.info(.controller, "Grundprofil wandert auf \"\(profile)\" (Modus sticky)")
        return outcome
    }

    /// Testen-Knopf aus den Einstellungen. Schaltet echt — anders wäre der Test
    /// wertlos — und zählt deshalb auch als zuletzt gesendetes Profil.
    @discardableResult
    func sendTest(profile: String) async -> Bool {
        await send(profile, reason: "Testen-Knopf")
    }

    // MARK: Intern

    @discardableResult
    private func send(_ profile: String, reason: String) async -> Bool {
        Log.info(.controller, "Sende \"\(profile)\" (\(reason))")
        let delivered = await bridge.activate(profile: profile)
        lastSendFailed = !delivered
        guard delivered else { return false }
        safety.recordSent(profile)
        lastSentAt = time.now()
        return true
    }
}
