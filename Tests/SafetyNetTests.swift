import Foundation
import Testing

@testable import AGFEOPresenceBridge

@Suite("SafetyNet — synchroner Rückfall")
struct SafetyNetTests {
    @Test("Ohne gesendetes Profil gibt es nichts zurückzuschalten")
    func nothingToResetInitially() {
        let net = SafetyNet(baseProfile: "Anwesend")
        #expect(net.profileNeeded(for: .shutdown) == nil)
        #expect(net.profileNeeded(for: .sleep) == nil)
    }

    @Test("Steht das Grundprofil, gibt es nichts zurückzuschalten")
    func nothingToResetOnBaseProfile() {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.recordSent("Anwesend")
        #expect(net.profileNeeded(for: .shutdown) == nil)
    }

    /// Abnahmekriterien 7 und 8: Ruhezustand oder Beenden während eines
    /// Gesprächs muss das Grundprofil noch senden.
    @Test("Steht ein Regelprofil, wird das Grundprofil gemeldet")
    func reportsBaseProfileWhileOnRuleProfile() {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.recordSent("Meeting")
        #expect(net.profileNeeded(for: .shutdown) == "Anwesend")
    }

    @Test("Nach dem Rückfall ist Ruhe")
    func quietAfterFallback() {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.recordSent("Meeting")
        net.recordSent(net.profileNeeded(for: .shutdown)!)
        #expect(net.profileNeeded(for: .shutdown) == nil)
    }

    @Test("Ein verschobenes Grundprofil wird berücksichtigt")
    func followsMovedBaseProfile() {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.recordSent("Zuhause")
        #expect(net.profileNeeded(for: .shutdown) == "Anwesend")

        // Modus `sticky`: das manuell gewählte Profil wird zum Grundprofil.
        net.setBaseProfile("Zuhause")
        #expect(net.profileNeeded(for: .shutdown) == nil)
    }

    @Test("Der Controller schreibt seinen Zustand synchron lesbar mit")
    func controllerKeepsSafetyNetCurrent() async {
        let net = SafetyNet(baseProfile: "Anwesend")
        var settings = Settings()
        settings.baseProfile = "Anwesend"
        let controller = ProfileController(
            bridge: MockBridge(), time: TestClock(), settings: settings, safetyNet: net)

        await controller.handle(.presence(availability: "Busy", activity: "InACall"))

        // Ohne `await` — genau darauf kommt es beim Einschlafen an.
        #expect(net.lastSentProfile == "Meeting")
        #expect(net.profileNeeded(for: .shutdown) == "Anwesend")
    }
}

@Suite("SafetyNet — Ruhezustand gilt als abwesend")
struct SafetyNetSleepTests {
    private func net(away: String?) -> SafetyNet {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.setAwayProfile(away)
        return net
    }

    /// Deckel zu heißt weg vom Platz — das ist ein eigener Auslöser und nicht
    /// bloß ein Zurücknehmen. Deshalb auch dann, wenn die App noch nichts
    /// gesendet hat.
    @Test("Einschlafen schaltet auf das Abwesenheitsprofil")
    func sleepUsesAwayProfile() {
        let net = net(away: "Abwesend")
        #expect(net.profileNeeded(for: .sleep) == "Abwesend")

        net.recordSent("Meeting")
        #expect(net.profileNeeded(for: .sleep) == "Abwesend")
    }

    @Test("Steht das Abwesenheitsprofil schon, passiert nichts")
    func sleepIsIdempotent() {
        let net = net(away: "Abwesend")
        net.recordSent("Abwesend")
        #expect(net.profileNeeded(for: .sleep) == nil)
    }

    /// Nach dem Herunterfahren kann die App nichts mehr korrigieren — dann
    /// bliebe das Telefon auf Dauer aufs Handy umgeleitet.
    @Test("Herunterfahren geht trotzdem auf das Grundprofil")
    func shutdownStillUsesBaseProfile() {
        let net = net(away: "Abwesend")
        net.recordSent("Meeting")
        #expect(net.profileNeeded(for: .shutdown) == "Anwesend")
    }

    @Test("Ohne Abwesenheitsregel bleibt es beim bisherigen Verhalten")
    func withoutAwayRuleNothingChanges() {
        let net = net(away: nil)
        #expect(net.profileNeeded(for: .sleep) == nil)

        net.recordSent("Meeting")
        #expect(net.profileNeeded(for: .sleep) == "Anwesend")
    }
}
