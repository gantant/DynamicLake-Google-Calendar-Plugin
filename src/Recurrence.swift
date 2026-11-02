import Foundation

/// RFC 5545 recurrence expansion, kept apart from parsing and from the lake so
/// the agenda rules live in one place.
enum Recurrence {
    /// Expands an event into the window. Recurrence math runs in the event's own
    /// time zone so a 9:30 meeting stays at 9:30 across a DST change.
    static func occurrences(of event: ICalEvent, in window: DateInterval) -> [(start: Date, end: Date)] {
        let duration = event.end.timeIntervalSince(event.start)
        guard duration > 0 else { return [] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = event.timeZone
        calendar.firstWeekday = 2 // Recurrence week starts on Monday for BYDAY math.

        // An all-day event spans whole calendar days, and a DST day is not 24
        // hours. Advancing by seconds would end an hour into the next day on a
        // 23-hour day, and leave a 25-hour series ending at 01:00 forever after,
        // which shows up as a second busy day. Timed events keep their real
        // duration, so they stay on seconds.
        let allDaySpan: Int? = event.isAllDay
            ? max(1, calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: event.start),
                to: calendar.startOfDay(for: event.end)
            ).day ?? 1)
            : nil

        var starts: [Date] = [event.start]
        if let rule = event.rule {
            // A series can start years before it is looked at, and a long event
            // can start before the window and still overlap it, so the generator
            // is told how far back it must not skip.
            let searchStart = window.start.addingTimeInterval(-max(duration, 0) - 86_400)
            starts = generate(rule: rule, from: event.start, calendar: calendar, windowStart: searchStart, windowEnd: window.end)
        }
        starts += event.rdates

        let excluded = Set(event.exdates.map { minuteKey($0, calendar: calendar) })
        var seen = Set<Int>()
        var results: [(Date, Date)] = []

