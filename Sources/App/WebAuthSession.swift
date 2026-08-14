import AppKit
import AuthenticationServices
import Foundation

/// `ASWebAuthenticationSession` hinter dem plattformunabhängigen Protokoll.
///
/// Der einzige Teil der Anmeldung, der AppKit braucht — deshalb liegt er in
/// `App/` und nicht in `Core/`.
final class WebAuthSession: WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                Runner.shared.start(
                    url: url, callbackScheme: callbackScheme, continuation: continuation)
            }
        }
    }
}

/// Hält Session und Ankerfenster am Leben, solange die Anmeldung läuft.
@MainActor
private final class Runner: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = Runner()

    private var session: ASWebAuthenticationSession?
    /// Als Menüleisten-App gibt es kein reguläres Fenster, das als Anker
    /// dienen könnte. Dieses hier bleibt unsichtbar.
    private lazy var anchorWindow = NSWindow(
        contentRect: .zero, styleMask: [], backing: .buffered, defer: true)

    func start(
        url: URL,
        callbackScheme: String,
        continuation: CheckedContinuation<URL, any Error>
    ) {
        let answer = SingleAnswer(continuation)

        // `@Sendable` ist hier Pflicht, nicht Kosmetik: ohne die Markierung
        // erbt der Closure die MainActor-Isolation dieser Methode, und die
        // Laufzeit prüft sie beim Aufruf. Der Handler kommt aber über eine
        // XPC-Reply-Queue der SafariLaunchAgent-Verbindung zurück — die Prüfung
        // schlägt fehl und beendet den Prozess mit SIGTRAP.
        //
        // Aus demselben Grund wird `self` nicht eingefangen. Die Session bleibt
        // in `self.session` liegen, bis die nächste Anmeldung sie ersetzt; eine
        // beendete Session hält nichts offen.
        let session = ASWebAuthenticationSession(
            url: url, callbackURLScheme: callbackScheme
        ) { @Sendable callback, error in
            if let callback {
                answer.resume(returning: callback)
                return
            }
            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                answer.resume(throwing: AuthError.cancelled)
                return
            }
            answer.resume(
                throwing: AuthError.transport(
                    error?.localizedDescription ?? "Die Anmeldung wurde nicht abgeschlossen."))
        }

        session.presentationContextProvider = self
        // Bestehende Browser-Anmeldung mitnehmen, damit kein zweiter Login nötig ist.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session

        // Ohne das erscheint das Anmeldefenster hinter den anderen Fenstern.
        NSApp.activate(ignoringOtherApps: true)
        if !session.start() {
            self.session = nil
            answer.resume(
                throwing: AuthError.transport("Das Anmeldefenster ließ sich nicht öffnen."))
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? anchorWindow
    }
}

/// Löst die Continuation genau einmal ein, egal aus welchem Thread. Ein
/// doppeltes `resume` wäre ein sofortiger Absturz.
private final class SingleAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?

    init(_ continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = continuation
    }

    func resume(returning url: URL) {
        take()?.resume(returning: url)
    }

    func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<URL, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
