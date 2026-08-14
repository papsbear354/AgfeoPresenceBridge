import AppKit
import CoreGraphics
import Foundation

/// Erkennt lokal, ob jemand am Platz sitzt.
///
/// Drei Signale, keines davon braucht eine Berechtigung:
///
/// - **Bildschirmsperre.** Sofort und eindeutig. Die Notification ist nicht
///   offiziell dokumentiert, aber seit vielen macOS-Versionen stabil; fällt sie
///   aus, greift weiterhin der Leerlauf.
/// - **Leerlauf.** `CGEventSource` liefert die Sekunden seit der letzten
///   Tastatur- oder Mauseingabe — derselbe Wert, den auch `ioreg` unter
///   `HIDIdleTime` führt. Kein Event Tap, keine Bedienungshilfen.
/// - **Ruhezustand.** Deckel zu heißt weg vom Platz.
final class SystemDeskPresence: DeskPresenceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (DeskPresence) async -> Void)?
    private var timer: Timer?
    private var observers: [any NSObjectProtocol] = []

    private var useScreenLock = true
    private var useIdle = true
    private var idleThreshold: TimeInterval = 600

    private var screenLocked = false
    private var asleep = false
    private var current: DeskPresence = .atDesk

    /// So oft wird die Leerlaufzeit nachgesehen.
    ///
    /// Am Platz genügt ein gemächlicher Takt — bis die Schwelle überhaupt
    /// erreicht ist, vergehen Minuten. Während der Abwesenheit wird häufiger
    /// nachgesehen, weil dann die Rückkehr schnell auffallen soll: wer nur die
    /// Maus bewegt, ohne zu entsperren, wartet sonst unnötig auf sein Profil.
    /// Die Abfrage selbst kostet praktisch nichts.
    private let atDeskInterval: TimeInterval = 10
    private let awayInterval: TimeInterval = 2

    // MARK: DeskPresenceSource

    func start(sink: @escaping @Sendable (DeskPresence) async -> Void) {
        lock.withLock { self.sink = sink }
        Task { @MainActor in self.install() }
    }

    func stop() {
        Task { @MainActor in self.uninstall() }
        lock.withLock { sink = nil }
    }

    func apply(_ settings: Settings) {
        lock.withLock {
            useScreenLock = settings.awayOnScreenLock
            useIdle = settings.awayOnIdle
            idleThreshold = TimeInterval(settings.idleThresholdSeconds)
        }
        evaluate()
    }

    // MARK: Beobachtung

    @MainActor
    private func install() {
        guard timer == nil else { return }

        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter

        var tokens: [any NSObjectProtocol] = []
        tokens.append(distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { @Sendable [self] _ in setScreenLocked(true) })

        tokens.append(distributed.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { @Sendable [self] _ in setScreenLocked(false) })

        tokens.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { @Sendable [self] _ in setAsleep(true) })

        tokens.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { @Sendable [self] _ in setAsleep(false) })

        lock.withLock { observers = tokens }

        startTimer(interval: atDeskInterval)
        Log.info(.app, "Anwesenheit am Platz wird überwacht")
        evaluate()
    }

    @MainActor
    private func startTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            @Sendable [self] _ in evaluate()
        }
        timer.tolerance = interval / 4
        self.timer = timer
    }

    /// Nach einem Zustandswechsel den Takt anpassen.
    @MainActor
    private func adjustTimer(away: Bool) {
        // Läuft keine Überwachung, gibt es auch nichts umzustellen.
        guard let timer else { return }
        let wanted = away ? awayInterval : atDeskInterval
        guard timer.timeInterval != wanted else { return }
        startTimer(interval: wanted)
    }

    @MainActor
    private func uninstall() {
        // Ohne laufende Überwachung gibt es nichts abzuräumen — und nichts zu
        // melden. Sonst stünde die Zeile bei jedem Start im Log.
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        let tokens = lock.withLock { defer { observers = [] }; return observers }
        for token in tokens {
            DistributedNotificationCenter.default().removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        Log.info(.app, "Anwesenheit am Platz wird nicht mehr überwacht")
    }

    private func setScreenLocked(_ locked: Bool) {
        lock.withLock { screenLocked = locked }
        evaluate()
    }

    private func setAsleep(_ value: Bool) {
        lock.withLock { asleep = value }
        evaluate()
    }

    /// Sekunden seit der letzten Tastatur- oder Mauseingabe.
    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: .init(rawValue: ~0)!)
    }

    private func evaluate() {
        let idle = idleSeconds
        let (next, sink) = lock.withLock { () -> (DeskPresence, (@Sendable (DeskPresence) async -> Void)?) in
            var presence = DeskPresence.atDesk
            if asleep {
                presence = .away(.asleep)
            } else if useScreenLock, screenLocked {
                presence = .away(.screenLocked)
            } else if useIdle, idle >= idleThreshold {
                presence = .away(.idle)
            }
            guard presence != current else { return (current, nil) }
            current = presence
            return (presence, self.sink)
        }
        guard let sink else { return }
        Task { @MainActor in adjustTimer(away: next.isAway) }
        Task { await sink(next) }
    }
}
