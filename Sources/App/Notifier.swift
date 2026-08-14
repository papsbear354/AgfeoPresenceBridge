import Foundation
import UserNotifications

/// Systemmitteilungen für Fälle, die man sonst erst bemerkt, wenn das Telefon
/// falsch klingelt.
///
/// Es wird sparsam gemeldet: nur, wenn ein Profil sich nicht schalten ließ.
/// Erfolgreiche Wechsel stehen im Menü und im Log, dafür braucht niemand eine
/// Einblendung.
@MainActor
final class Notifier {
    private var authorizationAsked = false
    private var authorized = false

    func warn(title: String, body: String) async {
        guard await ensureAuthorization() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.notice(.app, "Mitteilung konnte nicht gezeigt werden: \(error.localizedDescription)")
        }
    }

    /// Wird erst beim ersten tatsächlichen Anlass gefragt — ein Dialog gleich
    /// beim Start, bevor irgendetwas passiert ist, wäre nur lästig.
    private func ensureAuthorization() async -> Bool {
        if authorizationAsked { return authorized }
        authorizationAsked = true
        do {
            authorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
        } catch {
            Log.notice(.app, "Mitteilungen nicht erlaubt: \(error.localizedDescription)")
            authorized = false
        }
        return authorized
    }
}
