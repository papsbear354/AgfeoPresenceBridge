import Foundation

/// Ergebnis eines Poll-Vorgangs (SPEC §6).
///
/// Die Unterscheidung zwischen `.offline` und `.unknown` ist zentral:
/// `.offline` heißt „telefoniert nicht", `.unknown` heißt „wir wissen es
/// nicht" — und nur das erste ist je eine Grundlage zum Schalten.
enum PresenceResult: Equatable, Sendable {
    case presence(availability: String, activity: String)
    case offline
    case unknown(PollFailure)

    var activity: String? {
        if case .presence(_, let activity) = self { return activity }
        return nil
    }
}

enum PollFailure: Equatable, Sendable {
    case network(String)
    case http(Int)
    /// Anmeldung endgültig weg — hier wird nicht weiter gepollt.
    case notSignedIn
    case malformedResponse

    var text: String {
        switch self {
        case .network(let message): return message
        case .http(let code): return "HTTP \(code)"
        case .notSignedIn: return "nicht angemeldet"
        case .malformedResponse: return "unlesbare Antwort"
        }
    }
}

/// Rohe Antwort des Endpunkts. Was daraus folgt, entscheidet der Poller — er
/// kennt Backoff, Token-Erneuerung und den bisherigen Verlauf.
enum PresenceFetch: Equatable, Sendable {
    case presence(availability: String, activity: String)
    case unauthorized
    case throttled(retryAfter: TimeInterval?)
    case serverError(Int)
    case transport(String)
    case malformed
}

/// `GET /me/presence` — ausschließlich die eigene Präsenz (SPEC §2).
struct PresenceClient: Sendable {
    /// Ohne `$select`, entgegen Nachtrag 01 §2: der Endpunkt unterstützt das
    /// nicht. Graph antwortet auf `?$select=availability,activity` mit
    /// HTTP 400, „The property 'availability' cannot be used in the $select
    /// query option." Gemessen am 13.08.2026 im Zieltenant.
    ///
    /// Die zusätzlich gelieferten Felder (`statusMessage`, `workLocation`,
    /// `sequenceNumber`, `outOfOfficeSettings`) werden nicht ausgewertet und
    /// beim Dekodieren verworfen.
    static let endpoint = URL(string: "https://graph.microsoft.com/v1.0/me/presence")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(accessToken: String) async -> PresenceFetch {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { return .malformed }

        switch http.statusCode {
        case 200:
            guard let body = try? JSONDecoder().decode(PresenceResponse.self, from: data) else {
                return .malformed
            }
            return .presence(availability: body.availability, activity: body.activity)
        case 401:
            return .unauthorized
        case 429:
            let header = http.value(forHTTPHeaderField: "Retry-After")
            return .throttled(retryAfter: Self.retryAfter(from: header))
        default:
            // Die Fehlermeldung von Graph benennt die Ursache (falscher
            // Parameter, fehlende Berechtigung) und enthält keine Tokens.
            Log.error(.presence, "HTTP \(http.statusCode): \(Self.errorText(from: data))")
            return .serverError(http.statusCode)
        }
    }

    // MARK: Rein funktionale Bausteine

    /// `Offline` und `PresenceUnknown` bedeuten beide: Teams ist aus. Real
    /// heißt das, es wird nicht telefoniert (SPEC §6).
    static func result(availability: String, activity: String) -> PresenceResult {
        if availability == "Offline" || availability == "PresenceUnknown" {
            return .offline
        }
        return .presence(availability: availability, activity: activity)
    }

    /// Kürzt den Fehlerkörper auf eine loggbare Zeile.
    static func errorText(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "keine Fehlermeldung"
        }
        return String(text.prefix(400)).replacingOccurrences(of: "\n", with: " ")
    }

    /// `Retry-After` kommt als Sekundenzahl. Ein HTTP-Datum wäre zulässig,
    /// Graph liefert es hier nicht — dann greift der normale Backoff.
    static func retryAfter(from header: String?) -> TimeInterval? {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)),
              seconds > 0
        else { return nil }
        return min(seconds, 300)
    }
}

private struct PresenceResponse: Decodable {
    let availability: String
    let activity: String
}
