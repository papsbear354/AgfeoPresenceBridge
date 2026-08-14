import Foundation

/// Fragt einmalig den angemeldeten Benutzer ab, damit der Konto-Tab ihn
/// benennen kann.
///
/// Das ist der einzige Graph-Aufruf außerhalb von `/me/presence`. Er läuft nach
/// der Anmeldung und beim Start, nicht im Poll-Takt, und die Antwort wird
/// nirgends gespeichert.
struct AccountClient: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    struct Account: Equatable, Sendable {
        let displayName: String
        let userPrincipalName: String
    }

    func fetch(accessToken: String) async -> Account? {
        let url = URL(string: "https://graph.microsoft.com/v1.0/me?$select=displayName,userPrincipalName")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                Log.notice(.auth, "Benutzerangaben nicht abrufbar (HTTP \(status))")
                return nil
            }
            return try JSONDecoder().decode(Account.self, from: data)
        } catch {
            Log.notice(.auth, "Benutzerangaben nicht abrufbar: \(error.localizedDescription)")
            return nil
        }
    }
}

extension AccountClient.Account: Decodable {}
