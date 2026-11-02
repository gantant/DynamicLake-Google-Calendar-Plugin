import Foundation

// Second suite: the feed reader that replaced EventKit.

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS \(name)")
    } else {
        print("FAIL \(name)")
        failures += 1
    }
}

func utc() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}

func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, calendar: Calendar) -> Date {
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = day
    parts.hour = hour
    parts.minute = minute
    return calendar.date(from: parts)!
}

func window(_ from: Date, _ to: Date) -> DateInterval {
    DateInterval(start: from, end: to)
}

@main
enum ICalendarTests {
    static func main() {
        let calendar = utc()

        // MARK: - Parsing

        let simple = """
        BEGIN:VCALENDAR
        VERSION:2.0
        X-WR-CALNAME:Work
        BEGIN:VEVENT
        UID:one
        SUMMARY:Design review
        DTSTART:20261005T090000Z
        DTEND:20261005T100000Z
        END:VEVENT
        BEGIN:VEVENT
        UID:two
        SUMMARY:Company holiday
        DTSTART;VALUE=DATE:20261012
        DTEND;VALUE=DATE:20261013
        END:VEVENT
        END:VCALENDAR
        """

        let parsed = try! ICalendarParser.parse(simple)
        check(parsed.count == 2, "two VEVENTs parse")
        check(parsed[0].summary == "Design review", "summary survives")
        check(parsed[0].isAllDay == false, "timed events are not all-day")
        check(parsed[0].calendarName == "Work", "the feed name is carried")
        check(parsed[1].isAllDay, "VALUE=DATE marks an all-day event")
        check(parsed[1].end.timeIntervalSince(parsed[1].start) == 86400, "an all-day event spans one day")

        let folded = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:fold
        SUMMARY:A very long meeting title that is folded
         across two lines
        DTSTART:20261005T090000Z
        DTEND:20261005T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let foldedEvents = try! ICalendarParser.parse(folded)
        check(foldedEvents[0].summary.hasPrefix("A very long meeting title that is folded") && foldedEvents[0].summary.contains("across two lines"), "folded lines are unfolded")

        let escaped = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:esc
        SUMMARY:Lunch\\, then a walk\\; maybe
        DTSTART:20261005T090000Z
        DTEND:20261005T100000Z
        END:VEVENT
        END:VCALENDAR
        """
        let escapedEvents = try! ICalendarParser.parse(escaped)
        check(escapedEvents[0].summary == "Lunch, then a walk; maybe", "text escapes are decoded")

        check((try? ICalendarParser.parse("<html>nope</html>")) == nil, "a non-calendar body is rejected")

        // MARK: - Recurrence

        func recurring(_ lines: String) -> ICalEvent {
            let text = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:r
            \(lines)
            END:VEVENT
            END:VCALENDAR
            """
            return try! ICalendarParser.parse(text)[0]
        }

        let weekly = recurring("""
        SUMMARY:Standup
        DTSTART:20261005T090000Z
        DTEND:20261005T091500Z
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=6
        """)
        let october = window(day(2026, 10, 1, calendar: calendar), day(2026, 11, 1, calendar: calendar))
        let weeklyOccurrences = Recurrence.occurrences(of: weekly, in: october)
        check(weeklyOccurrences.count == 6, "a COUNT-limited weekly rule emits six occurrences")
        check(weeklyOccurrences.allSatisfy { [2, 4, 6].contains(calendar.component(.weekday, from: $0.start)) },
              "weekly occurrences land on the listed weekdays")
        check(weeklyOccurrences.first?.start == day(2026, 10, 5, 9, 0, calendar: calendar), "the series starts at DTSTART")

        let excluded = recurring("""
        SUMMARY:Standup
        DTSTART:20261005T090000Z
        DTEND:20261005T091500Z
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=6
        EXDATE:20261007T090000Z
        """)
        check(Recurrence.occurrences(of: excluded, in: october).count == 5, "EXDATE removes one occurrence")

