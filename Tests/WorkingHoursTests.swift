import Foundation
import Testing

@testable import AGFEOPresenceBridge

@Suite("WorkingHours")
struct WorkingHoursTests {
    /// Fester Kalender ohne Sommerzeit-Überraschungen.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// - Parameter weekday: 1 = Sonntag … 7 = Samstag.
    private func date(weekday: Int, hour: Int, minute: Int = 0) -> Date {
        // 09.08.2026 ist ein Sonntag, also der Wochentag 1.
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 8
        parts.day = 8 + weekday
        parts.hour = hour
        parts.minute = minute
        return calendar.date(from: parts)!
    }

    private let officeHours = WorkingHours(
        enabled: true, days: [2, 3, 4, 5, 6], startMinute: 8 * 60, endMinute: 18 * 60)

    @Test("Abgeschaltet gilt immer als Arbeitszeit")
    func disabledAlwaysMatches() {
        let hours = WorkingHours()
        #expect(hours.contains(date(weekday: 1, hour: 3), calendar: calendar))
    }

    @Test("Innerhalb der Bürozeit an einem Werktag")
    func insideOnWeekday() {
        #expect(officeHours.contains(date(weekday: 3, hour: 9), calendar: calendar))
        #expect(officeHours.contains(date(weekday: 6, hour: 17, minute: 59), calendar: calendar))
    }

    @Test("Der Feierabend zählt nicht mehr dazu")
    func endIsExclusive() {
        #expect(!officeHours.contains(date(weekday: 3, hour: 18), calendar: calendar))
        #expect(!officeHours.contains(date(weekday: 3, hour: 20), calendar: calendar))
    }

    @Test("Vor Arbeitsbeginn zählt nicht dazu")
    func beforeStart() {
        #expect(!officeHours.contains(date(weekday: 3, hour: 7, minute: 59), calendar: calendar))
        #expect(officeHours.contains(date(weekday: 3, hour: 8), calendar: calendar))
    }

    @Test("Am Wochenende gilt nichts")
    func weekendIsOff() {
        #expect(!officeHours.contains(date(weekday: 7, hour: 10), calendar: calendar))
        #expect(!officeHours.contains(date(weekday: 1, hour: 10), calendar: calendar))
    }

    /// Für Schichten, die über Mitternacht laufen: der Abend gehört zum
    /// ausgewählten Tag, die frühen Stunden danach zum Vortag.
    @Test("Ein Fenster über Mitternacht")
    func spanningMidnight() {
        let nightShift = WorkingHours(
            enabled: true, days: [6], startMinute: 22 * 60, endMinute: 6 * 60)

        #expect(nightShift.contains(date(weekday: 6, hour: 23), calendar: calendar))
        #expect(nightShift.contains(date(weekday: 7, hour: 5), calendar: calendar))
        #expect(!nightShift.contains(date(weekday: 7, hour: 7), calendar: calendar))
        #expect(!nightShift.contains(date(weekday: 6, hour: 21), calendar: calendar))
    }

    @Test("Gleiche Anfangs- und Endzeit bedeutet: nie")
    func emptyWindow() {
        let hours = WorkingHours(
            enabled: true, days: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 9 * 60)
        #expect(!hours.contains(date(weekday: 3, hour: 9), calendar: calendar))
    }

    @Test("Ohne gewählte Tage passiert nichts")
    func noDaysSelected() {
        let hours = WorkingHours(enabled: true, days: [], startMinute: 0, endMinute: 23 * 60)
        #expect(!hours.contains(date(weekday: 3, hour: 10), calendar: calendar))
    }

    @Test("Die Zusammenfassung nennt Tage und Uhrzeit")
    func summaryReadsWell() {
        let text = officeHours.summary(calendar: calendar)
        #expect(text.contains("08:00–18:00 Uhr"))
    }
}

@Suite("ProfileController — Ende der Arbeitszeit")
struct ProfileControllerScheduleTests {
    @Test("Zum Feierabend wird ein Regelprofil zurückgenommen")
    func standDownResetsRuleProfile() async {
        let bridge = MockBridge()
        var settings = Settings()
        settings.baseProfile = "Anwesend"
        let controller = ProfileController(
            bridge: bridge, time: TestClock(), settings: settings)

        await controller.handle(.presence(availability: "Busy", activity: "InACall"))
        #expect(bridge.sent == ["Meeting"])

        await controller.standDown()
        #expect(bridge.sent == ["Meeting", "Anwesend"])
    }

    @Test("Steht ohnehin das Grundprofil, wird nichts gesendet")
    func standDownIsQuietWhenNothingToDo() async {
        let bridge = MockBridge()
        let controller = ProfileController(
            bridge: bridge, time: TestClock(), settings: Settings())

        await controller.standDown()
        #expect(bridge.sent.isEmpty)
    }
}
