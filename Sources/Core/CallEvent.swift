import Foundation

/// Ein Anrufereignis der Telefonanlage, gemeldet über den AGFEO Klick.
///
/// Das ist der Rückkanal, den der Protocol Handler nicht hat: Das Dashboard
/// ruft bei jedem Zustandswechsel ein Skript auf, das die Werte als URL an
/// diese App weiterreicht.
struct CallEvent: Equatable, Sendable {
    var state: CallState
    var number: String
    var isOutbound: Bool
    /// Bleibt über ein Gespräch hinweg gleich und trennt so aufeinander
    /// folgende Anrufe voneinander.
    var connectionUID: String

    /// Zustände laut Programmbinary des Dashboards, ergänzt um die im Betrieb
    /// beobachteten Abweichungen: gemeldet wird tatsächlich `finished`, wo im
    /// Binary `disconnect` steht.
    enum CallState: String, Equatable, Sendable {
        case calling            // eigener Ruf geht raus
        case called             // es klingelt herein
        case calledBusy = "calledbusy"
        case connect            // Gespräch steht
        case finished           // Gespräch beendet
        case disconnect         // ebenfalls Ende, je nach Fall
        case pickup             // herangeholt
        case mailboxRecording = "mailbox_recording"
        case connectMailbox = "connect_mailbox"
        case disconnectMailbox = "disconnect_mailbox"
        case note = "ctinote"
        case initial = "init"

        /// Läuft ein Gespräch? Nur das zählt als „am Telefon“ — beim bloßen
        /// Klingeln ist noch niemand im Gespräch.
        var isTalking: Bool {
            switch self {
            case .connect, .pickup, .connectMailbox, .mailboxRecording:
                return true
            case .calling, .called, .calledBusy, .finished, .disconnect,
                 .disconnectMailbox, .note, .initial:
                return false
            }
        }

        /// Beendet dieses Ereignis das Gespräch?
        var endsCall: Bool {
            self == .finished || self == .disconnect || self == .disconnectMailbox
        }

        var text: String {
            switch self {
            case .calling: return "wählt"
            case .called: return "klingelt"
            case .calledBusy: return "besetzt"
            case .connect: return "im Gespräch"
            case .finished, .disconnect: return "beendet"
            case .pickup: return "herangeholt"
            case .mailboxRecording: return "Ansage läuft"
            case .connectMailbox: return "mit Sprachbox verbunden"
            case .disconnectMailbox: return "Sprachbox beendet"
            case .note: return "Notiz"
            case .initial: return "Start"
            }
        }
    }

    /// Baut das Ereignis aus der URL, die das Klick-Skript schickt:
    /// `de.baz.agfeopresence://call?state=…&number=…&outbound=…&uid=…`
    init?(url: URL) {
        guard url.host == "call",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
        guard let state = CallState(rawValue: value("state")) else { return nil }

        self.state = state
        number = value("number")
        isOutbound = value("outbound") == "1"
        connectionUID = value("uid")
    }
}