        let extra = recurring("""
        SUMMARY:Standup
        DTSTART:20261005T090000Z
        DTEND:20261005T091500Z
        RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=2
        RDATE:20261020T090000Z
        """)
        check(Recurrence.occurrences(of: extra, in: october).count == 3, "RDATE adds an occurrence")

        let monthly = recurring("""
        SUMMARY:Rent
        DTSTART:20260115T120000Z
        DTEND:20260115T130000Z
        RRULE:FREQ=MONTHLY;BYMONTHDAY=15;COUNT=3
        """)
        let spring = window(day(2026, 1, 1, calendar: calendar), day(2026, 5, 1, calendar: calendar))
        let monthlyOccurrences = Recurrence.occurrences(of: monthly, in: spring)
        check(monthlyOccurrences.count == 3, "a monthly rule emits one per month")
        check(monthlyOccurrences.map { calendar.component(.day, from: $0.start) } == [15, 15, 15], "monthly occurrences stay on the 15th")

        let secondTuesday = recurring("""
        SUMMARY:Book club
        DTSTART:20260113T180000Z
        DTEND:20260113T190000Z
        RRULE:FREQ=MONTHLY;BYDAY=2TU;COUNT=2
        """)
        let bookClub = Recurrence.occurrences(of: secondTuesday, in: spring)
        check(bookClub.count == 2, "an ordinal weekday rule emits the expected count")
        check(bookClub.allSatisfy { calendar.component(.weekday, from: $0.start) == 3 }, "ordinal weekday occurrences are Tuesdays")
        check(bookClub.first.map { calendar.component(.day, from: $0.start) } == 13, "2TU picks the second Tuesday")

        let octoberOnly = recurring("""
        SUMMARY:October review
        DTSTART:20260115T090000Z
        DTEND:20260115T100000Z
        RRULE:FREQ=MONTHLY;BYMONTH=10;COUNT=2
        """)
        let twoYears = window(day(2026, 1, 1, calendar: calendar), day(2028, 1, 1, calendar: calendar))
        let octoberOccurrences = Recurrence.occurrences(of: octoberOnly, in: twoYears)
        check(octoberOccurrences.count == 2, "BYMONTH prunes before COUNT is spent")
        check(octoberOccurrences.allSatisfy { calendar.component(.month, from: $0.start) == 10 }, "only October occurrences survive")

        let birthday = recurring("""
        SUMMARY:Birthday
        DTSTART:19900412T090000Z
        DTEND:19900412T100000Z
        RRULE:FREQ=YEARLY
        """)
        let thisYear = window(day(2026, 1, 1, calendar: calendar), day(2027, 1, 1, calendar: calendar))
        let birthdays = Recurrence.occurrences(of: birthday, in: thisYear)
        check(birthdays.count == 1, "a yearly rule lands once in the year")
        check(birthdays.first.map { calendar.component(.month, from: $0.start) } == 4, "the yearly occurrence keeps its month")

        let multiDay = recurring("""
        SUMMARY:Trip
        DTSTART;VALUE=DATE:20261020
        DTEND;VALUE=DATE:20261023
        """)
        let trip = Recurrence.occurrences(of: multiDay, in: october)
        check(trip.count == 1, "a long event is one occurrence")
        check(trip[0].end.timeIntervalSince(trip[0].start) == 3 * 86400, "a three-day event keeps its length")

        // MARK: - Snapshot

        let rows = CalendarMath.monthRows(monthStart: DayKey(year: 2026, month: 10, day: 1), calendar: calendar)
        let snapshot = SnapshotBuilder.build(
            events: parsed + RecurrenceFixture.weekly,
            monthRows: rows,
            selectedDay: DayKey(year: 2026, month: 10, day: 5),
            calendar: calendar
        )
        check(snapshot.busyDays.contains(DayKey(year: 2026, month: 10, day: 5)), "days with events are marked busy")
        check(!snapshot.busyDays.contains(DayKey(year: 2026, month: 10, day: 6)), "quiet days stay unmarked")
        check(snapshot.dayEvents.contains { $0.title == "Design review" }, "the selected day gets its events")
        check(snapshot.dayEvents.allSatisfy { $0.title != "Company holiday" }, "events from other days stay out")

