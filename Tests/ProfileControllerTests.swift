import Foundation
import Testing

@testable import AGFEOPresenceBridge

/// Ersatz für das Dashboard: merkt sich, was gesendet wurde, und kann
/// Fehlschläge simulieren.
final class MockBridge: ProfileActivating, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _succeeds: Bool

    init(succeeds: Bool = true) {
        _succeeds = succeeds
    }

    var sent: [String] {
        lock.withLock { _sent }
    }

    func setSucceeds(_ value: Bool) {
        lock.withLock { _succeeds = value }
    }

    func activate(profile name: String) async -> Bool {
        lock.withLock {
            _sent.append(name)
            return _succeeds
        }
    }
}

/// Stellbare Uhr. Ohne sie wären die Zeitkriterien aus SPEC §13 nur mit echtem
/// Warten prüfbar — und damit langsam und wackelig.
final class TestClock: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { date += seconds }
    }
}

private func makeSettings(
    base: String = "Anwesend",
    mode: ManualMode = .overwrite,
    automation: Bool = true,
    resetDelay: Int = 5,
    blindTimeout: Int = 300
) -> Settings {
    var settings = Settings()
    settings.baseProfile = base
    settings.manualMode = mode
    settings.automationEnabled = automation
    settings.resetDelaySeconds = resetDelay
    settings.blindTimeoutSeconds = blindTimeout
    return settings
}

private let inACall = PresenceResult.presence(availability: "Busy", activity: "InACall")
/// Beim Bildschirmteilen wechselt auch die `availability` — am 14.08.2026 im
/// Betrieb gemessen. Ausgewertet wird nur die Activity.
private let presenting = PresenceResult.presence(
    availability: "DoNotDisturb", activity: "Presenting")
private let available = PresenceResult.presence(availability: "Available", activity: "Available")

@Suite("ProfileController — Automatik")
struct ProfileControllerAutomationTests {
    /// Abnahmekriterium 6: Zehn Polls mit gleichbleibender Activity ergeben
    /// genau einen gesendeten Befehl.
    @Test("Unveränderter Zustand wird nicht erneut gesendet")
    func sendsOnlyOnChange() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        for _ in 0..<10 {
            await controller.handle(inACall)
            clock.advance(5)
        }

        #expect(bridge.sent == ["Meeting"])
    }

    /// Nach dem Start weiß die App nicht, was in der Anlage steht. Sie fasst
    /// sie deshalb erst an, wenn eine Regel greift — ein von Hand am Telefon
    /// gesetztes Profil bleibt so erhalten.
    @Test("Ohne Regeltreffer wird nach dem Start nichts gesendet")
    func staysQuietUntilARuleMatches() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        for _ in 0..<10 {
            await controller.handle(available)
            clock.advance(5)
        }
        await controller.handle(.offline)
        clock.advance(60)
        await controller.handle(.offline)

        #expect(bridge.sent.isEmpty)
        #expect(await controller.lastSentProfile == nil)
    }

    @Test("Nach dem ersten Regeltreffer schaltet die Automatik normal zurück")
    func firstRuleHitEnablesTheReturnPath() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(available)
        clock.advance(30)
        await controller.handle(available)
        #expect(bridge.sent.isEmpty)

        await controller.handle(inACall)
        await controller.handle(available)
        clock.advance(6)
        await controller.handle(available)

        #expect(bridge.sent == ["Meeting", "Anwesend"])
    }

    /// Abnahmekriterium 3: Zwei Anrufe mit 3 s Pause dürfen zwischendurch nicht
    /// auf das Grundprofil zurückschalten.
    @Test("Kurze Gesprächspause schaltet nicht zwischendurch zurück")
    func shortGapDoesNotResetProfile() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(inACall)
        // Pause: kürzer als die Rückschalt-Verzögerung von 5 s.
        clock.advance(3)
        await controller.handle(available)
        clock.advance(3)
        await controller.handle(inACall)

        #expect(bridge.sent == ["Meeting"])
    }

    @Test("Nach dem Auflegen wird erst nach Ablauf der Verzögerung zurückgeschaltet")
    func resetsAfterDelay() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(inACall)
        await controller.handle(available)
        clock.advance(4)
        await controller.handle(available)
        #expect(bridge.sent == ["Meeting"])

        clock.advance(2)
        await controller.handle(available)
        #expect(bridge.sent == ["Meeting", "Anwesend"])
    }

    /// Beim Bildschirmteilen ersetzt `Presenting` den Wert `InACall`. Da beide
    /// auf dasselbe Profil zeigen, darf daraus kein zweiter Befehl entstehen
    /// (Nachtrag 01 §3).
    @Test("Wechsel von InACall auf Presenting sendet nicht erneut")
    func presentingKeepsProfile() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(inACall)
        clock.advance(3)
        await controller.handle(presenting)
        clock.advance(3)
        await controller.handle(inACall)

        #expect(bridge.sent == ["Meeting"])
    }

    @Test("Teams offline führt wie ein Regel-Fehlschlag zurück zum Grundprofil")
    func offlineReturnsToBaseProfile() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(inACall)
        await controller.handle(.offline)
        clock.advance(6)
        await controller.handle(.offline)

        #expect(bridge.sent == ["Meeting", "Anwesend"])
    }

    /// Abnahmekriterium 10: Bei pausierter Automatik wird nichts automatisch
    /// geschaltet, manuelles Schalten funktioniert weiter.
    @Test("Pausierte Automatik schaltet nicht, manuell geht weiter")
    func pausedAutomationStaysQuiet() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(
            bridge: bridge, time: clock, settings: makeSettings(automation: false))

        await controller.handle(inACall)
        clock.advance(10)
        await controller.handle(available)
        #expect(bridge.sent.isEmpty)

        await controller.sendManual(profile: "Meeting")
        #expect(bridge.sent == ["Meeting"])
    }
}

