import Foundation
import Testing

@testable import AGFEOPresenceBridge

/// Liefert Token oder wirft — je nachdem, was der Fall verlangt.
final class FakeTokens: TokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _error: (any Error)?
    private var _calls = 0

    init(error: (any Error)? = nil) {
        _error = error
    }

    var calls: Int { lock.withLock { _calls } }

    func setError(_ error: (any Error)?) {
        lock.withLock { _error = error }
    }

    func validAccessToken() async throws -> String {
        try lock.withLock {
            _calls += 1
            if let _error { throw _error }
            return "token"
        }
    }

    func refreshedAccessToken() async throws -> String {
        try await validAccessToken()
    }
}


/// Wartet, bis die Bedingung zutrifft — höchstens `timeout` Sekunden.
///
/// Feste Wartezeiten machen zeitabhängige Tests unter Last unzuverlässig; hier
/// wird nur so lange gewartet, wie tatsächlich nötig.
func waitUntil(
    _ timeout: TimeInterval = 5,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

@Suite("PresencePoller — wann die Abfrage aufgibt")
struct PresencePollerTests {
    private func poller(
        tokens: FakeTokens,
        sink: @escaping PresencePoller.Sink = { _ in }
    ) -> PresencePoller {
        PresencePoller(
            auth: tokens,
            client: PresenceClient(session: StubbedNetwork().session(
                URLProtocolStub.Stub(status: 200,
                    body: Data(#"{"availability":"Available","activity":"Available"}"#.utf8)))),
            normalInterval: 0.05,
            fastInterval: 0.05,
            sink: sink)
    }

    /// Der Fall, der im Betrieb aufgetreten ist: Beim Aufwachen steht das Netz
    /// noch nicht, die Token-Erneuerung scheitert an der Verbindung. Früher
    /// endete die Abfrage daraufhin endgültig und das Rufprofil blieb den
    /// ganzen Tag stehen.
    @Test("Ein Netzwerkfehler beendet die Abfrage nicht")
    func networkFailureKeepsPolling() async throws {
        let tokens = FakeTokens(error: AuthError.transport("Kein Netz"))
        let results = Results()
        let poller = poller(tokens: tokens) { await results.add($0) }

        await poller.start()

        // Mehrfach versucht statt einmal aufgegeben.
        #expect(await waitUntil { tokens.calls > 1 })
        #expect(await results.all.allSatisfy { $0 == .unknown(.network("Kein Netz")) })

        // Und sobald das Netz zurück ist, läuft es ohne Zutun weiter.
        tokens.setError(nil)
        #expect(await waitUntil {
            await results.all.contains(.presence(availability: "Available", activity: "Available"))
        })
        await poller.stop()
    }

    @Test("Eine erloschene Anmeldung beendet die Abfrage")
    func invalidGrantStopsPolling() async throws {
        let tokens = FakeTokens(error: AuthError.invalidGrant)
        let results = Results()
        let poller = poller(tokens: tokens) { await results.add($0) }

        await poller.start()
        #expect(await waitUntil { await results.all.isEmpty == false })

        // Genau ein Versuch, danach Ruhe — hier hilft kein Wiederholen.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(tokens.calls == 1)
        #expect(await results.all == [.unknown(.notSignedIn)])
        await poller.stop()
    }

    @Test("Ohne hinterlegtes Token wird ebenfalls nicht weiterversucht")
    func notSignedInStopsPolling() async throws {
        let tokens = FakeTokens(error: AuthError.notSignedIn)
        let poller = poller(tokens: tokens)

        await poller.start()
        #expect(await waitUntil { tokens.calls == 1 })
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(tokens.calls == 1)
        await poller.stop()
    }

    /// Antwortet der Anmeldedienst mit einem Serverfehler, ist das kein Grund
    /// aufzugeben — der ist morgen wieder da.
    @Test("Ein Serverfehler des Anmeldedienstes beendet die Abfrage nicht")
    func serverErrorKeepsPolling() async throws {
        let tokens = FakeTokens(error: AuthError.server("temporarily_unavailable", nil))
        let poller = poller(tokens: tokens)

        await poller.start()
        #expect(await waitUntil { tokens.calls > 1 })
        await poller.stop()
    }
}

/// Sammelt, was der Poller meldet.
actor Results {
    private(set) var all: [PresenceResult] = []
    func add(_ result: PresenceResult) { all.append(result) }
}