        let allDayFirst = SnapshotBuilder.build(
            events: [RecurrenceFixture.timed, RecurrenceFixture.allDay],
            monthRows: rows,
            selectedDay: DayKey(year: 2026, month: 10, day: 6),
            calendar: calendar
        )
        check(allDayFirst.dayEvents.map { $0.title } == ["Holiday", "Morning call"], "all-day events sort first")

        let withoutAllDay = SnapshotBuilder.build(
            events: [RecurrenceFixture.timed, RecurrenceFixture.allDay],
            monthRows: rows,
            selectedDay: DayKey(year: 2026, month: 10, day: 6),
            calendar: calendar,
            includeAllDay: false
        )
        check(withoutAllDay.dayEvents.map { $0.title } == ["Morning call"], "hiding all-day events drops them from the agenda")

        let allDayOnly = SnapshotBuilder.build(
            events: [RecurrenceFixture.allDay],
            monthRows: rows,
            selectedDay: nil,
            calendar: calendar,
            includeAllDay: false
        )
        check(allDayOnly.busyDays.isEmpty, "a hidden all-day event leaves its day unmarked")
        check(SnapshotBuilder.build(
            events: [RecurrenceFixture.allDay],
            monthRows: rows,
            selectedDay: nil,
            calendar: calendar
        ).busyDays.contains(DayKey(year: 2026, month: 10, day: 6)), "an all-day event marks its day busy by default")

        let override = SnapshotBuilder.build(
            events: [RecurrenceFixture.master, RecurrenceFixture.movedInstance],
            monthRows: rows,
            selectedDay: DayKey(year: 2026, month: 10, day: 12),
            calendar: calendar
        )
        check(override.dayEvents.map { $0.title } == ["Moved standup"], "an override replaces the generated occurrence")
        check(override.dayEvents.first.map { calendar.component(.hour, from: $0.start) } == 11, "the override keeps its new time")

        // MARK: - Notch planner

        let sixth = window(day(2026, 10, 6, 0, 0, calendar: calendar), day(2026, 10, 7, 0, 0, calendar: calendar))
        let notchEvents = [
            RecurrenceFixture.timed,
            RecurrenceFixture.allDay,
            RecurrenceFixture.cancelled,
            RecurrenceFixture.free,
        ]
        let next = AgendaPlanner.firstStarting(in: sixth, events: notchEvents, calendar: calendar)
        check(next?.title == "Focus time", "the next notch event is the earliest timed one")
        check(next?.start == day(2026, 10, 6, 8, 0, calendar: calendar), "the planner keeps the event's start")

        let skipped = AgendaPlanner.firstStarting(
            in: sixth,
            events: notchEvents,
            calendar: calendar,
            skipping: [AgendaPlanner.Upcoming.key(uid: "focus", start: day(2026, 10, 6, 8, 0, calendar: calendar))]
        )
        check(skipped?.title == "Morning call", "an event already warned about is skipped")

        let late = window(day(2026, 10, 6, 9, 30, calendar: calendar), day(2026, 10, 6, 10, 30, calendar: calendar))
        check(AgendaPlanner.firstStarting(in: late, events: notchEvents, calendar: calendar) == nil, "an event that already started is not the next one")

        let emptyWindow = window(day(2026, 10, 6, 9, 0, calendar: calendar), day(2026, 10, 6, 9, 0, calendar: calendar))
        check(AgendaPlanner.firstStarting(in: emptyWindow, events: notchEvents, calendar: calendar) == nil, "an empty window has nothing to peek")

