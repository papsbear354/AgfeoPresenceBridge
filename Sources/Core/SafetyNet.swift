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
    private let lock = NSLock()
    private var storedLastSent: String?
    private var storedBase: String

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

    /// Das Profil, das vor dem Verschwinden der App noch gesendet werden
    /// muss — oder `nil`, wenn ohnehin schon das Grundprofil steht.
    func profileNeedingReset() -> String? {
        lock.withLock {
            guard let storedLastSent, storedLastSent != storedBase else { return nil }
            return storedBase
        }
    }
}
