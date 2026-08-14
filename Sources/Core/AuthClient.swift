import CryptoKit
import Foundation

/// Öffnet die Autorisierungsseite und liefert die Callback-URL zurück.
///
/// Als Protokoll, weil `ASWebAuthenticationSession` AppKit braucht und der
/// `AuthClient` plattformunabhängig bleiben soll.
protocol WebAuthenticating: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Verifier und Challenge nach RFC 7636 (S256).
struct PKCE: Sendable {
    let verifier: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        verifier = Data(bytes).base64URLEncodedString()
    }

    init(verifier: String) {
        self.verifier = verifier
    }

    var challenge: String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

enum AuthError: LocalizedError, Equatable {
    /// `state` der Antwort passt nicht zur Anfrage — Abbruch (SPEC §5).
    case stateMismatch
    case missingCode
    case cancelled
    /// Die Anmeldung ist endgültig weg: Passwortwechsel, Consent widerrufen,
    /// Conditional Access. Es wird nicht im Hintergrund weiterversucht.
    case invalidGrant
    case notSignedIn
    case server(String, String?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .stateMismatch:
            return "Die Antwort der Anmeldung passte nicht zur Anfrage. Abgebrochen."
        case .missingCode:
            return "Die Anmeldung lieferte keinen Autorisierungscode."
        case .cancelled:
            return "Anmeldung abgebrochen."
        case .invalidGrant:
            return "Die Anmeldung ist nicht mehr gültig. Bitte neu anmelden."
        case .notSignedIn:
            return "Nicht angemeldet."
        case .server(let code, let description):
            return description ?? "Fehler von Microsoft: \(code)"
        case .transport(let message):
            return message
        }
    }
}