        check(RecurrenceFixture.free.isCancelled == false, "a free (TRANSP:TRANSPARENT) event still exists")
        check(RecurrenceFixture.cancelled.isCancelled, "a cancelled event is dropped")

        // MARK: - Notch peek

        let peekLocale = Locale(identifier: "en_US")
        let morning = day(2026, 10, 6, 8, 0, calendar: calendar)
        let timedPeek = NotchPeek.content(
            now: morning,
            events: [RecurrenceFixture.timed, RecurrenceFixture.allDay],
            calendar: calendar,
            locale: peekLocale,
            persistentChip: true
        )
        check(timedPeek.text.contains("Morning call"), "the peek names the next timed event")
        check(timedPeek.text.contains("9:00"), "the peek shows that event's time")
        check(timedPeek.validUntil == day(2026, 10, 6, 9, 0, calendar: calendar), "the peek turns over when the event starts")

        let evening = day(2026, 10, 6, 18, 0, calendar: calendar)
        let allDayPeek = NotchPeek.content(
            now: evening,
            events: [RecurrenceFixture.timed, RecurrenceFixture.allDay],
            calendar: calendar,
            locale: peekLocale,
            persistentChip: true
        )
        check(allDayPeek.text.contains("Holiday"), "with nothing timed left, an all-day event fills the peek")
        check(allDayPeek.text.contains("All day"), "the all-day peek says All day")
        check(allDayPeek.validUntil == day(2026, 10, 7, calendar: calendar), "the all-day peek lasts until midnight")

        let datePeek = NotchPeek.content(
            now: evening,
            events: [],
            calendar: calendar,
            locale: peekLocale,
            persistentChip: true
        )
        check(datePeek.key.hasPrefix("date:"), "an empty day still falls back to the date")

        let chipOff = NotchPeek.content(
            now: morning,
            events: [RecurrenceFixture.timed, RecurrenceFixture.allDay],
            calendar: calendar,
            locale: peekLocale,
            persistentChip: false
        )
        check(chipOff.key.hasPrefix("date:"), "with the chip off the peek stays a date")

        // MARK: - Daylight saving

        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        newYork.locale = Locale(identifier: "en_US")

