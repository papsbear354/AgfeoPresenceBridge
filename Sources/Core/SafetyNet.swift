import Foundation

/// Synchron lesbarer Schaltzustand: zuletzt gesendetes Profil und Grundprofil.
///
/// Beim Einschlafen, Herunterfahren und Beenden bleibt keine Zeit für
/// asynchrone Arbeit — der Prozess ist weg, bevor ein Task startet. Der
/// `ProfileController` ist ein Actor und damit nur mit `await` zugänglich.
/// Deshalb liegen genau die beiden Werte, die das Sicherheitsnetz braucht,
/// hier hinter einer Sperre und sind von jedem Thread sofort lesbar.
///
/// Der Controller hält sie nicht doppelt, sondern arbeitet direkt hierauf —
/// zwei Wahrheiten über denselben Zustand wären genau die Sorte Fehler, die im
/// Betrieb wehtut.
final class SafetyNet: @unchecked Sendable {
    /// Warum die App gleich verschwindet — davon hängt ab, wohin geschaltet wird.
    enum Occasion {
        /// Ruhezustand: der Benutzer ist weg, kommt aber zurück, und die App
        /// korrigiert dann selbst. Ziel ist das Abwesenheitsprofil.
        case sleep
        /// Herunterfahren oder Beenden: die App ist danach weg und kann nichts
        /// mehr korrigieren. Ziel ist deshalb immer das Grundprofil, sonst
        /// bliebe das Telefon auf Dauer umgeleitet.
        case shutdown
    }

    private let lock = NSLock()
    private var storedLastSent: String?
    private var storedBase: String
    private var storedAway: String?

    init(baseProfile: String) {
        storedBase = baseProfile
    }

    var lastSentProfile: String? {
        lock.withLock { storedLastSent }
    }

    var baseProfile: String {
        lock.withLock { storedBase }
    }

    func recordSent(_ profile: String) {
        lock.withLock { storedLastSent = profile }
    }

    func setBaseProfile(_ profile: String) {
        lock.withLock { storedBase = profile }
    }

    /// Ziel der ersten aktiven Abwesenheitsregel, oder `nil`, wenn es keine gibt.
    func setAwayProfile(_ profile: String?) {
        lock.withLock { storedAway = profile }
    }

    /// Das Profil, das vor dem Verschwinden der App noch gesendet werden
    /// muss — oder `nil`, wenn ohnehin schon das richtige steht.
    func profileNeeded(for occasion: Occasion) -> String? {
        lock.withLock {
            // Zuklappen heißt weg vom Platz. Das ist ein eigener Auslöser und
            // kein Korrigieren — deshalb wird hier auch dann geschaltet, wenn
            // die App noch gar nichts gesendet hat.
            if case .sleep = occasion, let storedAway {
                return storedLastSent == storedAway ? nil : storedAway
            }
            // Sonst wird nur zurückgenommen, was die App selbst verstellt hat.
            guard let storedLastSent, storedLastSent != storedBase else { return nil }
            return storedBase
        }
    }
}
