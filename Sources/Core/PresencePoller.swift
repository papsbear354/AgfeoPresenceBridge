import Foundation

/// Exponentieller Backoff mit Deckel bei 60 s (SPEC §6).
///
/// Bei den vorgesehenen Intervallen ist das reine Hygiene — das Presence-Limit
/// liegt bei 1.500–10.000 Anfragen pro 30 s pro App und Tenant.
struct Backoff: Equatable, Sendable {
    static let ceiling: TimeInterval = 60

    let base: TimeInterval
    private(set) var step = 0

    init(base: TimeInterval) {
        self.base = base
    }

    mutating func next() -> TimeInterval {
        let delay = min(base * pow(2, Double(step)), Self.ceiling)
        step += 1
        return delay
    }

    mutating func reset() {
        step = 0
    }

    var isActive: Bool { step > 0 }
}

/// Fragt die Präsenz in Intervallen ab und reicht jedes Ergebnis weiter.
///
/// Der Poller schaltet nichts und kennt keine Regeln — er liefert nur, was er
/// weiß, und markiert ehrlich, wenn er nichts weiß.
actor PresencePoller {
    typealias Sink = @Sendable (PresenceResult) async -> Void

    private let auth: any TokenProviding
    private let client: PresenceClient
    private let sink: Sink

    private var normalInterval: TimeInterval
    private var fastInterval: TimeInterval
    /// Während ein Regelprofil aktiv ist, wird häufiger gefragt, damit das
    /// Zurückschalten schneller kommt. Gesetzt wird das ab M4.
    private var usesFastInterval = false

    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var backoff: Backoff
    private var lastLogged: PresenceResult?

    init(
        auth: any TokenProviding,
        client: PresenceClient = PresenceClient(),
        normalInterval: TimeInterval,
        fastInterval: TimeInterval,
        sink: @escaping Sink
    ) {
        self.auth = auth
        self.client = client
        self.sink = sink
        self.normalInterval = normalInterval
        self.fastInterval = fastInterval
        backoff = Backoff(base: normalInterval)
    }

    // MARK: Steuerung

    func start() {
        guard loop == nil else { return }
        Log.info(.presence, "Abfrage gestartet, Intervall \(Int(normalInterval)) s")
        loop = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        guard loop != nil else { return }
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        sleeper = nil
        lastLogged = nil
        Log.info(.presence, "Abfrage gestoppt")
    }

    /// Sofort wieder abfragen und den Backoff zurücksetzen — nach dem
    /// Aufwachen aus dem Ruhezustand (SPEC §6).
    func pokeNow() {
        backoff.reset()
        sleeper?.cancel()
    }

    func setFastInterval(_ enabled: Bool) {
        guard usesFastInterval != enabled else { return }
        usesFastInterval = enabled
    }

    func updateIntervals(normal: TimeInterval, fast: TimeInterval) {
        normalInterval = normal
        fastInterval = fast
        backoff = Backoff(base: normal)
    }

    // MARK: Schleife

    private func run() async {
        while !Task.isCancelled {
            let step = await poll()
            await emit(step.result)

            if step.stopsPolling {
                Log.error(.presence, "Abfrage endet: \(step.result.failureText ?? "—")")
                loop = nil
                return
            }

            await wait(step.forcedDelay ?? delay(after: step.result))
        }
    }

    private struct PollStep {
        var result: PresenceResult
        var forcedDelay: TimeInterval?
        var stopsPolling = false

        /// Unterscheidet eine erloschene Anmeldung von einer bloßen Störung.
        ///
        /// Vorher galt jeder Fehler als „Anmeldung weg“ und beendete die
        /// Abfrage endgültig. Beim Aufwachen aus dem Ruhezustand steht das
        /// Netz aber oft noch nicht — dann scheiterte die Token-Erneuerung an
        /// der Verbindung, und die App schwieg für den Rest des Tages, bis sich
        /// jemand von Hand neu anmeldete. Nur `invalidGrant` und
        /// `notSignedIn` bedeuten wirklich, dass niemand mehr angemeldet ist.
        static func from(_ error: any Error) -> PollStep {
            switch error as? AuthError {
            case .invalidGrant, .notSignedIn:
                return PollStep(result: .unknown(.notSignedIn), stopsPolling: true)
            case .server(let code, _):
                return PollStep(result: .unknown(.network("Anmeldedienst: \(code)")))
            default:
                let text = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                return PollStep(result: .unknown(.network(text)))
            }
        }
    }

    private func poll() async -> PollStep {
        let token: String
        do {
            token = try await auth.validAccessToken()
        } catch {
            return PollStep.from(error)
        }

        var fetch = await client.fetch(accessToken: token)

        // Genau ein Wiederholversuch mit frischem Token (SPEC §6).
        if fetch == .unauthorized {
            Log.notice(.presence, "401 — Token wird erneuert und der Aufruf wiederholt")
            do {
                let fresh = try await auth.refreshedAccessToken()
                fetch = await client.fetch(accessToken: fresh)
            } catch {
                return PollStep.from(error)
            }
        }

        switch fetch {
        case .presence(let availability, let activity):
            return PollStep(result: PresenceClient.result(
                availability: availability, activity: activity))
        case .unauthorized:
            return PollStep(result: .unknown(.notSignedIn), stopsPolling: true)
        case .throttled(let retryAfter):
            return PollStep(result: .unknown(.http(429)), forcedDelay: retryAfter)
        case .serverError(let code):
            return PollStep(result: .unknown(.http(code)))
        case .transport(let message):
            return PollStep(result: .unknown(.network(message)))
        case .malformed:
            return PollStep(result: .unknown(.malformedResponse))
        }
    }

    private func delay(after result: PresenceResult) -> TimeInterval {
        switch result {
        case .presence, .offline:
            backoff.reset()
            return usesFastInterval ? fastInterval : normalInterval
        case .unknown:
            return backoff.next()
        }
    }

    private func emit(_ result: PresenceResult) async {
        // Nur Wechsel protokollieren, sonst stünden pro Minute ein Dutzend
        // identischer Zeilen im Log (SPEC §12).
        if result != lastLogged {
            lastLogged = result
            Log.info(.presence, result.logLine)
        }
        await sink(result)
    }

    /// Wartezeit, die sich von `pokeNow()` abkürzen lässt.
    private func wait(_ seconds: TimeInterval) async {
        let task = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                // Von `pokeNow()` abgebrochen — dann geht es sofort weiter.
            }
        }
        sleeper = task
        await task.value
        sleeper = nil
    }
}

extension PresenceResult {
    var failureText: String? {
        if case .unknown(let failure) = self { return failure.text }
        return nil
    }

    var logLine: String {
        switch self {
        case .presence(let availability, let activity):
            return "Status \(availability) / \(activity)"
        case .offline:
            return "Status offline"
        case .unknown(let failure):
            return "Status unbekannt (\(failure.text))"
        }
    }
}
