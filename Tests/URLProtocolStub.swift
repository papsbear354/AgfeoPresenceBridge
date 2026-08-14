import Foundation

/// Antwortet anstelle des Netzes.
///
/// Jeder Test bekommt über einen eigenen Kopfzeileneintrag seinen eigenen
/// Eintrag in der Registrierung. Ein einzelner globaler Zustand hätte sich
/// zwischen parallel laufenden Suiten gegenseitig überschrieben — `.serialized`
/// wirkt nur innerhalb einer Suite, nicht zwischen ihnen.
final class URLProtocolStub: URLProtocol {
    struct Stub {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var error: (any Error)?
    }

    private static let header = "X-Stub-Id"

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [String: Stub] = [:]
        private var requests: [String: URLRequest] = [:]

        func set(_ stub: Stub, for id: String) {
            lock.withLock { stubs[id] = stub }
        }

        func stub(for id: String) -> Stub {
            lock.withLock { stubs[id] ?? Stub() }
        }

        func record(_ request: URLRequest, for id: String) {
            lock.withLock { requests[id] = request }
        }

        func request(for id: String) -> URLRequest? {
            lock.withLock { requests[id] }
        }
    }

    static let registry = Registry()

    /// Session mit eigener Kennung. Die Kennung reist als Kopfzeile mit und
    /// verbindet Anfrage und hinterlegte Antwort.
    static func makeSession(id: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        configuration.httpAdditionalHeaders = [header: id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        Self.registry.record(request, for: id)
        let stub = Self.registry.stub(for: id)

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

/// Bündelt Kennung, Session und Zugriff auf die aufgezeichnete Anfrage.
struct StubbedNetwork {
    let id = UUID().uuidString

    func session(_ stub: URLProtocolStub.Stub) -> URLSession {
        URLProtocolStub.registry.set(stub, for: id)
        return URLProtocolStub.makeSession(id: id)
    }

    var request: URLRequest? {
        URLProtocolStub.registry.request(for: id)
    }
}
