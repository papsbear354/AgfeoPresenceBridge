import AppKit
import Foundation

/// Sicherheitsnetz aus SPEC §8 — Pflicht, nicht optional.
///
/// Verschwindet die App, während ein Regelprofil steht, wird vorher synchron
/// auf das Grundprofil zurückgeschaltet. Genau das ist der Fall, den man sonst
/// tagelang nicht bemerkt: Rechner zugeklappt, Telefon bleibt umgeleitet.
final class LifecycleGuard: @unchecked Sendable {
    private let safetyNet: SafetyNet
    private let bridge: AgfeoBridge

    init(safetyNet: SafetyNet, bridge: AgfeoBridge) {
        self.safetyNet = safetyNet
        self.bridge = bridge
    }

    func install() {
        // `queue: nil` ist hier entscheidend: der Block läuft dann synchron auf
        // dem postenden Thread. Mit `.main` würde er nur eingereiht — und käme
        // nach dem Einschlafen oder Beenden nie mehr dran.
        //
        // `@Sendable` verhindert, dass die Blöcke eine Actor-Isolation erben,
        // die beim Aufruf geprüft würde.
        let workspace = NSWorkspace.shared.notificationCenter

        _ = workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { @Sendable [self] _ in
            resetIfNeeded(trigger: "Ruhezustand")
        }

        _ = workspace.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: nil
        ) { @Sendable [self] _ in
            resetIfNeeded(trigger: "Herunterfahren")
        }

        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { @Sendable [self] _ in
            resetIfNeeded(trigger: "Beenden")
        }
    }

    private func resetIfNeeded(trigger: String) {
        guard let profile = safetyNet.profileNeedingReset() else { return }

        Log.notice(
            .controller,
            "\(trigger): schalte synchron zurück auf \"\(profile)\"",
            immediate: true)

        if bridge.activateNow(profile: profile) {
            safetyNet.recordSent(profile)
        } else {
            Log.error(
                .controller,
                "\(trigger): Rückschalten fehlgeschlagen — das Telefon bleibt umgeleitet",
                immediate: true)
        }
    }
}
