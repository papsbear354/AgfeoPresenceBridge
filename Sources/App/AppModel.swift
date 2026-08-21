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
            if settings.workingHours != oldValue.workingHours {
                checkSchedule()
            }
            if settings.hotKeyChoice != oldValue.hotKeyChoice
                || settings.hotKeyProfile != oldValue.hotKeyProfile {
                updateHotKey()
            }
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
    /// Laufendes Gespräch an der Telefonanlage, gemeldet über den AGFEO Klick.
    @Published private(set) var activeCall: CallEvent?
    /// Außerhalb der Arbeitszeit ruht die Automatik vollständig.
    @Published private(set) var withinWorkingHours = true
    /// Läuft eine Befristung, steht hier ihr Ende. Ohne Ende bedeutet ein
    /// gesetztes `heldProfile`: per Tastenkurzbefehl gehalten.
    @Published private(set) var holdUntil: Date?
    @Published private(set) var heldProfile: String?
    /// Die letzten Schaltvorgänge für das Menü.
    @Published private(set) var history: [SwitchRecord] = []

    /// Meldung, wenn sich der Autostart nicht eintragen ließ.
    @Published private(set) var launchAtLoginProblem: String?
    /// Meldung, wenn der Teams-Status nicht gesetzt werden konnte.
    @Published private(set) var teamsStatusProblem: String?

    private let bridge = AgfeoBridge()
    private let deskSource = SystemDeskPresence()
    private let safetyNet: SafetyNet
    private let lifecycle: LifecycleGuard
    private let controller: ProfileController
    private let accountClient = AccountClient()
    private let presenceWriter = PresenceWriter()
    private var auth: AuthClient
    private var poller: PresencePoller?
    private var persistTask: Task<Void, Never>?
    private var scheduleTimer: Timer?
    private var holdTimer: Timer?
    private let notifier = Notifier()

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

        // Im Testlauf hört das Programm hier auf. Ein Testlauf startet die
        // vollständige App als Wirt; täte sie dann ihre Arbeit, fragte jeder
        // Durchlauf nach dem Schlüsselbund-Passwort — die Testfassung ist
        // ad-hoc signiert und für den Schlüsselbund damit jedes Mal ein
        // anderes Programm, weshalb auch „Immer erlauben“ nichts hilft. Und im
        // schlimmsten Fall schaltete ein Testlauf echte Rufprofile um.
        guard !Log.isRunningTests else { return }

        lifecycle.install()
        KlickScript.install()
        observeWake()
        reconcileLaunchAtLogin()
        withinWorkingHours = loaded.workingHours.contains(Date())
        startScheduleWatch()
        updateHotKey()
        updateDeskWatching()
        Task { await restoreSession() }
    }

    /// Nach dem Aufwachen sofort wieder abfragen und den Backoff zurücksetzen
    /// (SPEC §6). `@Sendable` verhindert, dass der Closure die Isolation dieser
    /// Methode erbt und beim Aufruf geprüft wird.
    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                Log.info(.app, "Aufgewacht, Abfrage wird sofort wiederholt")
                self?.checkSchedule()
                await self?.poller?.pokeNow()
            }
        }

        // Startet das Dashboard neu, kennt es unseren Stand nicht mehr. Weil es
        // keinen Rückkanal gibt, hilft nur erneutes Senden.
        center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { @Sendable [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard app?.bundleIdentifier == AgfeoBridge.dashboardBundleID else { return }
            Task { @MainActor in await self?.dashboardDidStart() }
        }
    }

    private func dashboardDidStart() async {
        // Kurz warten: das Dashboard synchronisiert sich erst mit der Anlage,
        // und ein eigener Schaltvorgang, der den Start ausgelöst hat, soll
        // zuerst fertig werden.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard withinWorkingHours, settings.automationEnabled else { return }
        Log.info(.app, "Dashboard neu gestartet, letzter Stand wird erneut gesendet")
        await controller.resendLastProfile()
        await refreshFromController()
    }

    // MARK: Anmeldung

    /// Beim Start: aus dem Refresh Token in der Keychain still wieder anmelden.
    private func restoreSession() async {
        guard await auth.hasStoredCredentials else {
            // Ohne diese Zeile sieht man nur, dass nichts passiert — nicht,
            // warum. Genau das hat die Suche nach der täglichen Abmeldung
            // unnötig schwer gemacht.
            Log.info(.auth, "Kein Refresh Token lesbar — nicht angemeldet")
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
        // Einen gesetzten Teams-Status nicht zurücklassen — nach dem Abmelden
        // käme die App nicht mehr an ihn heran.
        if activeCall != nil, settings.setTeamsStatusOnCall,
           let token = try? await auth.validAccessToken() {
            _ = await presenceWriter.clear(accessToken: token)
        }
        activeCall = nil
        await stopPolling()
        await auth.signOut()
        authState = .signedOut
    }

    // MARK: Präsenz

    private func startPolling() async {
        await stopPolling()
        guard isSignedIn, withinWorkingHours else { return }
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

    // MARK: Telefonanlage

    /// Ereignis vom AGFEO Klick — der Rückkanal, den der Protocol Handler
    /// nicht hat.
    func handleCallEvent(_ event: CallEvent) {
        Log.info(.app, "Anlage meldet: \(event.state.rawValue)"
                 + (event.number.isEmpty ? "" : " (\(event.number))"))

        let wasTalking = activeCall != nil

        if event.state.endsCall {
            // Nur das Gespräch beenden, um das es auch geht: ein verspätetes
            // Ende darf einen längst neuen Anruf nicht abräumen.
            if activeCall?.connectionUID == event.connectionUID { activeCall = nil }
        } else {
            activeCall = event.state.isTalking ? event : nil
        }

        guard wasTalking != (activeCall != nil) else { return }
        Task { await applyTeamsStatus(busy: activeCall != nil) }
    }

    /// Spiegelt ein Gespräch an der Telefonanlage in den Teams-Status.
    ///
    /// Beim Ende wird der Status nicht auf „Verfügbar“ gesetzt, sondern
    /// freigegeben — sonst stünde er auf Grün fest, während in Teams
    /// womöglich längst eine Besprechung läuft.
    private func applyTeamsStatus(busy: Bool) async {
        guard settings.setTeamsStatusOnCall, isSignedIn else { return }
        guard let token = try? await auth.validAccessToken() else { return }

        let result = busy
            ? await presenceWriter.setBusy(accessToken: token)
            : await presenceWriter.clear(accessToken: token)

        switch result {
        case .ok:
            Log.info(.presence, busy
                     ? "Teams-Status auf Beschäftigt gesetzt (Gespräch an der Anlage)"
                     : "Teams-Status wieder freigegeben")
            teamsStatusProblem = nil
        case .forbidden:
            teamsStatusProblem = "Berechtigung fehlt — bitte einmal ab- und wieder anmelden."
        case .failed(let message):
            teamsStatusProblem = message
        }
    }

    /// Zeile im Menü, solange an der Anlage telefoniert wird.
    var callLine: String? {
        guard let call = activeCall else { return nil }
        let direction = call.isOutbound ? "abgehend" : "ankommend"
        let number = call.number.isEmpty ? "unbekannt" : call.number
        return "Telefon: \(call.state.text), \(direction) \(number)"
    }

    // MARK: Arbeitszeit

    /// Prüft regelmäßig, ob das Zeitfenster begonnen oder geendet hat. Eine
    /// halbe Minute genügt: an einer Grenze kommt es auf Sekunden nicht an.
    private func startScheduleWatch() {
        scheduleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            @Sendable [weak self] _ in
            Task { @MainActor in self?.checkSchedule() }
        }
        timer.tolerance = 10
        scheduleTimer = timer
    }

    private func checkSchedule() {
        let inside = settings.workingHours.contains(Date())
        guard inside != withinWorkingHours else { return }
        withinWorkingHours = inside
        Task { await applySchedule(inside) }
    }

    private func applySchedule(_ inside: Bool) async {
        if inside {
            Log.info(.app, "Arbeitszeit beginnt, Automatik läuft wieder")
            await startPolling()
            updateDeskWatching()
        } else {
            // Erst die Quellen abschalten, dann aufräumen — sonst könnte ein
            // gerade laufender Poll noch dazwischenfunken.
            Log.info(.app, "Arbeitszeit endet, Automatik ruht")
            await stopPolling()
            deskSource.stop()
            deskPresence = .atDesk
            await controller.standDown()
            await refreshFromController()
        }
    }

    // MARK: Anwesenheit am Platz

    /// Überwacht wird nur, wenn eine aktive Regel den Auslöser braucht.
    private func updateDeskWatching() {
        deskSource.apply(settings)
        guard settings.watchesDesk, withinWorkingHours else {
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
    ///
    /// - Parameter duration: Mit Angabe bleibt das Profil so lange stehen und
    ///   die Automatik hält sich zurück; danach übernimmt sie wieder.
    func send(profile: String, for duration: TimeInterval? = nil) async {
        isSending = true
        defer { isSending = false }

        let outcome = await controller.sendManual(
            profile: profile, holdsAutomation: duration != nil)
        if let newBase = outcome.newBaseProfile {
            settings.baseProfile = newBase
        }
        if outcome.delivered, let duration {
            startHold(for: duration)
        } else {
            clearHold()
        }
        await refreshFromController()
    }

    /// Befristung vorzeitig beenden.
    func endHold() async {
        clearHold()
        await controller.releaseHold()
        await refreshFromController()
    }

    /// Tastenkurzbefehl: schaltet auf das eingestellte Profil und hält es, bis
    /// dieselbe Taste erneut gedrückt wird.
    func toggleHotKeyProfile() async {
        guard settings.hasHotKey else { return }
        if heldProfile != nil {
            await endHold()
            return
        }
        isSending = true
        defer { isSending = false }
        clearHold()
        await controller.sendManual(profile: settings.hotKeyProfile, holdsAutomation: true)
        await refreshFromController()
    }

    private func updateHotKey() {
        let choice = HotKeyChoice.choice(id: settings.hotKeyChoice)
        guard settings.hasHotKey else {
            HotKeyCenter.shared.unregister()
            return
        }
        HotKeyCenter.shared.register(
            keyCode: choice.keyCode, modifiers: choice.modifiers
        ) { [weak self] in
            Task { @MainActor in await self?.toggleHotKeyProfile() }
        }
        Log.info(.app, "Tastenkurzbefehl \(choice.label) schaltet auf \"\(settings.hotKeyProfile)\"")
    }

    private func startHold(for duration: TimeInterval) {
        holdTimer?.invalidate()
        holdUntil = Date().addingTimeInterval(duration)
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
            @Sendable [weak self] _ in
            Task { @MainActor in await self?.endHold() }
        }
        timer.tolerance = 5
        holdTimer = timer
        Log.info(.app, "Befristung läuft \(Int(duration / 60)) Minuten")
    }

    private func clearHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdUntil = nil
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
        history = await controller.history
        heldProfile = await controller.heldProfile

        let failed = await controller.lastSendFailed
        // Nur beim Übergang melden, nicht bei jedem Poll erneut.
        if failed, !sendFailed {
            let profile = history.first?.profile ?? "Rufprofil"
            Task {
                await notifier.warn(
                    title: "Rufprofil nicht geschaltet",
                    body: "„\(profile)“ ließ sich nicht setzen. Läuft das AGFEO-Dashboard?")
            }
        }
        sendFailed = failed
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
        if !settings.automationEnabled || !withinWorkingHours { return "phone.badge.plus" }
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

        guard withinWorkingHours else {
            return "Außerhalb der Arbeitszeit — es wird nicht geschaltet"
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