        for start in starts {
            let key = minuteKey(start, calendar: calendar)
            if excluded.contains(key) { continue }
            if !seen.insert(key).inserted { continue }
            let end: Date
            if let span = allDaySpan, let shifted = calendar.date(byAdding: .day, value: span, to: start) {
                end = shifted
            } else {
                end = start.addingTimeInterval(duration)
            }
            if end <= window.start || start >= window.end { continue }
            results.append((start, end))
        }
        return results.sorted { $0.0 < $1.0 }
    }

    static func minuteKey(_ date: Date, calendar: Calendar) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    /// Expands the rule's candidates up to `windowEnd`.
    ///
    /// `windowStart` is a lower bound to skip ahead to, not a filter. A daily
    /// rule that began in 2015 used to spend its whole period budget reaching
    /// 2018 and then stop, so its occurrences silently vanished from every later
    /// window; jumping to the window costs the same whatever the series' age.
    /// Rules with COUNT cannot skip, because COUNT counts from the series start —
    /// the count itself keeps that work bounded.
    static func generate(rule: RecurrenceRule, from start: Date, calendar: Calendar, windowStart: Date, windowEnd: Date) -> [Date] {
        var results: [Date] = []
        let hardLimit = 2000
        var produced = 0
        var period = rule.count == nil
            ? periodsBefore(windowStart, rule: rule, start: start, calendar: calendar)
            : 0

        // One period per candidate cycle, stepping by INTERVAL.
        while produced < hardLimit {
            guard let periodStart = periodStart(for: start, rule: rule, offset: period, calendar: calendar) else { break }
            if periodStart >= windowEnd.addingTimeInterval(86400) { break }
            if period > 100_000 { break }

            var candidates: [Date] = []
            switch rule.frequency {
            case .daily:
                guard let day = calendar.date(byAdding: .day, value: period * rule.interval, to: start) else { break }
                candidates = [day]
            case .weekly:
                candidates = weeklyCandidates(rule: rule, weekStart: periodStart, origin: start, calendar: calendar)
            case .monthly:
                candidates = monthlyCandidates(rule: rule, monthStart: periodStart, origin: start, calendar: calendar)
            case .yearly:
                candidates = yearlyCandidates(rule: rule, yearStart: periodStart, origin: start, calendar: calendar)
            }

            for candidate in candidates.sorted() {
                if candidate < start { continue }
                if let until = rule.until, candidate > until { return results }
                // BYMONTH prunes before COUNT, because only the occurrences that
                // survive the filter are the ones the rule counts.
                if !rule.byMonth.isEmpty, !rule.byMonth.contains(calendar.component(.month, from: candidate)) { continue }
                produced += 1
                if let count = rule.count, produced > count { return results }
                results.append(candidate)
            }

            period += 1
        }

        return results
    }

    /// How many whole periods may be skipped before `date` without losing a
    /// candidate at or after it. One period is always given back, so a boundary
    /// is never rounded past.
    private static func periodsBefore(_ date: Date, rule: RecurrenceRule, start: Date, calendar: Calendar) -> Int {
        guard date > start else { return 0 }
        let units: Int?
        switch rule.frequency {
        case .daily:
            units = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: start),
                to: calendar.startOfDay(for: date)
            ).day
        case .weekly:
            let from = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            let to = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            units = calendar.dateComponents([.weekOfYear], from: from, to: to).weekOfYear
        case .monthly:
            units = calendar.dateComponents([.month], from: start, to: date).month
        case .yearly:
            units = calendar.dateComponents([.year], from: start, to: date).year
        }
        guard let units = units else { return 0 }
        let step = max(1, rule.interval)
        return max(0, units / step - 1)
    }

    private static func periodStart(for start: Date, rule: RecurrenceRule, offset: Int, calendar: Calendar) -> Date? {
        switch rule.frequency {
        case .daily:
            return calendar.date(byAdding: .day, value: offset * rule.interval, to: calendar.startOfDay(for: start))
        case .weekly:
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: start)?.start ?? start
            return calendar.date(byAdding: .weekOfYear, value: offset * rule.interval, to: weekStart)
        case .monthly:
            let monthStart = calendar.dateInterval(of: .month, for: start)?.start ?? start
            return calendar.date(byAdding: .month, value: offset * rule.interval, to: monthStart)
        case .yearly:
            let yearStart = calendar.dateInterval(of: .year, for: start)?.start ?? start
            return calendar.date(byAdding: .year, value: offset * rule.interval, to: yearStart)
        }
    }

    private static func weeklyCandidates(rule: RecurrenceRule, weekStart: Date, origin: Date, calendar: Calendar) -> [Date] {
        let weekdays = rule.byDay.isEmpty
            ? [RecurrenceRule.Weekday(weekday: calendar.component(.weekday, from: origin), ordinal: nil)]
            : rule.byDay

        return weekdays.compactMap { entry in
            // Recurrence weeks begin on Monday regardless of the user's locale.
            let offset = (entry.weekday - 2 + 7) % 7
            guard let day = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
            return noon(day, calendar: calendar).map { keepTime(of: origin, on: $0, calendar: calendar) }
        }
    }

    private static func monthlyCandidates(rule: RecurrenceRule, monthStart: Date, origin: Date, calendar: Calendar) -> [Date] {
        if !rule.byMonthDay.isEmpty {
            return rule.byMonthDay.compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
                guard calendar.component(.month, from: date) == calendar.component(.month, from: monthStart) else { return nil }
                return keepTime(of: origin, on: date, calendar: calendar)
            }
        }

        if !rule.byDay.isEmpty {
            return rule.byDay.compactMap { entry in
                nth(entry, in: monthStart, calendar: calendar).flatMap { keepTime(of: origin, on: $0, calendar: calendar) }
            }
        }

        let day = calendar.component(.day, from: origin)
        guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return [] }
        return [keepTime(of: origin, on: date, calendar: calendar)]
    }

    private static func yearlyCandidates(rule: RecurrenceRule, yearStart: Date, origin: Date, calendar: Calendar) -> [Date] {
        let month = rule.byMonth.first ?? calendar.component(.month, from: origin)
        guard let monthStart = calendar.date(byAdding: .month, value: month - 1, to: yearStart) else { return [] }

        if !rule.byMonthDay.isEmpty {
            return rule.byMonthDay.compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
                return keepTime(of: origin, on: date, calendar: calendar)
            }
        }
        if !rule.byDay.isEmpty, let entry = rule.byDay.first {
            guard let date = nth(entry, in: monthStart, calendar: calendar) else { return [] }
            return [keepTime(of: origin, on: date, calendar: calendar)]
        }

        let day = calendar.component(.day, from: origin)
        guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return [] }
        return [keepTime(of: origin, on: date, calendar: calendar)]
    }

    private static func nth(_ entry: RecurrenceRule.Weekday, in monthStart: Date, calendar: Calendar) -> Date? {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return nil }
        let matches = range.compactMap { day -> Date? in
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart) else { return nil }
            return calendar.component(.weekday, from: date) == entry.weekday ? date : nil
        }
        guard !matches.isEmpty else { return nil }

        if let ordinal = entry.ordinal {
            if ordinal > 0 { return ordinal <= matches.count ? matches[ordinal - 1] : nil }
            let index = matches.count + ordinal
            return index >= 0 ? matches[index] : nil
        }
        return matches.first
    }

    private static func keepTime(of origin: Date, on day: Date, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.hour, .minute, .second], from: origin)
        parts.year = calendar.component(.year, from: day)
        parts.month = calendar.component(.month, from: day)
        parts.day = calendar.component(.day, from: day)
        return calendar.date(from: parts) ?? day
    }

    private static func noon(_ date: Date, calendar: Calendar) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = 12
        return calendar.date(from: parts)
    }
}
