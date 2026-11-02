import Foundation

/// What the standing notch chip says. Kept out of the plugin's run loop so the
/// wording can be tested without a socket, and so the cache's expiry rule lives
/// next to the text it protects.
enum NotchPeek {
    struct Content: Equatable {
        let key: String
        let text: String
        /// The moment this text stops being true: the named event's start, or
        /// midnight for the fallbacks.
        let validUntil: Date
    }

    static let textLimit = 60

    /// The next timed event still to start today. When none is left, an all-day
    /// event that covers today takes the line instead of a bare date; only when
    /// the day is empty does the chip show the date.
    static func content(
        now: Date,
        events: [ICalEvent],
        calendar: Calendar,
        locale: Locale,
        persistentChip: Bool
    ) -> Content {
        let day = CalendarMath.today(in: calendar, now: now)
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? now.addingTimeInterval(3600)

        if persistentChip {
            if let next = AgendaPlanner.firstStarting(
                in: DateInterval(start: now, end: dayEnd),
                events: events,
                calendar: calendar
            ) {
                let time = CalendarMath.timeLabel(next.start, calendar: calendar, locale: locale)
                return Content(key: next.key, text: truncated("\(next.title) · \(time)"), validUntil: next.start)
            }

            if let allDay = AgendaPlanner.firstAllDay(on: day, events: events, calendar: calendar) {
                return Content(key: "allday:\(allDay.key)", text: truncated("\(allDay.title) · All day"), validUntil: dayEnd)
            }
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return Content(key: "date:\(day)", text: formatter.string(from: now), validUntil: dayEnd)
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > textLimit else { return text }
        return String(text.prefix(textLimit - 1)) + "…"
    }
}
