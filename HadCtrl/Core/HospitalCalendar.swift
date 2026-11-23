import Foundation

/// Injectable time source (spec §30: tests never depend on the wall clock).
protocol HCClock: Sendable {
    func now() -> Date
}

struct SystemClock: HCClock {
    func now() -> Date { Date() }
}

struct FixedClock: HCClock {
    let date: Date
    func now() -> Date { date }
}

/// Institutional Gregorian calendar in the hospital time zone (spec §11, §15).
struct HospitalCalendar: Sendable {
    let timeZone: TimeZone
    let calendar: Calendar

    static let riyadh = HospitalCalendar(timeZoneID: "Asia/Riyadh")

    init(timeZoneID: String) {
        let zone = TimeZone(identifier: timeZoneID) ?? TimeZone(secondsFromGMT: 3 * 3600)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = 1 // Sunday
        self.timeZone = zone
        self.calendar = cal
    }

    /// A date-only deadline resolves to 23:59:59 local time of that day,
    /// matching `private.end_of_local_day` on the server.
    func endOfDay(year: Int, month: Int, day: Int) -> Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        c.hour = 23; c.minute = 59; c.second = 59
        guard let date = calendar.date(from: c),
              calendar.component(.day, from: date) == day else { return nil } // rejects 31 Nov etc.
        return date
    }

    func endOfDay(containing date: Date) -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return endOfDay(year: c.year!, month: c.month!, day: c.day!)!
    }

    /// Clamp a requested day-of-month into the month (e.g. day 31 in February).
    func clampedDay(_ day: Int, year: Int, month: Int) -> Int {
        var c = DateComponents(); c.year = year; c.month = month; c.day = 1
        guard let first = calendar.date(from: c),
              let range = calendar.range(of: .day, in: .month, for: first) else { return day }
        return min(max(1, day), range.upperBound - 1)
    }

    func isOverdue(dueAt: Date, submittedAt: Date?, now: Date) -> Bool {
        submittedAt == nil && now > dueAt
    }
}
