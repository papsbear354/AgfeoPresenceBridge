import Foundation

/// Ob der Benutzer am Platz sitzt — rein lokal ermittelt, ohne Teams und ohne
/// Netz.
///
/// Das ist bewusst ein zweiter, unabhängiger Eingang neben der Teams-Präsenz:
/// Teams meldet `Away` erst nach einigen Minuten und gar nicht, wenn der Status
/// von Hand auf „Verfügbar“ festgehalten wird.
enum DeskPresence: Equatable, Sendable {
    case atDesk
    case away(AwayReason)

    var isAway: Bool {
        if case .away = self { return true }
        return false
    }
}

enum AwayReason: String, Equatable, Sendable {
    case screenLocked
    case idle
    case asleep

    var text: String {
        switch self {
        case .screenLocked: return "Bildschirm gesperrt"
        case .idle: return "keine Eingabe"
        case .asleep: return "Ruhezustand"
        }
    }
}

/// Quelle des Signals. Die Umsetzung braucht AppKit und CoreGraphics und liegt
/// deshalb in `App/`.
protocol DeskPresenceSource: Sendable {
    /// Beginnt zu überwachen. Jede Änderung geht an `sink`, der aktuelle Stand
    /// wird sofort einmal gemeldet.
    func start(sink: @escaping @Sendable (DeskPresence) async -> Void)
    func stop()
    /// Übernimmt geänderte Schwellen und Schalter.
    func apply(_ settings: Settings)
}
