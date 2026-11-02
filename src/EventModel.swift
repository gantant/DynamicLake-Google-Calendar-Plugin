import Foundation

/// One calendar event, reduced to what the card can show. Kept free of EventKit
/// so the lake builder and its tests can run without a calendar store.
struct DayEvent: Equatable {
    let identifier: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String

    func timeText(calendar: Calendar, locale: Locale) -> String {
        isAllDay ? "All day" : CalendarMath.timeLabel(start, calendar: calendar, locale: locale)
    }

    /// All-day events lead the day, then timed events in start order.
    static func sorted(_ events: [DayEvent]) -> [DayEvent] {
        events.sorted { lhs, rhs in
            if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

/// What the lake needs for one render: which days carry events, and the selected
/// day's agenda.
struct CalendarSnapshot: Equatable {
    var busyDays: Set<DayKey> = []
    var dayEvents: [DayEvent] = []

    static let empty = CalendarSnapshot()
}
