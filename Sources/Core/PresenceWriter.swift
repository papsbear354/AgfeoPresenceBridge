import Foundation

/// Setzt die eigene Teams-Präsenz — die Gegenrichtung zum Lesen.
///
/// Verwendet wird `setUserPreferredPresence`: Das entspricht dem, was ein
/// Benutzer tut, wenn er seinen Status in Teams von Hand auf „Beschäftigt“
/// stellt. Der Wert bleibt stehen, bis er wieder freigegeben wird — deshalb
/// gehört zu jedem Setzen zwingend ein Freigeben.
///
/// Als Sicherheitsnetz bekommt jeder Eintrag zusätzlich eine Verfallszeit.
/// Stirbt die App mitten im Gespräch, räumt Teams selbst auf; ohne das bliebe
/// der Status womöglich tagelang hängen — und im Gegensatz zum Rufprofil sähen
/// das alle Kollegen.
struct PresenceWriter: Sendable {
    /// Nach dieser Zeit verfällt der gesetzte Status von selbst. Länger als
    /// jedes realistische Telefonat, kurz genug, um einen Absturz nicht zum
    /// Dauerzustand werden zu lassen.
    static let expiration = "PT2H"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum WriteResult: Equatable, Sendable {
        case ok
        /// Die Berechtigung fehlt — meist, weil die Anmeldung noch mit dem
        /// alten Scope erfolgt ist.
        case forbidden
        case failed(String)
    }

    /// Setzt den Status auf „Beschäftigt“.
    ///
    /// `activity` muss zur `availability` passen; Teams-eigene Werte wie
    /// `InACall` sind hier nicht erlaubt und führen zu HTTP 400.
    func setBusy(accessToken: String) async -> WriteResult {
        await post(
            path: "setUserPreferredPresence",
            body: [
                "availability": "Busy",
                "activity": "Busy",
                "expirationDuration": Self.expiration,
            ],
            accessToken: accessToken)
    }

    /// Gibt den Status wieder frei, sodass Teams ihn selbst bestimmt.
    func clear(accessToken: String) async -> WriteResult {
        await post(path: "clearUserPreferredPresence", body: [:], accessToken: accessToken)
    }

    private func post(
        path: String,
        body: [String: String],
        accessToken: String
    ) async -> WriteResult {
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/presence/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200, 202, 204:
                return .ok
            case 401, 403:
                Log.error(.presence, "Teams-Status nicht erlaubt (HTTP \(status)) — "
                          + "wurde die Anmeldung nach der Rechteänderung erneuert?")
                return .forbidden
            default:
                let text = PresenceClient.errorText(from: data)
                Log.error(.presence, "Teams-Status nicht gesetzt (HTTP \(status)): \(text)")
                return .failed("HTTP \(status)")
            }
        } catch {
            Log.error(.presence, "Teams-Status nicht gesetzt: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
}
