import Foundation

/// Legt das Skript für den AGFEO Klick neben die Einstellungen.
///
/// Es liegt im Programmbündel und wird beim Start herauskopiert. Auf einem
/// fremden Rechner gäbe es das Skript sonst gar nicht — und der Pfad, den man
/// im Dashboard einträgt, muss außerhalb des Bündels liegen: Bei jedem Update
/// wird das Bündel ersetzt, ein Pfad hinein würde also irgendwann ins Leere
/// zeigen.
enum KlickScript {
    static var installedURL: URL {
        SettingsStore.directory.appendingPathComponent("klick-bridge.sh")
    }

    /// Kopiert das Skript heraus, wenn es fehlt oder veraltet ist, und macht
    /// es ausführbar.
    @discardableResult
    static func install() -> URL? {
        guard let source = Bundle.main.url(forResource: "klick-bridge", withExtension: "sh"),
              let wanted = try? Data(contentsOf: source)
        else {
            Log.notice(.app, "Klick-Skript liegt nicht im Programmbündel")
            return nil
        }

        let target = installedURL
        let existing = try? Data(contentsOf: target)
        guard existing != wanted else { return target }

        do {
            try FileManager.default.createDirectory(
                at: SettingsStore.directory, withIntermediateDirectories: true)
            try wanted.write(to: target, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: target.path)
            Log.info(.app, existing == nil
                     ? "Klick-Skript angelegt"
                     : "Klick-Skript aktualisiert")
            return target
        } catch {
            Log.error(.app, "Klick-Skript nicht schreibbar: \(error.localizedDescription)")
            return nil
        }
    }
}
