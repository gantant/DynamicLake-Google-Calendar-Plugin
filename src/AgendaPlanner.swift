import Foundation

/// The one question the notch asks about the calendar: which timed event starts
/// next inside a window. The standing chip's peek and the warning before an
/// event share it, so they can never name different events.
enum AgendaPlanner {
    struct Upcoming: Equatable {
        let key: String
        let title: String
        let start: Date

        /// The key the plugin remembers warned events by.
        static func key(uid: String, start: Date) -> String {
            "\(uid)#\(Int(start.timeIntervalSince1970))"
        }
    }

    /// The first all-day event covering `day`, in the same title order the
    /// agenda uses. It has no clock time, so it can only fill a surface that
    /// has nothing timed left to name.
    static func firstAllDay(on day: DayKey, events: [ICalEvent], calendar: Calendar) -> Upcoming? {
        let start = day.date(in: calendar)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let window = DateInterval(start: start, end: end)

        var first: Upcoming?
        var seen = Set<String>()

        for event in events where !event.isCancelled && event.isAllDay {
            for occurrence in Recurrence.occurrences(of: event, in: window) {
                let key = Upcoming.key(uid: event.uid, start: occurrence.start)
                guard seen.insert(key).inserted else { continue }
                let candidate = Upcoming(key: key, title: event.summary, start: occurrence.start)
                if first == nil || candidate.title.localizedCaseInsensitiveCompare(first!.title) == .orderedAscending {
                    first = candidate
                }
            }
        }
        return first
    }

    /// The earliest timed occurrence starting inside `window`.
    ///
    /// All-day events have no clock time to show, so they are skipped, as are
    /// cancelled ones and anything in `skipping` (already warned about).
    static func firstStarting(
        in window: DateInterval,
        events: [ICalEvent],
        calendar: Calendar,
        skipping: Set<String> = []
    ) -> Upcoming? {
        guard window.end > window.start else { return nil }

        var next: Upcoming?
        for event in events where !event.isCancelled && !event.isAllDay {
            for occurrence in Recurrence.occurrences(of: event, in: window) {
                guard occurrence.start >= window.start, occurrence.start < window.end else { continue }
                let key = Upcoming.key(uid: event.uid, start: occurrence.start)
                if skipping.contains(key) { continue }
                if next == nil || occurrence.start < next!.start {
                    next = Upcoming(key: key, title: event.summary, start: occurrence.start)
                }
            }
        }
        return next
    }
}
