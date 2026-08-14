import AppKit
import Foundation

/// Alles, was der `ProfileController` von der AGFEO-Seite braucht. Als
/// Protokoll, damit der Controller ohne AppKit und ohne laufendes Dashboard
/// testbar bleibt.
protocol ProfileActivating: Sendable {
    /// Schaltet das Rufprofil. Rückgabe sagt nur, ob der Befehl abgesetzt
    /// werden konnte — eine Bestätigung liefert das Dashboard nicht.
    func activate(profile name: String) async -> Bool
}

/// Schaltet Rufprofile über den Protocol Handler des AGFEO-Dashboards.
///
/// Der Handler ist eine Einbahnstraße: kein Rückkanal, keine Bestätigung, kein
/// Auslesen des aktiven Profils oder der vorhandenen Profile (SPEC §9).
/// Deshalb sind Profilnamen im UI Freitext und die App spricht immer von
/// „zuletzt gesendet", nie von „aktiv".
final class AgfeoBridge: ProfileActivating {
    /// Ermittelt mit `osascript -e 'id of app "AGFEO-Dashboard"'` (13.08.2026),
    /// gegengeprüft gegen `CFBundleURLTypes` in der Info.plist des Dashboards,
    /// das die Schemes `adashboard`, `tksuite` und `tel` registriert.
    static let dashboardBundleID = "de.agfeo.dashboard"

    /// So lange wird nach einem Kaltstart auf den Prozess gewartet.
    private let launchTimeout: TimeInterval = 15
    /// Und so lange danach noch, bevor der Befehl kommt: das Dashboard muss
    /// sich erst mit der Anlage synchronisieren, sonst geht er ins Leere.
    private let settleAfterLaunch: TimeInterval = 2
    /// Abstand des einen Wiederholversuchs, wenn `open` fehlschlägt.
    private let retryDelay: TimeInterval = 2

    // MARK: URL

    /// Baut `adashboard:activate_call_profile?name=…`.
    ///
    /// Leerzeichen und Umlaute sind in Profilnamen zulässig. Aus
    /// `.urlQueryAllowed` werden zusätzlich `&=+?#` entfernt — die sind darin
    /// erlaubt, würden aber einen Namen wie „Büro & Mobil" in zwei
    /// Query-Parameter zerlegen.
    static func makeURL(profile name: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty
        else { return nil }
        return URL(string: "adashboard:activate_call_profile?name=\(encoded)")
    }

    // MARK: Schalten

    func activate(profile name: String) async -> Bool {
        guard let url = Self.makeURL(profile: name) else {
            Log.error(.agfeo, "Profilname \"\(name)\" ergibt keine gültige URL")
            return false
        }

        if !Self.isDashboardRunning {
            Log.info(.agfeo, "Dashboard läuft nicht, wird gestartet")
            guard await launchDashboard() else { return false }
            // Prozess da heißt noch nicht empfangsbereit.
            try? await Task.sleep(nanoseconds: UInt64(settleAfterLaunch * 1_000_000_000))
        }

        if await open(url) {
            Log.info(.agfeo, "Profil \"\(name)\" gesendet")
            return true
        }

        try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
        if await open(url) {
            Log.notice(.agfeo, "Profil \"\(name)\" erst im zweiten Versuch gesendet")
            return true
        }

        Log.error(.agfeo, "Profil \"\(name)\" konnte nicht gesendet werden")
        return false
    }

    /// Synchrone Variante für Ruhezustand, Herunterfahren und Beenden.
    ///
    /// Startet das Dashboard bewusst **nicht**: dafür bleibt keine Zeit, und
    /// ohne laufendes Dashboard lässt sich die Anlage ohnehin nicht schalten.
    func activateNow(profile name: String) -> Bool {
        guard let url = Self.makeURL(profile: name) else { return false }
        guard Self.isDashboardRunning else {
            Log.error(
                .agfeo,
                "Dashboard läuft nicht — \"\(name)\" kann jetzt nicht mehr gesendet werden",
                immediate: true)
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    // MARK: Dashboard

    static var isDashboardRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: dashboardBundleID).isEmpty
    }

    @MainActor
    private func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    /// Startet das Dashboard und wartet, bis der Prozess auftaucht.
    private func launchDashboard() async -> Bool {
        guard let appURL = await MainActor.run(body: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.dashboardBundleID)
        }) else {
            Log.error(.agfeo, "AGFEO-Dashboard ist nicht installiert (\(Self.dashboardBundleID))")
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } catch {
            Log.error(.agfeo, "Dashboard-Start fehlgeschlagen: \(error.localizedDescription)")
            return false
        }

        let deadline = Date().addingTimeInterval(launchTimeout)
        while Date() < deadline {
            if Self.isDashboardRunning { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        Log.error(.agfeo, "Dashboard war nach \(Int(launchTimeout)) s nicht erreichbar")
        return false
    }
}
