import Foundation
import OSLog

/// Logbereiche. Erscheinen in `Console.app` als OSLog-Category und in der
/// Logdatei als Präfix.
enum LogCategory: String {
    case app
    case agfeo
    case controller
    case settings
    case auth
    case presence
}

/// OSLog plus rotierende Datei unter `~/Library/Logs/AGFEOPresenceBridge/`.
///
/// Geloggt werden Zustandswechsel, gesendete Profilbefehle mit Grund und
/// Fehler. Niemals Tokens, Auth-Codes oder rohe Antwortkörper (SPEC §12).
enum Log {
    static let subsystem = "de.baz.agfeopresence"

    /// `immediate` wartet, bis die Zeile auf der Platte steht. Nötig für das
    /// Sicherheitsnetz: beim Einschlafen oder Beenden ist der Prozess weg,
    /// bevor die Schreib-Queue drankommt — und gerade dann will man die Zeile
    /// später lesen können.
    static func debug(_ category: LogCategory, _ message: String, immediate: Bool = false) {
        emit(.debug, category, message, immediate)
    }

    static func info(_ category: LogCategory, _ message: String, immediate: Bool = false) {
        emit(.info, category, message, immediate)
    }

    static func notice(_ category: LogCategory, _ message: String, immediate: Bool = false) {
        emit(.default, category, message, immediate)
    }

    static func error(_ category: LogCategory, _ message: String, immediate: Bool = false) {
        emit(.error, category, message, immediate)
    }

    /// Verzeichnis der Logdateien.
    static var directory: URL {
        LogFile.directory
    }

    /// Die aktuell beschriebene Datei — Ziel von „Log anzeigen".
    static var currentFile: URL {
        LogFile.currentFile
    }

    /// Im Testlauf wird nicht protokolliert. Sonst stünden die absichtlich
    /// erzeugten Fehler der Testfälle im Betriebslog und würden bei einer
    /// echten Fehlersuche in die Irre führen.
    private static let isTestRun: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }()

    private static func emit(
        _ level: OSLogType,
        _ category: LogCategory,
        _ message: String,
        _ immediate: Bool
    ) {
        guard !isTestRun else { return }
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        logger.log(level: level, "\(message, privacy: .public)")
        LogFile.shared.append(
            level: level, category: category, message: message, immediate: immediate)
    }
}

/// Rotierende Logdatei: `bridge.log` plus vier Archive, je höchstens 1 MB.
///
/// Alle Dateizugriffe laufen über eine serielle Queue, deshalb ist der
/// ungeprüfte `Sendable`-Stempel hier vertretbar.
private final class LogFile: @unchecked Sendable {
    static let shared = LogFile()

    static var directory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/AGFEOPresenceBridge", isDirectory: true)
    }

    static var currentFile: URL {
        directory.appendingPathComponent("bridge.log")
    }

    private let queue = DispatchQueue(label: "de.baz.agfeopresence.logfile")
    private let maxBytes = 1_000_000
    private let archiveCount = 4
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "de_DE")
        return f
    }()

    func append(
        level: OSLogType,
        category: LogCategory,
        message: String,
        immediate: Bool = false
    ) {
        let line = "\(stamp.string(from: Date())) [\(label(for: level))] \(category.rawValue): \(message)\n"
        let write = { @Sendable [self] in
            guard let data = line.data(using: .utf8) else { return }
            prepareDirectory()
            rotateIfNeeded()
            let url = Self.currentFile
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
        if immediate {
            queue.sync(execute: write)
        } else {
            queue.async(execute: write)
        }
    }

    private func label(for level: OSLogType) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .error, .fault: return "FEHLER"
        default: return "HINWEIS"
        }
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(
            at: Self.directory, withIntermediateDirectories: true)
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        let current = Self.currentFile
        guard let size = try? fm.attributesOfItem(atPath: current.path)[.size] as? Int,
              size > maxBytes
        else { return }

        let archive = { (index: Int) in
            Self.directory.appendingPathComponent("bridge.\(index).log")
        }
        try? fm.removeItem(at: archive(archiveCount))
        for index in stride(from: archiveCount - 1, through: 1, by: -1) {
            try? fm.moveItem(at: archive(index), to: archive(index + 1))
        }
        try? fm.moveItem(at: current, to: archive(1))
    }
}
