import Foundation
import Testing

@testable import AGFEOPresenceBridge

@Suite("CallEvent — Rückkanal vom AGFEO Klick")
struct CallEventTests {
    private func url(_ query: String) -> URL {
        URL(string: "de.baz.agfeopresence://call?\(query)")!
    }

    /// Genau so kam der Aufruf am 14.08.2026 aus dem Dashboard.
    @Test("Ein echter Gesprächsverlauf wird gelesen")
    func readsRealSequence() throws {
        let uid = "{30d14c62-df06-4260-bcf7-17af08c58bad}:b2a3a6ce"

        let calling = try #require(CallEvent(url: url(
            "state=calling&number=01758288556&outbound=1&uid=\(uid)")))
        #expect(calling.state == .calling)
        #expect(calling.number == "01758288556")
        #expect(calling.isOutbound)
        #expect(!calling.state.isTalking)

        let connected = try #require(CallEvent(url: url("state=connect&number=01758288556&outbound=1&uid=\(uid)")))
        #expect(connected.state.isTalking)

        // Das Ende meldet die Anlage als „finished“, nicht als „disconnect“ —
        // im Programmbinary steht beides.
        let finished = try #require(CallEvent(url: url("state=finished&number=01758288556&outbound=1&uid=\(uid)")))
        #expect(finished.state.endsCall)
        #expect(!finished.state.isTalking)
    }

    @Test("Ein ankommender Ruf wird als solcher erkannt")
    func readsInboundCall() throws {
        let event = try #require(CallEvent(url: url("state=called&number=0521447090&outbound=0&uid=x")))
        #expect(!event.isOutbound)
        #expect(event.state == .called)
        // Es klingelt erst — das ist noch kein Gespräch.
        #expect(!event.state.isTalking)
    }

    @Test("Beide Schreibweisen des Endes zählen")
    func bothEndStatesCount() throws {
        #expect(try #require(CallEvent(url: url("state=disconnect&uid=x"))).state.endsCall)
        #expect(try #require(CallEvent(url: url("state=finished&uid=x"))).state.endsCall)
    }

    @Test("Ein herangeholtes Gespräch zählt als Gespräch")
    func pickupCounts() throws {
        #expect(try #require(CallEvent(url: url("state=pickup&uid=x"))).state.isTalking)
    }

    @Test("Fremde URLs und unbekannte Zustände werden abgewiesen")
    func rejectsForeignURLs() {
        #expect(CallEvent(url: URL(string: "de.baz.agfeopresence://auth?code=x")!) == nil)
        #expect(CallEvent(url: url("state=irgendwas&uid=x")) == nil)
        #expect(CallEvent(url: url("number=123")) == nil)
    }

    @Test("Sonderzeichen in der Rufnummer überstehen die Kodierung")
    func decodesEncodedNumber() throws {
        let event = try #require(CallEvent(url: url("state=connect&number=%2B49521447090&uid=x")))
        #expect(event.number == "+49521447090")
    }
}