/// Authorization Code Flow mit PKCE gegen den tenant-spezifischen Endpunkt
/// (SPEC §5). Kein MSAL, kein Device Code Flow.
actor AuthClient {
    /// `User.Read` ist zusätzlich zur Hauptspec dabei, damit der Konto-Tab den
    /// angemeldeten Benutzer benennen kann. Die Berechtigung ist im Tenant
    /// delegiert und per Administratorzustimmung erteilt (Nachtrag 01 §1), es
    /// erscheint also kein zusätzlicher Zustimmungsdialog. Wird der Name nicht
    /// gebraucht, genügt hier `Presence.Read offline_access`.
    /// `Presence.ReadWrite` kommt hinzu, damit ein Gespräch an der
    /// Telefonanlage den Teams-Status setzen kann. Wer die Funktion nicht
    /// nutzt, ändert dadurch nichts — geschrieben wird nur auf Anforderung.
    static let scope = "Presence.Read Presence.ReadWrite User.Read offline_access"
    static let redirectURI = "de.baz.agfeopresence://auth"
    static let callbackScheme = "de.baz.agfeopresence"

    private let tenantId: String
    private let clientId: String
    private let webAuth: any WebAuthenticating
    private let tokens: TokenStore
    private let session: URLSession

    /// Nur im Speicher (SPEC §5).
    private var accessToken: String?
    private var expiresAt: Date?
    /// Gesetzt nach `invalid_grant`: ab hier wird nicht mehr von allein
    /// nachgefasst, bis sich jemand neu anmeldet.
    private var permanentlySignedOut = false

    init(
        tenantId: String,
        clientId: String,
        webAuth: any WebAuthenticating,
        session: URLSession = .shared
    ) {
        self.tenantId = tenantId
        self.clientId = clientId
        self.webAuth = webAuth
        self.session = session
        tokens = TokenStore(account: clientId)
    }

    /// Liegt ein Refresh Token vor? Sagt nichts darüber, ob es noch gilt.
    var hasStoredCredentials: Bool {
        tokens.read() != nil
    }

    // MARK: Anmelden

    func signIn() async throws {
        let pkce = PKCE()
        let state = UUID().uuidString

        guard let authorizeURL = Self.authorizeURL(
            tenantId: tenantId,
            clientId: clientId,
            state: state,
            challenge: pkce.challenge)
        else { throw AuthError.transport("Tenant- oder Client-ID ist ungültig.") }

        Log.info(.auth, "Anmeldung wird geöffnet")
        let callback: URL
        do {
            callback = try await webAuth.authenticate(
                url: authorizeURL, callbackScheme: Self.callbackScheme)
        } catch let error as AuthError {
            throw error
        } catch {
            throw AuthError.transport(error.localizedDescription)
        }

        let code = try Self.authorizationCode(from: callback, expectedState: state)
        try await exchange(code: code, verifier: pkce.verifier)
        permanentlySignedOut = false
        Log.info(.auth, "Anmeldung erfolgreich")
    }

    func signOut() {
        tokens.delete()
        accessToken = nil
        expiresAt = nil
        permanentlySignedOut = false
        Log.info(.auth, "Abgemeldet, Refresh Token gelöscht")
    }

    // MARK: Token

    /// Gültiges Access Token, notfalls über einen Refresh. Wird proaktiv
    /// erneuert, sobald weniger als fünf Minuten Restlaufzeit bleiben.
    func validAccessToken() async throws -> String {
        if permanentlySignedOut { throw AuthError.invalidGrant }
        if let token = accessToken, let expiry = expiresAt, expiry.timeIntervalSinceNow > 300 {
            return token
        }
        return try await refresh()
    }

    /// Erzwingt eine Erneuerung, auch wenn das Token noch gültig aussieht —
    /// für den einen Wiederholversuch nach einem 401 (SPEC §6).
    func refreshedAccessToken() async throws -> String {
        if permanentlySignedOut { throw AuthError.invalidGrant }
        accessToken = nil
        expiresAt = nil
        return try await refresh()
    }

    @discardableResult
    private func refresh() async throws -> String {
        guard let refreshToken = tokens.read() else {
            permanentlySignedOut = true
            throw AuthError.notSignedIn
        }

        return try await requestToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
            "scope": Self.scope,
        ])
    }

    private func exchange(code: String, verifier: String) async throws {
        try await requestToken(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
    }

    @discardableResult
    private func requestToken(form: [String: String]) async throws -> String {
        var request = URLRequest(url: Self.tokenEndpoint(tenantId: tenantId))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded(form).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AuthError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let failure = try? JSONDecoder.graph.decode(TokenErrorResponse.self, from: data)
            let code = failure?.error ?? "http_\(status)"
            // Die Beschreibung enthält die AADSTS-Nummer, aber keine Tokens.
            Log.error(.auth, "Token-Endpunkt antwortete mit \(code): \(failure?.errorDescription ?? "—")")
            if code == "invalid_grant" {
                tokens.delete()
                accessToken = nil
                expiresAt = nil
                permanentlySignedOut = true
                throw AuthError.invalidGrant
            }
            throw AuthError.server(code, failure?.errorDescription)
        }

        guard let token = try? JSONDecoder.graph.decode(TokenResponse.self, from: data) else {
            throw AuthError.transport("Die Antwort der Anmeldung war nicht lesbar.")
        }

        accessToken = token.accessToken
        expiresAt = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        // Microsoft rotiert Refresh Tokens — jede Antwort bringt potenziell
        // ein neues, das gespeichert werden muss (SPEC §5).
        if let rotated = token.refreshToken {
            tokens.save(rotated)
        }
        return token.accessToken
    }

    // MARK: Rein funktionale Bausteine (ohne Netz testbar)

    static func authorizeURL(
        tenantId: String,
        clientId: String,
        state: String,
        challenge: String
    ) -> URL? {
        guard !tenantId.isEmpty, !clientId.isEmpty else { return nil }
        var components = URLComponents(
            string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components?.url
    }

    static func tokenEndpoint(tenantId: String) -> URL {
        URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/token")!
    }

    /// Prüft `state` und liefert den Autorisierungscode.
    static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        if let error = value("error") {
            if error == "access_denied" { throw AuthError.cancelled }
            throw AuthError.server(error, value("error_description"))
        }
        guard value("state") == expectedState else {
            Log.error(.auth, "state der Antwort passt nicht zur Anfrage")
            throw AuthError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw AuthError.missingCode
        }
        return code
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Antwortmodelle

private struct TokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?
}

private struct TokenErrorResponse: Decodable {
    let error: String
    let errorDescription: String?
}

extension JSONDecoder {
    static var graph: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension Data {
    /// base64url ohne Auffüllzeichen (RFC 7636).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
