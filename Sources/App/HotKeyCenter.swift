import AppKit
import Carbon.HIToolbox
import Foundation

/// Systemweiter Tastenkurzbefehl.
///
/// Bewusst über die Carbon-API `RegisterEventHotKey` statt über
/// `NSEvent.addGlobalMonitorForEvents`: Letzteres verlangt die Freigabe unter
/// „Bedienungshilfen“, also einen Berechtigungsdialog und einen Eintrag in den
/// Systemeinstellungen. Ein registrierter Hotkey braucht davon nichts — das
/// System liefert nur dieses eine Tastenereignis aus.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        unregister()
        guard keyCode != 0 else { return }

        self.action = action
        installHandlerIfNeeded()

        let identifier = EventHotKeyID(signature: OSType(0x4147_4645), id: 1)  // 'AGFE'
        let status = RegisterEventHotKey(
            keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr {
            // Häufigster Grund: die Kombination ist schon von einer anderen
            // App oder vom System belegt.
            Log.error(.app, "Tastenkurzbefehl nicht belegbar (OSStatus \(status))")
            self.action = nil
        }
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        action = nil
    }

    fileprivate func fire() {
        action?()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &eventHandler)
    }
}

/// C-Rückruf des Event-Managers. Läuft auf dem Hauptthread, wird aber trotzdem
/// über einen Task überbrückt, statt die Isolation zu behaupten.
private func hotKeyEventHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    Task { @MainActor in HotKeyCenter.shared.fire() }
    return noErr
}

/// Auswahl fertiger Kombinationen. Ein freier Rekorder wäre schöner, bringt
/// aber eine eigene kleine Maschinerie mit; diese hier sind selten belegt.
struct HotKeyChoice: Identifiable, Equatable, Sendable {
    let id: Int
    let label: String
    let keyCode: UInt32

    /// ⌃⌥⌘ für alle Vorschläge — diese Kombination ist praktisch nie vergeben.
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)

    static let none = HotKeyChoice(id: 0, label: "keiner", keyCode: 0)

    static let all: [HotKeyChoice] = [
        none,
        HotKeyChoice(id: 1, label: "⌃⌥⌘U", keyCode: UInt32(kVK_ANSI_U)),
        HotKeyChoice(id: 2, label: "⌃⌥⌘A", keyCode: UInt32(kVK_ANSI_A)),
        HotKeyChoice(id: 3, label: "⌃⌥⌘M", keyCode: UInt32(kVK_ANSI_M)),
        HotKeyChoice(id: 4, label: "⌃⌥⌘T", keyCode: UInt32(kVK_ANSI_T)),
        HotKeyChoice(id: 5, label: "⌃⌥⌘1", keyCode: UInt32(kVK_ANSI_1)),
        HotKeyChoice(id: 6, label: "⌃⌥⌘2", keyCode: UInt32(kVK_ANSI_2)),
        HotKeyChoice(id: 7, label: "F13", keyCode: UInt32(kVK_F13)),
        HotKeyChoice(id: 8, label: "F14", keyCode: UInt32(kVK_F14)),
    ]

    static func choice(id: Int) -> HotKeyChoice {
        all.first { $0.id == id } ?? none
    }

    /// F-Tasten kommen ohne Zusatztasten aus.
    var modifiers: UInt32 {
        keyCode == UInt32(kVK_F13) || keyCode == UInt32(kVK_F14) ? 0 : Self.modifiers
    }
}
