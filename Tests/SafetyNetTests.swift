import Foundation
import Testing

@testable import AGFEOPresenceBridge

@Suite("SafetyNet — synchroner Rückfall")
struct SafetyNetTests {
    @Test("Ohne gesendetes Profil gibt es nichts zurückzuschalten")
    func nothingToResetInitially() {
        let net = SafetyNet(baseProfile: "Anwesend")
        #expect(net.profileNeedingReset() == nil)
    }

    @Test("Steht das Grundprofil, gibt es nichts zurückzuschalten")
    func nothingToResetOnBaseProfile() {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.recordSent("Anwesend")
        #expect(net.profileNeedingReset() == nil)
    }

    /// Abnahmekriterien 7 und 8: Ruhezustand oder Beenden während eines
    /// Gesprächs muss das Grundprofil noch senden.
    @Test("Steht ein Regelprofil, wird das Grundprofil gemeldet")
    func reportsBaseProfileWhileOnRuleProfile() {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.recordSent("Meeting")
        #expect(net.profileNeedingReset() == "Anwesend")
    }

    @Test("Nach dem Rückfall ist Ruhe")
    func quietAfterFallback() {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.recordSent("Meeting")
        net.recordSent(net.profileNeedingReset()!)
        #expect(net.profileNeedingReset() == nil)
    }

    @Test("Ein verschobenes Grundprofil wird berücksichtigt")
    func followsMovedBaseProfile() {
        let net = SafetyNet(baseProfile: "Anwesend")
        net.recordSent("Zuhause")
        #expect(net.profileNeedingReset() == "Anwesend")

        // Modus `sticky`: das manuell gewählte Profil wird zum Grundprofil.
        net.setBaseProfile("Zuhause")
        #expect(net.profileNeedingReset() == nil)
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
        #expect(net.profileNeedingReset() == "Anwesend")
    }
}
