import Foundation
import Testing

@testable import AGFEOPresenceBridge

@Suite("AuthClient — PKCE, Autorisierungs-URL, Callback")
struct AuthClientTests {
    /// Testvektor aus RFC 7636, Anhang B.
    @Test("Die Code Challenge entspricht dem RFC-Testvektor")
    func pkceMatchesRFCVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Ein erzeugter Verifier ist base64url und lang genug")
    func generatedVerifierIsSane() {
        let verifier = PKCE().verifier
        #expect(verifier.count >= 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(PKCE().verifier != verifier)
    }

    @Test("Die Autorisierungs-URL enthält alle geforderten Parameter")
    func authorizeURLIsComplete() throws {
        let url = try #require(AuthClient.authorizeURL(
            tenantId: "0d35eefe-cb7b-4411-af1e-cab10f60e02f",
            clientId: "80f6f821-c617-4d54-8775-101394c0fbee",
            state: "abc",
            challenge: "xyz"))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(components.host == "login.microsoftonline.com")
        #expect(components.path == "/0d35eefe-cb7b-4411-af1e-cab10f60e02f/oauth2/v2.0/authorize")
        #expect(items["client_id"] == "80f6f821-c617-4d54-8775-101394c0fbee")
        #expect(items["response_type"] == "code")
        #expect(items["response_mode"] == "query")
        #expect(items["redirect_uri"] == "de.baz.agfeopresence://auth")
        #expect(items["scope"] == AuthClient.scope)
        #expect(items["state"] == "abc")
        #expect(items["code_challenge"] == "xyz")
        #expect(items["code_challenge_method"] == "S256")
    }

    @Test("Ohne Tenant- oder Client-ID entsteht keine URL")
    func authorizeURLNeedsIDs() {
        #expect(AuthClient.authorizeURL(
            tenantId: "", clientId: "abc", state: "s", challenge: "c") == nil)
        #expect(AuthClient.authorizeURL(
            tenantId: "abc", clientId: "", state: "s", challenge: "c") == nil)
    }

    @Test("Der Code wird nur bei passendem state herausgegeben")
    func callbackChecksState() throws {
        let url = URL(string: "de.baz.agfeopresence://auth?code=EINCODE&state=erwartet")!

        #expect(try AuthClient.authorizationCode(from: url, expectedState: "erwartet") == "EINCODE")
        #expect(throws: AuthError.stateMismatch) {
            try AuthClient.authorizationCode(from: url, expectedState: "etwasanderes")
        }
    }

    @Test("Ein Abbruch durch den Benutzer wird als solcher erkannt")
    func callbackReportsUserCancellation() {
        let url = URL(string: "de.baz.agfeopresence://auth?error=access_denied&error_description=Nutzer")!
        #expect(throws: AuthError.cancelled) {
            try AuthClient.authorizationCode(from: url, expectedState: "s")
        }
    }

    @Test("Eine Fehlerantwort wird durchgereicht")
    func callbackReportsServerError() {
        let url = URL(string: "de.baz.agfeopresence://auth?error=invalid_request&error_description=AADSTS90014")!
        #expect(throws: AuthError.server("invalid_request", "AADSTS90014")) {
            try AuthClient.authorizationCode(from: url, expectedState: "s")
        }
    }

    @Test("Fehlt der Code, gibt es einen Fehler statt eines leeren Tokens")
    func callbackWithoutCodeFails() {
        let url = URL(string: "de.baz.agfeopresence://auth?state=s")!
        #expect(throws: AuthError.missingCode) {
            try AuthClient.authorizationCode(from: url, expectedState: "s")
        }
    }

    @Test("Formularwerte werden vollständig kodiert")
    func formEncoding() {
        let encoded = AuthClient.formEncoded([
            "grant_type": "authorization_code",
            "redirect_uri": "de.baz.agfeopresence://auth",
        ])
        #expect(encoded == "grant_type=authorization_code"
                + "&redirect_uri=de.baz.agfeopresence%3A%2F%2Fauth")
    }
}
