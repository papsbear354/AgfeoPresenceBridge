import Foundation
import Testing

@testable import AGFEOPresenceBridge

@Suite("AgfeoBridge — URL-Aufbau")
struct AgfeoBridgeTests {
    /// Abnahmekriterium 14: Profilnamen mit Leerzeichen und Umlaut.
    @Test("Leerzeichen und Umlaute werden prozentkodiert")
    func encodesSpacesAndUmlauts() throws {
        let url = try #require(AgfeoBridge.makeURL(profile: "Büro Mobil"))
        #expect(url.absoluteString == "adashboard:activate_call_profile?name=B%C3%BCro%20Mobil")
    }

    /// `&`, `=` und `+` sind in `.urlQueryAllowed` erlaubt und würden den
    /// Parameter zerlegen bzw. verfälschen.
    @Test("Query-Trennzeichen im Profilnamen werden kodiert")
    func encodesQuerySeparators() throws {
        let url = try #require(AgfeoBridge.makeURL(profile: "Büro & Mobil"))
        #expect(url.absoluteString == "adashboard:activate_call_profile?name=B%C3%BCro%20%26%20Mobil")

        let plus = try #require(AgfeoBridge.makeURL(profile: "A+B"))
        #expect(plus.absoluteString == "adashboard:activate_call_profile?name=A%2BB")
    }

    @Test("Ein einfacher Name bleibt unverändert")
    func plainNameStaysReadable() throws {
        let url = try #require(AgfeoBridge.makeURL(profile: "Meeting"))
        #expect(url.absoluteString == "adashboard:activate_call_profile?name=Meeting")
        #expect(url.scheme == "adashboard")
    }

    @Test("Ein leerer Name ergibt keine URL")
    func emptyNameIsRejected() {
        #expect(AgfeoBridge.makeURL(profile: "") == nil)
    }
}
