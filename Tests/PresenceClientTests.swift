import Foundation
import Testing

@testable import AGFEOPresenceBridge

/// Antwortet anstelle von Graph. Der Vorrat wird vor jedem Test gesetzt,
/// deshalb läuft die Suite seriell.
final class URLProtocolStub: URLProtocol {
    struct Stub {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var error: (any Error)?
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stub = Stub()
        private var lastRequest: URLRequest?

        func set(_ stub: Stub) {
            lock.withLock { self.stub = stub }
        }

        func current() -> Stub {
            lock.withLock { stub }
        }

        func record(_ request: URLRequest) {
            lock.withLock { lastRequest = request }
        }

        func request() -> URLRequest? {
            lock.withLock { lastRequest }
        }
    }

    static let box = Box()

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.box.record(request)
        let stub = Self.box.current()

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("PresenceClient — Antworten und Fehlerfälle", .serialized)
struct PresenceClientTests {
    private func client(_ stub: URLProtocolStub.Stub) -> PresenceClient {
        URLProtocolStub.box.set(stub)
        return PresenceClient(session: URLProtocolStub.makeSession())
    }

    private func json(_ text: String) -> URLProtocolStub.Stub {
        URLProtocolStub.Stub(status: 200, body: Data(text.utf8))
    }

    @Test("Eine gültige Antwort wird gelesen")
    func readsPresence() async {
        let client = client(json(#"{"id":"x","availability":"Busy","activity":"InACall"}"#))
        let result = await client.fetch(accessToken: "token")
        #expect(result == .presence(availability: "Busy", activity: "InACall"))
    }

    @Test("Der Aufruf trägt das Bearer-Token und fragt nur die eigene Präsenz ab")
    func sendsTokenToOwnPresence() async {
        let client = client(json(#"{"availability":"Available","activity":"Available"}"#))
        _ = await client.fetch(accessToken: "GEHEIM")

        let request = URLProtocolStub.box.request()
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer GEHEIM")
        #expect(request?.url?.path == "/v1.0/me/presence")
        // Kein $select: der Endpunkt weist das mit HTTP 400 zurück.
        #expect(request?.url?.query == nil)
    }

    @Test("Zusätzliche Felder der Antwort stören nicht")
    func ignoresExtraFields() async {
        let client = client(json("""
        {"id":"x","availability":"Available","activity":"Available",
         "statusMessage":null,"outOfOfficeSettings":{"isOutOfOffice":false}}
        """))
        let result = await client.fetch(accessToken: "token")
        #expect(result == .presence(availability: "Available", activity: "Available"))
    }

    @Test("401 wird als solches gemeldet, nicht als Serverfehler")
    func reportsUnauthorized() async {
        let client = client(URLProtocolStub.Stub(status: 401))
        #expect(await client.fetch(accessToken: "token") == .unauthorized)
    }

    @Test("429 reicht Retry-After durch")
    func honoursRetryAfter() async {
        let client = client(URLProtocolStub.Stub(status: 429, headers: ["Retry-After": "12"]))
        #expect(await client.fetch(accessToken: "token") == .throttled(retryAfter: 12))
    }

    @Test("429 ohne Retry-After überlässt die Wartezeit dem Backoff")
    func throttledWithoutHeader() async {
        let client = client(URLProtocolStub.Stub(status: 429))
        #expect(await client.fetch(accessToken: "token") == .throttled(retryAfter: nil))
    }

    @Test("5xx wird als Serverfehler gemeldet")
    func reportsServerError() async {
        let client = client(URLProtocolStub.Stub(status: 503))
        #expect(await client.fetch(accessToken: "token") == .serverError(503))
    }

    @Test("Unlesbare Antworten gelten nicht als Status")
    func rejectsGarbage() async {
        let client = client(json("kein json"))
        #expect(await client.fetch(accessToken: "token") == .malformed)
    }

    @Test("Ein Netzwerkfehler ist ein Transportfehler, kein Status")
    func reportsTransportFailure() async {
        let stub = URLProtocolStub.Stub(
            error: URLError(.notConnectedToInternet))
        let client = client(stub)

        if case .transport = await client.fetch(accessToken: "token") {
            // wie erwartet
        } else {
            Issue.record("Netzwerkfehler wurde nicht als Transportfehler gemeldet")
        }
    }
}

@Suite("PresenceClient — Auswertung")
struct PresenceMappingTests {
    @Test("Offline und PresenceUnknown bedeuten beide: telefoniert nicht")
    func offlineMapping() {
        #expect(PresenceClient.result(availability: "Offline", activity: "Offline") == .offline)
        #expect(PresenceClient.result(
            availability: "PresenceUnknown", activity: "PresenceUnknown") == .offline)
    }

    @Test("Ein bekannter Status bleibt erhalten")
    func presenceMapping() {
        #expect(PresenceClient.result(availability: "Busy", activity: "InACall")
                == .presence(availability: "Busy", activity: "InACall"))
    }

    @Test("Retry-After wird nur als Sekundenzahl akzeptiert")
    func retryAfterParsing() {
        #expect(PresenceClient.retryAfter(from: "30") == 30)
        #expect(PresenceClient.retryAfter(from: " 5 ") == 5)
        #expect(PresenceClient.retryAfter(from: nil) == nil)
        #expect(PresenceClient.retryAfter(from: "0") == nil)
        #expect(PresenceClient.retryAfter(from: "Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        // Deckel, damit ein abwegiger Header die App nicht stundenlang stilllegt.
        #expect(PresenceClient.retryAfter(from: "99999") == 300)
    }
}

@Suite("Backoff")
struct BackoffTests {
    @Test("Verdoppelt ab dem Poll-Intervall bis 60 s")
    func doublesToCeiling() {
        var backoff = Backoff(base: 5)
        #expect(backoff.next() == 5)
        #expect(backoff.next() == 10)
        #expect(backoff.next() == 20)
        #expect(backoff.next() == 40)
        #expect(backoff.next() == 60)
        #expect(backoff.next() == 60)
    }

    @Test("Ein erfolgreicher Poll setzt zurück")
    func resets() {
        var backoff = Backoff(base: 5)
        _ = backoff.next()
        _ = backoff.next()
        #expect(backoff.isActive)
        backoff.reset()
        #expect(!backoff.isActive)
        #expect(backoff.next() == 5)
    }
}
