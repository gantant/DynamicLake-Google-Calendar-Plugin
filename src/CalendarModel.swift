import Foundation

/// A calendar day, independent of time zone quirks. Comparable and hashable so
/// the lake can ask "is this day busy?" with a set lookup.
struct DayKey: Hashable, Comparable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = parts.year ?? 1970
        self.month = parts.month ?? 1
        self.day = parts.day ?? 1
    }

    func date(in calendar: Calendar) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// Where the card looks once the date changes under it.
enum DayRollover {
    /// Following today is the default, so midnight moves the selection and the
    /// month with it. A day the user browsed to is deliberate and is left alone.
    static func follow(
        previousToday: DayKey,
        today: DayKey,
        selectedDay: DayKey?,
        monthStart: DayKey,
        calendar: Calendar
    ) -> (selectedDay: DayKey?, monthStart: DayKey) {
        let wasFollowingToday = selectedDay == nil || selectedDay == previousToday
        guard wasFollowingToday else { return (selectedDay, monthStart) }
        return (today, CalendarMath.monthStart(for: today.date(in: calendar), calendar: calendar))
    }
}

enum CalendarMath {
    /// Six rows is the tallest a month can need; shorter months trim the empty
    /// rows so the card doesn't carry blank space.
    static let maximumWeeks = 6

    static func monthStart(for date: Date, calendar: Calendar) -> DayKey {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return DayKey(year: parts.year ?? 1970, month: parts.month ?? 1, day: 1)
    }

    static func today(in calendar: Calendar, now: Date = Date()) -> DayKey {
        DayKey(date: now, calendar: calendar)
    }

    static func addMonths(_ count: Int, to monthStart: DayKey, calendar: Calendar) -> DayKey {
        let base = monthStart.date(in: calendar)
        let shifted = calendar.date(byAdding: .month, value: count, to: base) ?? base
        return CalendarMath.monthStart(for: shifted, calendar: calendar)
    }

    static func addDays(_ count: Int, to day: DayKey, calendar: Calendar) -> DayKey {
        let base = day.date(in: calendar)
        let shifted = calendar.date(byAdding: .day, value: count, to: base) ?? base
        return DayKey(date: shifted, calendar: calendar)
    }

    /// The visible month as rows of seven days. Days that belong to the previous
    /// or next month are nil, so the grid shows blanks instead of numbers that
    /// look like they belong to the month on screen.
    static func monthRows(monthStart: DayKey, calendar: Calendar) -> [[DayKey?]] {
        let firstDate = monthStart.date(in: calendar)
        let weekday = calendar.component(.weekday, from: firstDate)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: firstDate) else {
            return Array(repeating: Array(repeating: nil, count: 7), count: maximumWeeks)
        }

        var rows: [[DayKey?]] = []
        for row in 0..<maximumWeeks {
            var cells: [DayKey?] = []
            for column in 0..<7 {
                let offset = row * 7 + column
                guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                    cells.append(nil)
                    continue
                }
                let key = DayKey(date: date, calendar: calendar)
                if key.year == monthStart.year && key.month == monthStart.month {
                    cells.append(key)
                } else {
                    cells.append(nil)
                }
            }
            rows.append(cells)
        }

        // Trim trailing rows with no day of this month (February can fit exactly
        // four weeks, which would otherwise leave two empty rows).
        while rows.count > 1, rows.last?.allSatisfy({ $0 == nil }) == true {
            rows.removeLast()
        }
        return rows
    }

    static func weekDays(containing day: DayKey, calendar: Calendar) -> [DayKey] {
        let date = day.date(in: calendar)
        let weekday = calendar.component(.weekday, from: date)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return (0..<7).map { offset in
            guard let shifted = calendar.date(byAdding: .day, value: offset - leading, to: date) else { return day }
            return DayKey(date: shifted, calendar: calendar)
        }
    }

    /// The first day of the week a day belongs to, so two days can be compared
    /// for "same week" without caring which one is selected.
    static func weekStart(containing day: DayKey, calendar: Calendar) -> DayKey {
        weekDays(containing: day, calendar: calendar).first ?? day
    }

    /// Two-letter weekday headings, rotated so the first one matches the user's
    /// first day of week.
    static func weekdaySymbols(calendar: Calendar, locale: Locale) -> [String] {
        var localised = calendar
        localised.locale = locale
        let symbols = localised.shortWeekdaySymbols
        let first = max(0, min(6, calendar.firstWeekday - 1))
        return (0..<7).map { index in
            let symbol = symbols[(first + index) % 7]
            return String(symbol.prefix(2))
        }
    }

    /// Month name only: the year is dropped for now, which keeps the header
    /// short enough to sit beside the agenda's day number.
    static func monthTitle(_ monthStart: DayKey, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("LLLL")
        return formatter.string(from: monthStart.date(in: calendar))
    }

    /// Short weekday ("Sun") for the glance's compact date label.
    static func weekdayShortName(_ day: DayKey, calendar: Calendar, locale: Locale) -> String {
        compactFormat("EEE", date: day.date(in: calendar), calendar: calendar, locale: locale)
    }

    /// Short month ("Oct") for the glance's compact date label.
    static func monthShortTitle(_ monthStart: DayKey, calendar: Calendar, locale: Locale) -> String {
        compactFormat("LLL", date: monthStart.date(in: calendar), calendar: calendar, locale: locale)
    }

    /// The day's weekday name, such as "Saturday", beside the big day number.
    static func weekdayName(_ day: DayKey, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter.string(from: day.date(in: calendar))
    }

    static func dayTitle(_ day: DayKey) -> String {
        "\(day.day)"
    }

    private static func compactFormat(_ template: String, date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// Google Calendar's day view. An iCal UID is not Google's event ID, so the
    /// best a feed can do is open the day the event sits on.
    static func googleCalendarDayURL(_ day: DayKey) -> String {
        "https://calendar.google.com/calendar/r/day/\(day.year)/\(day.month)/\(day.day)"
    }

    /// Short, locale-aware clock time ("9:30", "09:30", "9:30 AM").
    static func timeLabel(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: date)
    }

    /// Pads a column of time strings with spaces so the event titles beside them
    /// line up; dynamic type in the lake gives no fixed-width text.
    static func paddedTimeColumn(_ labels: [String]) -> [String] {
        let width = labels.map { $0.count }.max() ?? 0
        return labels.map { label in
            let missing = width - label.count
            return missing > 0 ? String(repeating: " ", count: missing) + label : label
        }
    }
}
