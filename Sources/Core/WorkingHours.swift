import Foundation

/// Zeitfenster, in dem die Automatik überhaupt etwas tun darf.
///
/// Außerhalb wird nicht gepollt, nichts erkannt und nichts geschaltet — das
/// MacBook wird abends auch privat benutzt, und dann soll die Telefonanlage in
/// Ruhe gelassen werden. Manuelles Schalten aus dem Menü bleibt jederzeit
/// möglich.
struct WorkingHours: Codable, Equatable, Sendable {
    var enabled: Bool = false
    /// Wochentage nach `Calendar`-Zählung: 1 = Sonntag … 7 = Samstag.
    /// Voreinstellung Montag bis Freitag.
    var days: [Int] = [2, 3, 4, 5, 6]
    /// Minuten seit Mitternacht.
    var startMinute: Int = 8 * 60
    var endMinute: Int = 18 * 60

    /// Liegt der Zeitpunkt innerhalb der Arbeitszeit?
    ///
    /// Ist das Fenster abgeschaltet, gilt immer „ja“ — dann verhält sich die
    /// App wie zuvor.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return true }
        guard startMinute != endMinute else { return false }

        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute
        else { return true }
        let current = hour * 60 + minute

        guard startMinute > endMinute else {
            return days.contains(weekday) && current >= startMinute && current < endMinute
        }

        // Fenster über Mitternacht: der angebrochene Abend zählt zum
        // ausgewählten Tag, die frühen Stunden danach gehören zum Vortag.
        if current >= startMinute { return days.contains(weekday) }
        let previousDay = weekday == 1 ? 7 : weekday - 1
        return current < endMinute && days.contains(previousDay)
    }

    /// Beschriftung für die Oberfläche, etwa „Mo–Fr, 08:00–18:00 Uhr“.
    func summary(calendar: Calendar = .current) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let names = days.sorted().compactMap { day -> String? in
            let index = day - 1
            return symbols.indices.contains(index) ? symbols[index] : nil
        }
        let time = "\(Self.text(for: startMinute))–\(Self.text(for: endMinute)) Uhr"
        return names.isEmpty ? "keine Tage gewählt" : "\(names.joined(separator: ", ")), \(time)"
    }

    static func text(for minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60 % 24, minute % 60)
    }
}
