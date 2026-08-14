import Foundation
import Testing

@testable import AGFEOPresenceBridge

@Suite("Settings — Voreinstellungen und Laden")
struct SettingsTests {
    @Test("Auslieferungszustand entspricht der Spec")
    func defaults() {
        let settings = Settings()
        #expect(settings.baseProfile == "Anwesend")
        #expect(settings.knownProfiles == ["Anwesend", "Meeting"])
        #expect(settings.pollIntervalSeconds == 5)
        #expect(settings.pollIntervalInCallSeconds == 3)
        #expect(settings.resetDelaySeconds == 5)
        #expect(settings.blindTimeoutSeconds == 300)
        #expect(settings.manualMode == .overwrite)
        #expect(settings.rules.map(\.activity) == ["InACall", "InAConferenceCall", "Presenting"])
        #expect(settings.rules.allSatisfy { $0.enabled && $0.profileName == "Meeting" })
    }

    /// Die Voreinstellungen in der Spec führen keine Regel-IDs.
    @Test("Regeln ohne id bekommen beim Laden eine eigene")
    func decodesRulesWithoutIDs() throws {
        let json = """
        { "rules": [
            { "enabled": true, "activity": "InACall", "profileName": "Meeting" },
            { "enabled": true, "activity": "Presenting", "profileName": "Meeting" }
        ] }
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        #expect(settings.rules.count == 2)
        #expect(Set(settings.rules.map(\.id)).count == 2)
    }

    @Test("Fehlende Felder fallen auf die Voreinstellung zurück")
    func partialFileKeepsDefaults() throws {
        let json = """
        { "baseProfile": "Homeoffice", "resetDelaySeconds": 12 }
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

        #expect(settings.baseProfile == "Homeoffice")
        #expect(settings.resetDelaySeconds == 12)
        #expect(settings.pollIntervalSeconds == 5)
        #expect(settings.rules.count == 3)
        #expect(settings.clientId == Settings().clientId)
    }

    @Test("Schreiben und Lesen ergibt denselben Stand")
    func roundTrip() throws {
        var settings = Settings()
        settings.knownProfiles = ["Anwesend", "Meeting", "Büro & Mobil"]
        settings.baseProfile = "Büro & Mobil"
        settings.manualMode = .sticky
        settings.rules.append(Rule(activity: "InAMeeting", profileName: "Meeting"))

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)

        #expect(decoded == settings)
    }

    @Test("Offline und PresenceUnknown stehen nicht zur Auswahl")
    func pickerOmitsPollerHandledValues() {
        #expect(!GraphActivity.selectable.contains("Offline"))
        #expect(!GraphActivity.selectable.contains("PresenceUnknown"))
        #expect(GraphActivity.selectable.contains("InAMeeting"))
        #expect(GraphActivity.selectable.contains("Presenting"))
    }
}