@Suite("ProfileController — unbekannter Status")
struct ProfileControllerBlindTests {
    /// Abnahmekriterium 4: Zehn Sekunden ohne bekannten Status ändern nichts.
    @Test("Unbekannter Status schaltet nicht")
    func unknownDoesNotSwitch() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(inACall)
        for _ in 0..<5 {
            clock.advance(2)
            await controller.handle(.unknown(.network("Netz weg")))
        }

        #expect(bridge.sent == ["Meeting"])
        #expect(await controller.lastSentProfile == "Meeting")
    }

    /// Abnahmekriterium 5: Nach Ablauf des Blind-Timeouts genau ein Rückfall
    /// auf das Grundprofil, danach Ruhe.
    @Test("Nach dem Blind-Timeout genau ein Sicherheitsrückfall")
    func fallsBackOnceAfterBlindTimeout() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(inACall)
        await controller.handle(.unknown(.network("Netz weg")))
        #expect(bridge.sent == ["Meeting"])

        clock.advance(301)
        await controller.handle(.unknown(.network("Netz weg")))
        #expect(bridge.sent == ["Meeting", "Anwesend"])

        // Danach Ruhe, egal wie lange die Blindphase noch dauert.
        for _ in 0..<5 {
            clock.advance(300)
            await controller.handle(.unknown(.network("Netz weg")))
        }
        #expect(bridge.sent == ["Meeting", "Anwesend"])
    }

    @Test("Steht schon das Grundprofil, gibt es keinen Rückfall")
    func noFallbackWhenAlreadyOnBaseProfile() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(.unknown(.http(503)))
        clock.advance(1000)
        await controller.handle(.unknown(.http(503)))

        #expect(bridge.sent.isEmpty)
    }

    /// Sonst würde nach einem Netzausfall blind auf das Grundprofil
    /// geschaltet, obwohl das Gespräch noch läuft.
    @Test("Ein unbekannter Status verwirft den angefangenen Rückschalt-Zeitraum")
    func unknownDiscardsPendingReset() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(inACall)
        await controller.handle(available)
        clock.advance(4)
        await controller.handle(.unknown(.network("Netz weg")))
        clock.advance(4)
        await controller.handle(available)

        // Ohne das Verwerfen wären hier schon 8 s vergangen und es stünde
        // bereits „Anwesend".
        #expect(bridge.sent == ["Meeting"])
    }

    @Test("Ein bekannter Status beendet die Blindphase")
    func knownStatusClearsBlindPhase() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.handle(inACall)
        await controller.handle(.unknown(.network("Netz weg")))
        clock.advance(200)
        await controller.handle(inACall)
        #expect(await controller.blindSince == nil)

        clock.advance(200)
        await controller.handle(.unknown(.network("Netz weg")))
        clock.advance(200)
        await controller.handle(.unknown(.network("Netz weg")))
        // Insgesamt über 300 s unbekannt, aber nicht durchgehend.
        #expect(bridge.sent == ["Meeting"])
    }
}

@Suite("ProfileController — manuelles Schalten")
struct ProfileControllerManualTests {
    @Test("Ein manuelles Profil wird gesendet und als zuletzt gesendet vermerkt")
    func sendsAndRecords() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        let outcome = await controller.sendManual(profile: "Meeting")