        func allDaySeries(startingOn start: String) -> ICalEvent {
            let text = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:series-\(start)
            SUMMARY:All-day series
            DTSTART;VALUE=DATE:\(start)
            DTEND;VALUE=DATE:\(start)
            RRULE:FREQ=WEEKLY;COUNT=3
            END:VEVENT
            END:VCALENDAR
            """
            var event = try! ICalendarParser.parse(text, defaultTimeZone: newYork.timeZone)[0]
            // The feed normally carries an exclusive DTEND; the fixture above
            // reuses the start date, so give it a real next-day end.
            event.end = newYork.date(byAdding: .day, value: 1, to: event.start)!
            return event
        }

        let springAllDaySeries = allDaySeries(startingOn: "20260301")
        let marchWindow = window(day(2026, 3, 1, calendar: newYork), day(2026, 4, 1, calendar: newYork))
        let springOccurrences = Recurrence.occurrences(of: springAllDaySeries, in: marchWindow)
        check(springOccurrences.map { newYork.component(.day, from: $0.start) } == [1, 8, 15], "weekly all-day occurrences keep their days")
        check(springOccurrences.allSatisfy { newYork.startOfDay(for: $0.end) == $0.end }, "all-day occurrences end at midnight across spring forward")

        let springRows = CalendarMath.monthRows(monthStart: DayKey(year: 2026, month: 3, day: 1), calendar: newYork)
        let springSnapshot = SnapshotBuilder.build(events: [springAllDaySeries], monthRows: springRows, selectedDay: nil, calendar: newYork)
        check(!springSnapshot.busyDays.contains(DayKey(year: 2026, month: 3, day: 9)), "the day after spring forward is not marked busy")
        check(SnapshotBuilder.dayAgenda(events: [springAllDaySeries], day: DayKey(year: 2026, month: 3, day: 9), calendar: newYork).isEmpty, "an all-day series does not spill into the next day's agenda")
        check(SnapshotBuilder.dayAgenda(events: [springAllDaySeries], day: DayKey(year: 2026, month: 3, day: 8), calendar: newYork).count == 1, "the series still shows on its own spring-forward day")

        let fallAllDaySeries = allDaySeries(startingOn: "20261101")
        let novemberWindow = window(day(2026, 11, 1, calendar: newYork), day(2026, 12, 1, calendar: newYork))
        let fallOccurrences = Recurrence.occurrences(of: fallAllDaySeries, in: novemberWindow)
        check(fallOccurrences.map { newYork.component(.day, from: $0.start) } == [1, 8, 15], "weekly all-day occurrences survive fall back")
        check(fallOccurrences.allSatisfy { newYork.startOfDay(for: $0.end) == $0.end }, "all-day occurrences end at midnight across fall back")

        let fallRows = CalendarMath.monthRows(monthStart: DayKey(year: 2026, month: 11, day: 1), calendar: newYork)
        let fallSnapshot = SnapshotBuilder.build(events: [fallAllDaySeries], monthRows: fallRows, selectedDay: nil, calendar: newYork)
        check(!fallSnapshot.busyDays.contains(DayKey(year: 2026, month: 11, day: 9)), "the day after fall back is not marked busy")
        check(SnapshotBuilder.dayAgenda(events: [fallAllDaySeries], day: DayKey(year: 2026, month: 11, day: 9), calendar: newYork).isEmpty, "a 25-hour master does not leak an hour into later occurrences")

        // MARK: - Long-running series

        // A daily series from 2015 is some 4,300 occurrences away from a 2026
        // window. The generator used to spend its whole period budget reaching
        // 2018 and then stop, so the series silently vanished from later windows.
        func series(_ rule: String, from start: String) -> ICalEvent {
            let text = """
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:long-series
            SUMMARY:Long series
            DTSTART;VALUE=DATE:\(start)
            DTEND;VALUE=DATE:\(start)
            RRULE:\(rule)
            END:VEVENT
            END:VCALENDAR
            """
            var event = try! ICalendarParser.parse(text, defaultTimeZone: newYork.timeZone)[0]
            event.end = newYork.date(byAdding: .day, value: 1, to: event.start)!
            return event
        }

        let oldDaily = series("FREQ=DAILY", from: "20150101")
        let oneNovemberDay = window(day(2026, 11, 1, calendar: newYork), day(2026, 11, 2, calendar: newYork))
        check(Recurrence.occurrences(of: oldDaily, in: oneNovemberDay).count == 1, "a daily series from 2015 still reaches a 2026 window")
        check(SnapshotBuilder.dayAgenda(events: [oldDaily], day: DayKey(year: 2026, month: 11, day: 1), calendar: newYork).count == 1, "the old series shows in that day's agenda")

        let countedDaily = series("FREQ=DAILY;COUNT=3", from: "20150101")
        check(Recurrence.occurrences(of: countedDaily, in: oneNovemberDay).isEmpty, "COUNT is still counted from the series start")

        let oldWeekly = series("FREQ=WEEKLY;BYDAY=SU", from: "20150104")
        let oneNovemberWeek = window(day(2026, 11, 1, calendar: newYork), day(2026, 11, 8, calendar: newYork))
        check(Recurrence.occurrences(of: oldWeekly, in: oneNovemberWeek).count == 1, "a weekly series from 2015 still reaches a 2026 window")

        // Today's US holiday: a yearly all-day observance that landed on 1 Nov.
        let observance = series("FREQ=YEARLY;BYMONTH=11;BYDAY=1SU", from: "20071104")
        check(SnapshotBuilder.dayAgenda(events: [observance], day: DayKey(year: 2026, month: 11, day: 1), calendar: newYork).count == 1, "a yearly observance lands on its 2026 date")

        // A long event beginning before the window still overlaps it, so the
        // generator may not skip past it.
        var spanningSeries = series("FREQ=MONTHLY", from: "20260130")
        spanningSeries.end = newYork.date(byAdding: .day, value: 3, to: spanningSeries.start)!
        let earlyDecember = window(day(2026, 12, 1, calendar: newYork), day(2026, 12, 2, calendar: newYork))
        check(!Recurrence.occurrences(of: spanningSeries, in: earlyDecember).isEmpty, "an occurrence that started before the window still overlaps it")

        // MARK: - Deadline planner

        // One timer, armed to the next thing that actually happens. `timed` starts
        // at 09:00, so a 10-minute warning is due at 08:50.
        let halfPast = day(2026, 10, 6, 8, 30, calendar: calendar)
        func deadline(
            now: Date,
            events: [ICalEvent] = [RecurrenceFixture.timed],
            warnMinutes: Int = 10,
            persistentChip: Bool = true,
            // A month by default, so a test about warnings or midnight is not
            // answered by "the next fetch is in five minutes".
            refreshInterval: TimeInterval = 30 * 24 * 3600,
            lastFetch: Date? = nil,
            warningDismissAt: Date? = nil,
            skipping: Set<String> = [],
            warningsAllowed: Bool = true
        ) -> DeadlinePlanner.Deadline {
            DeadlinePlanner.next(
                now: now,
                events: events,
                calendar: calendar,
                locale: Locale(identifier: "en_US"),
                warnMinutes: warnMinutes,
                persistentChip: persistentChip,
                refreshInterval: refreshInterval,
                lastFetch: lastFetch ?? now,
                warningDismissAt: warningDismissAt,
                skipping: skipping,
                warningsAllowed: warningsAllowed
            )
        }

        let warningDue = deadline(now: halfPast)
        check(warningDue.reason == .warning, "the next deadline is the warning")
        check(warningDue.date == day(2026, 10, 6, 8, 50, calendar: calendar), "the warning is due ten minutes before the event")

        let alreadyWarned = deadline(
            now: halfPast,
            skipping: [AgendaPlanner.Upcoming.key(uid: "call", start: day(2026, 10, 6, 9, 0, calendar: calendar))]
        )
        check(alreadyWarned.reason != .warning, "a warned event is not proposed again")

        let overdue = deadline(now: day(2026, 10, 6, 8, 55, calendar: calendar))
        check(overdue.reason == .warning && overdue.date == day(2026, 10, 6, 8, 55, calendar: calendar), "a warning whose lead has passed is due now, once")

        let lakeOpen = deadline(now: halfPast, warningsAllowed: false)
        check(lakeOpen.reason != .warning, "warnings are not scheduled while the lake is open")

        let noEvents = deadline(now: halfPast, events: [])
        check(noEvents.reason == .midnight, "an empty day waits for midnight")
        check(noEvents.date == day(2026, 10, 7, calendar: calendar), "midnight is the next day's start")

        let allDayDeadline = deadline(now: halfPast, events: [RecurrenceFixture.allDay], warnMinutes: 0)
        check(allDayDeadline.reason == .midnight, "an all-day event has no start to warn about")

        let started = deadline(now: day(2026, 10, 6, 9, 30, calendar: calendar), events: [RecurrenceFixture.timed])
        check(started.reason != .warning, "an event that already started is not warned about")

        let fetchDue = deadline(
            now: halfPast,
            events: [],
            refreshInterval: 300,
            lastFetch: halfPast.addingTimeInterval(-200)
        )
        check(fetchDue.reason == .fetch, "the fetch interval is a deadline of its own")
        check(fetchDue.date == halfPast.addingTimeInterval(100), "the fetch is due one interval after the last")

        let dismissalDue = deadline(now: halfPast, events: [], warningDismissAt: halfPast.addingTimeInterval(30))
        check(dismissalDue.reason == .dismissal, "a warning peek's dismissal is a deadline")

        // MARK: - Errors and config

        check(FeedError.offline.message.contains("offline"), "offline has a plain-language message")
        check(FeedError.http(404).message.contains("404"), "an HTTP failure names the status")
        check(FeedError.unknownHost("calendar.google.com").message.contains("calendar.google.com"), "a DNS failure names the host")
        check(FeedError.notACalendar.message.contains("isn't a calendar feed"), "a bad payload is called out")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("gcaltest-\(UUID().uuidString)")
        let config = temp.appendingPathComponent("feeds.txt")
        let loader = FeedLoader(environment: ["GOOGLE_CALENDAR_FEEDS": config.path])
        loader.prepareConfigFile()
        check(FileManager.default.fileExists(atPath: config.path), "the config file is created")
        let template = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        check(template.contains("Secret address"), "the template explains what to paste")
        check(template.contains("right-click the lake"), "the template says how to get back to it")
        check(template.contains("calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics"), "the template ships the US holidays feed")
        check(template.contains("remove the #"), "the template says how to turn US holidays on")
        check(loader.feedURLs().isEmpty, "the template yields no feeds, US holidays included")

        let filled = """
        # a comment
        https://calendar.google.com/calendar/ical/abc/basic.ics

        ftp://ignore.example.com/feed.ics
        """
        try! filled.write(to: config, atomically: true, encoding: .utf8)
        check(loader.feedURLs().count == 1, "comments, blanks and non-web schemes are ignored")
        check(loader.feedURLs().first?.host == "calendar.google.com", "the feed URL is read")

        try? FileManager.default.removeItem(at: temp)

        print(failures == 0 ? "ical tests passed" : "\(failures) ical checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}

enum RecurrenceFixture {
    static let weekly = try! ICalendarParser.parse("""
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:standup
    SUMMARY:Standup
    DTSTART:20261005T090000Z
    DTEND:20261005T091500Z
    RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=6
    END:VEVENT
    END:VCALENDAR
    """)

    static let timed = try! ICalendarParser.parse("""
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:call
    SUMMARY:Morning call
    DTSTART:20261006T090000Z
    DTEND:20261006T100000Z
    END:VEVENT
    END:VCALENDAR
    """)[0]

    static let allDay = try! ICalendarParser.parse("""
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:holiday
    SUMMARY:Holiday
    DTSTART;VALUE=DATE:20261006
    DTEND;VALUE=DATE:20261007
    END:VEVENT
    END:VCALENDAR
    """)[0]

    static let free = try! ICalendarParser.parse("""
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:focus
    SUMMARY:Focus time
    TRANSP:TRANSPARENT
    DTSTART:20261006T080000Z
    DTEND:20261006T083000Z
    END:VEVENT
    END:VCALENDAR
    """)[0]

    static let cancelled = try! ICalendarParser.parse("""
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:cancelled
    SUMMARY:Cancelled sync
    STATUS:CANCELLED
    DTSTART:20261006T070000Z
    DTEND:20261006T073000Z
    END:VEVENT
    END:VCALENDAR
    """)[0]

    static let master = try! ICalendarParser.parse("""
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:series
    SUMMARY:Standup
    DTSTART:20261005T090000Z
    DTEND:20261005T091500Z
    RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=4
    END:VEVENT
    END:VCALENDAR
    """)[0]

    static let movedInstance = try! ICalendarParser.parse("""
    BEGIN:VCALENDAR
    BEGIN:VEVENT
    UID:series
    SUMMARY:Moved standup
    RECURRENCE-ID:20261012T090000Z
    DTSTART:20261012T110000Z
    DTEND:20261012T111500Z
    END:VEVENT
    END:VCALENDAR
    """)[0]
}
