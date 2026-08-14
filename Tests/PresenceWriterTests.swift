import Foundation
import Testing

@testable import AGFEOPresenceBridge

@Suite("PresenceWriter — Teams-Status setzen")
struct PresenceWriterTests {
    private let network = StubbedNetwork()

    private func writer(_ stub: URLProtocolStub.Stub) -> PresenceWriter {
        PresenceWriter(session: network.session(stub))
    }

    private func body() throws -> [String: String] {
        let data = try #require(network.request?.httpBodyData)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    @Test("Beschäftigt wird mit Verfallszeit gesetzt")
    func setsBusyWithExpiration() async throws {
        let writer = writer(URLProtocolStub.Stub(status: 200))
        #expect(await writer.setBusy(accessToken: "T") == .ok)

        let request = network.request
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.path == "/v1.0/me/presence/setUserPreferredPresence")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer T")

        let sent = try body()
        #expect(sent["availability"] == "Busy")
        // Teams-eigene Werte wie InACall sind hier nicht erlaubt.
        #expect(sent["activity"] == "Busy")
        // Das Sicherheitsnetz, falls die App mitten im Gespräch stirbt.
        #expect(sent["expirationDuration"] == "PT2H")
    }

    @Test("Freigeben ruft den passenden Endpunkt")
    func clearsPreference() async {
        let writer = writer(URLProtocolStub.Stub(status: 200))
        #expect(await writer.clear(accessToken: "T") == .ok)
        #expect(network.request?.url?.path
                == "/v1.0/me/presence/clearUserPreferredPresence")
    }

    @Test("Fehlende Berechtigung wird als solche gemeldet")
    func reportsMissingPermission() async {
        let writer = writer(URLProtocolStub.Stub(status: 403))
        #expect(await writer.setBusy(accessToken: "T") == .forbidden)
    }

    @Test("Andere Fehler werden durchgereicht")
    func reportsOtherFailures() async {
        let writer = writer(URLProtocolStub.Stub(status: 400))
        #expect(await writer.setBusy(accessToken: "T") == .failed("HTTP 400"))
    }

    @Test("Der Scope enthält das Schreibrecht")
    func scopeIncludesWrite() {
        #expect(AuthClient.scope.contains("Presence.ReadWrite"))
        #expect(AuthClient.scope.contains("Presence.Read "))
    }
}

extension URLRequest {
    /// `httpBody` ist bei Anfragen, die durch `URLProtocol` laufen, leer — der
    /// Inhalt steckt dann im Stream.
    var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