        #expect(outcome.delivered)
        #expect(bridge.sent == ["Meeting"])
        #expect(await controller.lastSentProfile == "Meeting")
        #expect(await controller.lastSentAt == clock.now())
        #expect(await controller.lastSendFailed == false)
    }

    /// Abnahmekriterium 12: im Modus `overwrite` überschreibt die Automatik die
    /// manuelle Auswahl beim nächsten Zyklus.
    @Test("overwrite wird nach dem Anrufzyklus überschrieben")
    func overwriteIsReplacedByAutomation() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        await controller.sendManual(profile: "Zuhause")
        #expect(await controller.baseProfile == "Anwesend")

        await controller.handle(available)
        clock.advance(6)
        await controller.handle(available)

        #expect(bridge.sent == ["Zuhause", "Anwesend"])
    }

    /// Abnahmekriterium 11: im Modus `sticky` überlebt die manuelle Auswahl
    /// einen kompletten Anrufzyklus.
    @Test("sticky überlebt einen kompletten Anrufzyklus")
    func stickySurvivesCallCycle() async {
        let bridge = MockBridge()
        let clock = TestClock()
        var settings = makeSettings(mode: .sticky)
        let controller = ProfileController(bridge: bridge, time: clock, settings: settings)

        let outcome = await controller.sendManual(profile: "Zuhause")
        #expect(outcome.newBaseProfile == "Zuhause")

        // So zieht die App die Änderung nach: sie persistiert das neue
        // Grundprofil und reicht die Einstellungen zurück.
        settings.baseProfile = "Zuhause"
        await controller.apply(settings)

        await controller.handle(inACall)
        clock.advance(3)
        await controller.handle(available)
        clock.advance(6)
        await controller.handle(available)

        #expect(bridge.sent == ["Zuhause", "Meeting", "Zuhause"])
    }

    @Test("sticky auf das bereits gesetzte Grundprofil meldet keine Änderung")
    func stickyOnSameProfileIsNoChange() async {
        let bridge = MockBridge()
        let controller = ProfileController(
            bridge: bridge, time: TestClock(), settings: makeSettings(mode: .sticky))

        let outcome = await controller.sendManual(profile: "Anwesend")

        #expect(outcome.delivered)
        #expect(outcome.newBaseProfile == nil)
    }

    @Test("Ein fehlgeschlagener Befehl verändert den bekannten Zustand nicht")
    func failedSendKeepsState() async {
        let bridge = MockBridge(succeeds: false)
        let controller = ProfileController(
            bridge: bridge, time: TestClock(), settings: makeSettings(mode: .sticky))

        let outcome = await controller.sendManual(profile: "Meeting")

        #expect(outcome.delivered == false)
        #expect(outcome.newBaseProfile == nil)
        // Ob die Anlage geschaltet hat, weiß niemand — also nichts behaupten.
        #expect(await controller.lastSentProfile == nil)
        #expect(await controller.baseProfile == "Anwesend")
        #expect(await controller.lastSendFailed)
    }

    @Test("Der Testen-Knopf schaltet echt und zählt als zuletzt gesendet")
    func testButtonCountsAsSend() async {
        let bridge = MockBridge()
        let controller = ProfileController(
            bridge: bridge, time: TestClock(), settings: makeSettings())

        let delivered = await controller.sendTest(profile: "Büro & Mobil")

        #expect(delivered)
        #expect(bridge.sent == ["Büro & Mobil"])
        #expect(await controller.lastSentProfile == "Büro & Mobil")
    }

    @Test("Ein Regelprofil steuert das kürzere Poll-Intervall")
    func reportsRuleProfileState() async {
        let bridge = MockBridge()
        let clock = TestClock()
        let controller = ProfileController(bridge: bridge, time: clock, settings: makeSettings())

        #expect(await controller.isOnRuleProfile == false)
        await controller.handle(inACall)
        #expect(await controller.isOnRuleProfile)

        await controller.handle(available)
        clock.advance(6)
        await controller.handle(available)
        #expect(await controller.isOnRuleProfile == false)
    }
}

@Suite("RuleEngine")
struct RuleEngineTests {
    private let engine = RuleEngine(
        rules: [
            Rule(activity: "InACall", profileName: "Meeting"),
            Rule(enabled: false, activity: "InAMeeting", profileName: "Kalender"),
            Rule(activity: "Presenting", profileName: "Präsentation"),
            Rule(activity: "InACall", profileName: "Nie erreicht"),
        ],
        baseProfile: "Anwesend")

    @Test("Die erste passende Regel gewinnt")
    func firstMatchWins() {
        #expect(engine.targetProfile(for: "InACall") == "Meeting")
    }

    @Test("Deaktivierte Regeln werden übersprungen")
    func disabledRulesAreSkipped() {
        #expect(engine.targetProfile(for: "InAMeeting") == "Anwesend")
    }

    @Test("Ohne Treffer gilt das Grundprofil")
    func fallsBackToBaseProfile() {
        #expect(engine.targetProfile(for: "Available") == "Anwesend")
        #expect(engine.targetProfile(for: "Irgendwas") == "Anwesend")
    }

    @Test("Verglichen wird exakt")
    func matchesExactly() {
        #expect(engine.targetProfile(for: "inacall") == "Anwesend")
        #expect(engine.targetProfile(for: "Presenting") == "Präsentation")
    }
}
