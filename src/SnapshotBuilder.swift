import Foundation

/// Turns parsed feed events into what the lake draws: the month's busy days and
/// one day's agenda.
///
/// Both shapes come from the same expansion, so the grid and the agenda can
/// never disagree about which occurrences exist.
enum SnapshotBuilder {
    /// Merges expanded occurrences into the month's busy days and the selected
    /// day's agenda.
    /// `includeAllDay` is the "Show All-Day Events" setting: when it is off, an
    /// all-day event is skipped completely, so a day does not stay dotted for an
    /// event the agenda hides.
    static func build(
        events: [ICalEvent],
        monthRows: [[DayKey?]],
        selectedDay: DayKey?,
        calendar: Calendar,
        includeAllDay: Bool = true
    ) -> CalendarSnapshot {
        let monthDays = monthRows.flatMap { $0 }.compactMap { $0 }
        guard let first = monthDays.min(), let last = monthDays.max() else { return .empty }

        let windowStart = first.date(in: calendar)
        guard let windowEnd = calendar.date(byAdding: .day, value: 1, to: last.date(in: calendar)) else { return .empty }
        let window = DateInterval(start: windowStart, end: windowEnd)
        let monthSet = Set(monthDays)

        let dayStart = selectedDay?.date(in: calendar)
        let dayEnd = dayStart.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }

        var busy = Set<DayKey>()
        var agenda: [DayEvent] = []

        for occurrence in expandedOccurrences(
            events: events,
            in: window,
            calendar: calendar,
            includeAllDay: includeAllDay
        ) {
            var day = calendar.startOfDay(for: occurrence.start)
            var guardCount = 0
            while day < occurrence.end, guardCount < 62 {
                let dayKey = DayKey(date: day, calendar: calendar)
                if monthSet.contains(dayKey) { busy.insert(dayKey) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                guardCount += 1
            }

            if let start = dayStart, let end = dayEnd, occurrence.start < end, occurrence.end > start {
                agenda.append(dayEvent(for: occurrence))
            }
        }

        return CalendarSnapshot(busyDays: busy, dayEvents: DayEvent.sorted(agenda))
    }

    /// One day's agenda on its own. DynaGlance always describes today, which is
    /// usually not the day the lake has selected, so it cannot borrow the
    /// snapshot's agenda.
    static func dayAgenda(
        events: [ICalEvent],
        day: DayKey,
        calendar: Calendar,
        includeAllDay: Bool = true
    ) -> [DayEvent] {
        let start = day.date(in: calendar)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        let occurrences = expandedOccurrences(
            events: events,
            in: DateInterval(start: start, end: end),
            calendar: calendar,
            includeAllDay: includeAllDay
        )
        return DayEvent.sorted(occurrences.map(dayEvent(for:)))
    }

    // MARK: - Expansion

    /// One occurrence of one event, already cleared of the cases the lake
    /// should never draw.
    struct Occurrence {
        let event: ICalEvent
        let start: Date
        let end: Date
    }

    /// Expands every event into the window, dropping cancellations, duplicates
    /// and occurrences an override replaced.
    ///
    /// Overrides (RECURRENCE-ID) replace the slot they point at, not the time
    /// they were moved to, so the originals are checked against the override
    /// minutes before they are kept.
    static func expandedOccurrences(
        events: [ICalEvent],
        in window: DateInterval,
        calendar: Calendar,
        includeAllDay: Bool
    ) -> [Occurrence] {
        var overrides: [String: Set<Int>] = [:]
        for event in events where event.recurrenceID != nil {
            guard let original = event.recurrenceID else { continue }
            overrides[event.uid, default: []].insert(Recurrence.minuteKey(original, calendar: calendar))
        }

        // Overrides first, so their slots are known before the originals run.
        let ordered = events.sorted { lhs, rhs in
            (lhs.recurrenceID != nil ? 0 : 1) < (rhs.recurrenceID != nil ? 0 : 1)
        }

        var results: [Occurrence] = []
        var seen = Set<String>()

        for event in ordered where !event.isCancelled {
            if !includeAllDay, event.isAllDay { continue }
            for occurrence in Recurrence.occurrences(of: event, in: window) {
                let key = "\(event.uid)#\(Recurrence.minuteKey(occurrence.start, calendar: calendar))"
                if !seen.insert(key).inserted { continue }
                if event.recurrenceID == nil,
                   overrides[event.uid]?.contains(Recurrence.minuteKey(occurrence.start, calendar: calendar)) == true {
                    continue
                }
                results.append(Occurrence(event: event, start: occurrence.start, end: occurrence.end))
            }
        }

        return results
    }

    private static func dayEvent(for occurrence: Occurrence) -> DayEvent {
        DayEvent(
            identifier: "\(occurrence.event.uid)#\(Int(occurrence.start.timeIntervalSince1970))",
            title: occurrence.event.summary,
            start: occurrence.start,
            end: occurrence.end,
            isAllDay: occurrence.event.isAllDay,
            calendarTitle: occurrence.event.calendarName
        )
    }
}
