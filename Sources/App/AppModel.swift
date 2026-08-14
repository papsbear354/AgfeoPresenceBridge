import AppKit
import Foundation
import ServiceManagement

/// Brücke zwischen der SwiftUI-Oberfläche und `Core/`.
///
/// `ProfileController` und `AuthClient` sind Actors und kennen kein SwiftUI;
/// dieses Modell spiegelt ihren Zustand für die Anzeige und besitzt die
/// Einstellungen.
@MainActor
final class AppModel: ObservableObject {
    enum AuthState: Equatable {
        case signedOut
        /// Anmeldung läuft oder wird beim Start wiederhergestellt.
        case working
        case signedIn(name: String?)
        case failed(String)
    }

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            let snapshot = settings
            Task { await controller.apply(snapshot) }
            updateDeskWatching()
            if settings.tenantId != oldValue.tenantId || settings.clientId != oldValue.clientId {
                rebuildAuthClient()
            }
            if settings.pollIntervalSeconds != oldValue.pollIntervalSeconds
                || settings.pollIntervalInCallSeconds != oldValue.pollIntervalInCallSeconds {
                let normal = TimeInterval(settings.pollIntervalSeconds)
                let fast = TimeInterval(settings.pollIntervalInCallSeconds)
                Task { await poller?.updateIntervals(normal: normal, fast: fast) }
            }
            if settings.launchAtLogin != oldValue.launchAtLogin {
                applyLaunchAtLogin(settings.launchAtLogin)
            }
            schedulePersist()
        }
    }

    @Published private(set) var lastSentProfile: String?
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var sendFailed = false
    /// Läuft gerade ein Schaltvorgang? Sperrt die Knöpfe im UI.
    @Published private(set) var isSending = false
    @Published private(set) var authState: AuthState = .signedOut
    /// Letztes Pollergebnis. `nil` heißt: noch nicht abgefragt.
    @Published private(set) var presence: PresenceResult?
    /// Lokal erkannt, unabhängig von Teams.
    @Published private(set) var deskPresence: DeskPresence = .atDesk

    /// Meldung, wenn sich der Autostart nicht eintragen ließ.
    @Published private(set) var launchAtLoginProblem: String?

    private let bridge = AgfeoBridge()
    private let deskSource = SystemDeskPresence()
    private let safetyNet: SafetyNet
    private let lifecycle: LifecycleGuard
    private let controller: ProfileController
    private let accountClient = AccountClient()
    private var auth: AuthClient
    private var poller: PresencePoller?
    private var persistTask: Task<Void, Never>?

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        safetyNet = SafetyNet(baseProfile: loaded.baseProfile)
        controller = ProfileController(
            bridge: bridge, settings: loaded, safetyNet: safetyNet)
        lifecycle = LifecycleGuard(safetyNet: safetyNet, bridge: bridge)
        auth = AuthClient(
            tenantId: loaded.tenantId,
            clientId: loaded.clientId,
            webAuth: WebAuthSession())
        Log.info(.app, "Gestartet, Grundprofil \"\(loaded.baseProfile)\"")

        // Beim ersten Start die Datei anlegen, damit sie auffindbar ist und
        // nicht erst nach der ersten Änderung im UI auftaucht.
        if !FileManager.default.fileExists(atPath: SettingsStore.fileURL.path) {
            write(loaded)
        }

        lifecycle.install()
        observeWake()
        reconcileLaunchAtLogin()
        updateDeskWatching()
        Task { await restoreSession() }
    }

    /// Nach dem Aufwachen sofort wieder abfragen und den Backoff zurücksetzen
    /// (SPEC §6). `@Sendable` verhindert, dass der Closure die Isolation dieser
    /// Methode erbt und beim Aufruf geprüft wird.
    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                Log.info(.app, "Aufgewacht, Abfrage wird sofort wiederholt")
                await self?.poller?.pokeNow()
            }
        }
    }

    // MARK: Anmeldung

    /// Beim Start: aus dem Refresh Token in der Keychain still wieder anmelden.
    private func restoreSession() async {
        guard await auth.hasStoredCredentials else {
            authState = .signedOut
            return
        }
        authState = .working
        do {
            let account = try await refreshAccount()
            authState = .signedIn(name: account)
            Log.info(.auth, "Anmeldung aus der Keychain wiederhergestellt")
            await startPolling()
        } catch {
            authState = .failed(Self.message(for: error))
        }
    }

    func signIn() async {
        authState = .working
        do {
            try await auth.signIn()
            authState = .signedIn(name: try await refreshAccount())
            await startPolling()
        } catch AuthError.cancelled {
            // Kein Fehler, sondern eine Entscheidung des Benutzers.
            authState = .signedOut
            Log.info(.auth, "Anmeldung vom Benutzer abgebrochen")
        } catch {
            authState = .failed(Self.message(for: error))
        }
    }

    func signOut() async {
        await stopPolling()
        await auth.signOut()
        authState = .signedOut
    }

    // MARK: Präsenz

    private func startPolling() async {
        await stopPolling()
        let poller = PresencePoller(
            auth: auth,
            normalInterval: TimeInterval(settings.pollIntervalSeconds),
            fastInterval: TimeInterval(settings.pollIntervalInCallSeconds)
        ) { @Sendable [weak self] result in
            await self?.handle(result)
        }
        self.poller = poller
        await poller.start()
    }

    private func stopPolling() async {
        guard let poller else { return }
        await poller.stop()
        self.poller = nil
        presence = nil
    }

    // MARK: Anwesenheit am Platz

    /// Überwacht wird nur, wenn eine aktive Regel den Auslöser braucht.
    private func updateDeskWatching() {
        deskSource.apply(settings)
        guard settings.watchesDesk else {
            deskSource.stop()
            deskPresence = .atDesk
            return
        }
        deskSource.start { @Sendable [weak self] presence in
            await self?.handleDesk(presence)
        }
    }

    private func handleDesk(_ presence: DeskPresence) async {
        deskPresence = presence
        await controller.setDeskPresence(presence)
        await refreshFromController()
        await poller?.setFastInterval(await controller.isOnRuleProfile)
    }

    private func handle(_ result: PresenceResult) async {
        presence = result

        // Ist die Anmeldung endgültig weg, endet die Abfrage von selbst; das
        // muss sich im Icon und im Menü niederschlagen.
        if case .unknown(.notSignedIn) = result {
            authState = .failed("Die Anmeldung ist nicht mehr gültig. Bitte neu anmelden.")
            poller = nil
            return
        }

        await controller.handle(result)
        await refreshFromController()

        // Während ein Regelprofil steht, häufiger fragen — damit das
        // Zurückschalten nach dem Auflegen schneller kommt.
        await poller?.setFastInterval(await controller.isOnRuleProfile)
    }

    private func refreshAccount() async throws -> String? {
        let token = try await auth.validAccessToken()
        guard let account = await accountClient.fetch(accessToken: token) else { return nil }
        return "\(account.displayName) (\(account.userPrincipalName))"
    }

    private func rebuildAuthClient() {
        auth = AuthClient(
            tenantId: settings.tenantId,
            clientId: settings.clientId,
            webAuth: WebAuthSession())
        authState = .signedOut
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    var isSignedIn: Bool {
        if case .signedIn = authState { return true }
        return false
    }

    var accountDescription: String {
        switch authState {
        case .signedOut: return "—"
        case .working: return "wird geprüft…"
        case .signedIn(let name): return name ?? "angemeldet"
        case .failed(let message): return message
        }
    }

    // MARK: Schalten

    /// Manuelles Schalten aus dem Menü.
    func send(profile: String) async {
        isSending = true
        defer { isSending = false }
        let outcome = await controller.sendManual(profile: profile)
        if let newBase = outcome.newBaseProfile {
            settings.baseProfile = newBase
        }
        await refreshFromController()
    }

    /// Testen-Knopf neben einem Profilnamen in den Einstellungen.
    func test(profile: String) async {
        isSending = true
        defer { isSending = false }
        await controller.sendTest(profile: profile)
        await refreshFromController()
    }

    private func refreshFromController() async {
        lastSentProfile = await controller.lastSentProfile
        lastSentAt = await controller.lastSentAt
        sendFailed = await controller.lastSendFailed
    }

    // MARK: Anzeige

    /// Symbol der Menüleiste (SPEC §11).
    var statusSymbol: String {
        if sendFailed { return "exclamationmark.triangle" }
        switch authState {
        case .signedOut, .failed: return "exclamationmark.triangle"
        case .working, .signedIn: break
        }
        // Unbekannter Status ist ein Warnzustand: die App schaltet dann nicht.
        if case .unknown = presence { return "exclamationmark.triangle" }
        if !settings.automationEnabled { return "phone.badge.plus" }
        if let last = lastSentProfile, last != settings.baseProfile { return "phone.fill" }
        return "phone"
    }

    var statusSymbolIsDimmed: Bool {
        statusSymbol == "phone.badge.plus"
    }

    /// Bewusst „zuletzt gesendet", niemals „aktiv" — das Dashboard bestätigt nichts.
    var lastSentDescription: String {
        guard let profile = lastSentProfile, let at = lastSentAt else { return "noch nichts" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(profile) — \(formatter.string(from: at))"
    }

    /// Erste Zeile im Menü (SPEC §11).
    var statusLine: String {
        switch authState {
        case .signedOut: return "Nicht angemeldet"
        case .working: return "Anmeldung wird geprüft…"
        case .failed(let message): return message
        case .signedIn: break
        }

        switch presence {
        case .presence(_, let activity):
            return "Teams-Status: \(GraphActivity.label(for: activity)) (\(activity))"
        case .offline:
            return "Teams-Status: Offline"
        case .unknown:
            return "Status unbekannt — es wird nicht geschaltet"
        case nil:
            return "Teams-Status: wird abgefragt…"
        }
    }

    /// Zweite Anzeige für die Beobachtungsphase: der rohe `availability`-Wert.
    /// Graph liefert immer genau eine Activity, `availability` sagt zusätzlich,
    /// wie Teams den Zustand einordnet.
    var availabilityLine: String? {
        guard case .presence(let availability, _) = presence else { return nil }
        return "Verfügbarkeit: \(availability)"
    }

    /// Nur sichtbar, wenn die lokale Erkennung gerade Abwesenheit meldet.
    var deskLine: String? {
        guard case .away(let reason) = deskPresence else { return nil }
        return "Nicht am Platz — \(reason.text)"
    }

    // MARK: Profilliste

    func addProfile(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !settings.knownProfiles.contains(trimmed) else { return }
        settings.knownProfiles.append(trimmed)
    }

    func removeProfile(at index: Int) {
        guard settings.knownProfiles.indices.contains(index) else { return }
        settings.knownProfiles.remove(at: index)
    }

    /// Zieht eine Umbenennung durch Grundprofil und Regelwerk nach, damit keine
    /// Verweise auf einen Namen zurückbleiben, den es nicht mehr gibt.
    func renameProfile(at index: Int, to newName: String) {
        guard settings.knownProfiles.indices.contains(index) else { return }
        let oldName = settings.knownProfiles[index]
        guard oldName != newName else { return }
        settings.knownProfiles[index] = newName
        if settings.baseProfile == oldName { settings.baseProfile = newName }
        for ruleIndex in settings.rules.indices where settings.rules[ruleIndex].profileName == oldName {
            settings.rules[ruleIndex].profileName = newName
        }
    }

    // MARK: Regeln

    func addRule() {
        let profile = settings.knownProfiles.first ?? settings.baseProfile
        settings.rules.append(Rule(activity: "InACall", profileName: profile))
    }

    func removeRules(at offsets: IndexSet) {
        settings.rules.remove(atOffsets: offsets)
    }

    func moveRules(from source: IndexSet, to destination: Int) {
        settings.rules.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: Sonstiges

    func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Log.currentFile])
    }

    func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: Persistenz

    private func schedulePersist() {
        persistTask?.cancel()
        let snapshot = settings
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.write(snapshot)
        }
    }

    private func write(_ snapshot: Settings) {
        do {
            try SettingsStore.save(snapshot)
        } catch {
            Log.error(.settings, "Einstellungen konnten nicht geschrieben werden: \(error.localizedDescription)")
        }
    }

    /// Gleicht den gewünschten mit dem tatsächlichen Zustand ab.
    ///
    /// Ohne das bliebe der Autostart wirkungslos: die Einstellung steht auf
    /// „an“, eingetragen wird sie aber nur, wenn der Schalter umgelegt wird —
    /// beim ersten Start aus „/Programme“ passiert also sonst nichts.
    private func reconcileLaunchAtLogin() {
        let status = SMAppService.mainApp.status
        if status == .requiresApproval {
            launchAtLoginProblem = "In den Systemeinstellungen unter „Allgemein › "
                + "Anmeldeobjekte“ freigeben."
            return
        }
        guard settings.launchAtLogin != (status == .enabled) else { return }
        applyLaunchAtLogin(settings.launchAtLogin)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginProblem = nil
            Log.info(.app, "Autostart \(enabled ? "aktiviert" : "deaktiviert")")
        } catch {
            // Schlägt regelmäßig fehl, solange die App aus DerivedData läuft
            // und nicht in „/Programme“. Das gehört ins Fenster, nicht nur ins
            // Log — sonst glaubt man, der Schalter hätte gewirkt.
            launchAtLoginProblem = error.localizedDescription
            Log.error(.app, "Autostart konnte nicht gesetzt werden: \(error.localizedDescription)")
        }
    }
}
