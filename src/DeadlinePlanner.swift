import Foundation

/// Works out the single next moment the plugin has anything to do, so one timer
/// can replace a fixed tick. Everything the plugin used to poll for is a known
/// deadline: the day rolls at midnight, the chip's line stops being true when its
/// event starts, a warning is due `warnMinutes` before one, the fetch is due one
/// interval after the last, and a dismissal is due once the warning has been read.
///
/// Kept pure and free of sockets so the schedule can be tested without a host.
enum DeadlinePlanner {
    /// Why the timer is armed. Only used for logging; the date is what matters.
    enum Reason: String {
        case midnight
        case warning
        case peek
        case dismissal
        case fetch
    }

    struct Deadline: Equatable {
        let date: Date
        let reason: Reason
    }

    /// How far ahead the warning search looks. A midnight deadline recomputes
    /// this every day, so anything inside tomorrow is enough.
    static let warningHorizon: TimeInterval = 2 * 24 * 3600

    /// The earliest of every deadline that currently applies.
    /// - Parameters:
    ///   - warningDismissAt: when a warning peek should shrink back to the chip.
    ///   - skipping: events already warned about, so an overdue warning is not
    ///     proposed again — that would arm the timer for "now" forever.
    ///   - warningsAllowed: false while the lake is open, which suppresses
    ///     warnings for as long as the user is looking at the card.
    static func next(
        now: Date,
        events: [ICalEvent],
        calendar: Calendar,
        locale: Locale,
        warnMinutes: Int,
        persistentChip: Bool,
        refreshInterval: TimeInterval,
        lastFetch: Date,
        warningDismissAt: Date?,
        skipping: Set<String>,
        warningsAllowed: Bool
    ) -> Deadline {
        var candidates: [Deadline] = []

        // The day itself: rollover, the chip's date fallback and an all-day
        // peek all turn over at the same instant.
        let midnight = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(3600)
        candidates.append(Deadline(date: midnight, reason: .midnight))

        let peek = NotchPeek.content(
            now: now,
            events: events,
            calendar: calendar,
            locale: locale,
            persistentChip: persistentChip
        )
        candidates.append(Deadline(date: peek.validUntil, reason: .peek))

        if warningsAllowed, warnMinutes > 0 {
            let horizon = DateInterval(start: now, end: now.addingTimeInterval(warningHorizon))
            // An event that has already started is not warned about, and an
            // event whose lead time has passed is warned about now.
            if let upcoming = AgendaPlanner.firstStarting(
                in: horizon,
                events: events,
                calendar: calendar,
                skipping: skipping
            ), upcoming.start > now {
                let lead = upcoming.start.addingTimeInterval(-TimeInterval(warnMinutes * 60))
                candidates.append(Deadline(date: max(lead, now), reason: .warning))
            }
        }

        if let dismiss = warningDismissAt, dismiss > now {
            candidates.append(Deadline(date: dismiss, reason: .dismissal))
        }

        // Feeds refresh on their own interval whether or not the lake is open,
        // because the glance is a surface of its own.
        let fetch = lastFetch.addingTimeInterval(refreshInterval)
        if fetch > now {
            candidates.append(Deadline(date: fetch, reason: .fetch))
        }

        return candidates.min { $0.date < $1.date } ?? Deadline(date: midnight, reason: .midnight)
    }
}
