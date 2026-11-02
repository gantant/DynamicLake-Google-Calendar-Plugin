import Foundation

// Small dependency-free harness: prints PASS/FAIL per check and exits non-zero
// when anything fails, like the other plugin's suites.

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS \(name)")
    } else {
        print("FAIL \(name)")
        failures += 1
    }
}

func utcCalendar(firstWeekday: Int = 1, locale: String = "en_US") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: locale)
    calendar.firstWeekday = firstWeekday
    return calendar
}

func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = day
    parts.hour = 12
    return calendar.date(from: parts)!
}

func dateTime(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
    var parts = DateComponents()
    parts.year = year
    parts.month = month
    parts.day = day
    parts.hour = hour
    parts.minute = minute
    return calendar.date(from: parts)!
}

/// macOS formats clock times with a narrow no-break space before AM/PM.
func normalised(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}

func componentCount(in node: Any) -> Int {
    var count = 0
    if let dict = node as? [String: Any] {
        if dict["type"] is String { count += 1 }
        for value in dict.values { count += componentCount(in: value) }
    } else if let array = node as? [Any] {
        for value in array { count += componentCount(in: value) }
    }
    return count
}

/// DynamicLake allows four nested stacks and scrolls, counting the outermost.
/// The command object itself is not a stack, so it is not counted here.
func stackDepth(in node: Any, depth: Int = 0) -> Int {
    if let dict = node as? [String: Any] {
        let isStack = ["hstack", "vstack", "zstack", "scroll"].contains(dict["type"] as? String ?? "")
        let next = isStack ? depth + 1 : depth
        var deepest = next
        for value in dict.values {
            deepest = max(deepest, stackDepth(in: value, depth: next))
        }
        return deepest
    }
    if let array = node as? [Any] {
        var deepest = depth
        for value in array {
            deepest = max(deepest, stackDepth(in: value, depth: depth))
        }
        return deepest
    }
    return depth
}

func findComponents(in node: Any, where predicate: ([String: Any]) -> Bool) -> [[String: Any]] {
    var found: [[String: Any]] = []
    if let dict = node as? [String: Any] {
        if dict["type"] is String, predicate(dict) { found.append(dict) }
        for value in dict.values { found += findComponents(in: value, where: predicate) }
    } else if let array = node as? [Any] {
        for value in array { found += findComponents(in: value, where: predicate) }
    }
    return found
}

/// DynamicLake accepts only letters, numbers, . _ : and - in identifier-like
/// fields; anything else makes it reject the whole lake frame.
func invalidIdentifiers(in node: Any) -> [String] {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    var bad: [String] = []
    if let array = node as? [Any] {
        for value in array { bad += invalidIdentifiers(in: value) }
        return bad
    }
    guard let dict = node as? [String: Any] else { return bad }
    for key in ["id", "actionID"] {
        if let value = dict[key] as? String, value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            bad.append("\(key)=\(value)")
        }
    }
    for value in dict.values { bad += invalidIdentifiers(in: value) }
    return bad
}

func content(of command: [String: Any]) -> [[String: Any]] {
    guard let lake = command["lake"] as? [String: Any], let content = lake["content"] as? [[String: Any]] else { return [] }
    return content
}

func buttons(in command: [String: Any]) -> [[String: Any]] {
    findComponents(in: command) { $0["type"] as? String == "button" }
}

func actionIDs(in command: [String: Any]) -> [String] {
    buttons(in: command).compactMap { $0["actionID"] as? String }
}

func dayButtons(in command: [String: Any]) -> [[String: Any]] {
    buttons(in: command).filter { ($0["actionID"] as? String)?.hasPrefix("day:") == true }
}

func allTexts(in command: [String: Any]) -> [String] {
    findComponents(in: command) { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
}

@main
enum CalendarModelTests {
    static func main() {
        let calendar = utcCalendar()
        let locale = Locale(identifier: "en_US")

        // MARK: - Grid

        let october = CalendarMath.monthStart(for: date(2026, 10, 25, calendar: calendar), calendar: calendar)
        check(october == DayKey(year: 2026, month: 10, day: 1), "month start derives from any day")

        let octoberRows = CalendarMath.monthRows(monthStart: october, calendar: calendar)
        check(octoberRows.count == 5, "October 2026 is five rows with a Sunday start")
        check(octoberRows.allSatisfy { $0.count == 7 }, "every row holds seven columns")
        check(octoberRows.flatMap { $0 }.compactMap { $0 }.count == 31, "October 2026 contributes 31 days")
        check(octoberRows[0][4] == DayKey(year: 2026, month: 10, day: 1), "October 1 sits in Thursday's column")
        check(octoberRows[0][0] == nil, "days before the first are blank, not neighbouring dates")
        check(octoberRows[4][6] == DayKey(year: 2026, month: 10, day: 31), "October 31 closes the grid")
        check(octoberRows.flatMap { $0 }.compactMap { $0 }.allSatisfy { $0.month == 10 }, "no other month leaks into the grid")

        let mondayRows = CalendarMath.monthRows(monthStart: october, calendar: utcCalendar(firstWeekday: 2))
        check(mondayRows[0][3] == DayKey(year: 2026, month: 10, day: 1), "a Monday start shifts October 1 to the fourth column")
        check(mondayRows.flatMap { $0 }.compactMap { $0 }.count == 31, "Monday start keeps all 31 days")

        let february = DayKey(year: 2026, month: 2, day: 1)
        let februaryRows = CalendarMath.monthRows(monthStart: february, calendar: calendar)
        check(februaryRows.count == 4, "February 2026 fits exactly four weeks and trims the empty rows")
        check(februaryRows.flatMap { $0 }.compactMap { $0 }.count == 28, "February 2026 has 28 days")

        let leapRows = CalendarMath.monthRows(monthStart: DayKey(year: 2028, month: 2, day: 1), calendar: calendar)
        check(leapRows.flatMap { $0 }.compactMap { $0 }.count == 29, "February 2028 has 29 days")
        check(leapRows.count == 5, "February 2028 needs five rows")

        // MARK: - Week strip

        let weekSunday = CalendarMath.weekDays(containing: DayKey(year: 2026, month: 10, day: 25), calendar: calendar)
        check(weekSunday.count == 7, "a week is seven days")
        check(weekSunday.first == DayKey(year: 2026, month: 10, day: 25), "Sunday start puts the selected Sunday first")
        check(weekSunday.last == DayKey(year: 2026, month: 10, day: 31), "week ends on Saturday")

        let weekMonday = CalendarMath.weekDays(containing: DayKey(year: 2026, month: 10, day: 25), calendar: utcCalendar(firstWeekday: 2))
        check(weekMonday.first == DayKey(year: 2026, month: 10, day: 19), "Monday start puts the week at the 19th")
        check(weekMonday.last == DayKey(year: 2026, month: 10, day: 25), "Monday-start week ends on the selected Sunday")

        let acrossMonth = CalendarMath.weekDays(containing: DayKey(year: 2026, month: 11, day: 1), calendar: utcCalendar(firstWeekday: 2))
        check(acrossMonth.first == DayKey(year: 2026, month: 10, day: 26), "weeks cross month boundaries")
        check(acrossMonth.last == DayKey(year: 2026, month: 11, day: 1), "a cross-month week still ends on its last day")

        // MARK: - Arithmetic

        check(CalendarMath.addMonths(-1, to: DayKey(year: 2026, month: 1, day: 1), calendar: calendar) == DayKey(year: 2025, month: 12, day: 1), "stepping back from January lands in December")
        check(CalendarMath.addMonths(1, to: DayKey(year: 2026, month: 12, day: 1), calendar: calendar) == DayKey(year: 2027, month: 1, day: 1), "stepping past December rolls the year")
        check(CalendarMath.addMonths(13, to: DayKey(year: 2026, month: 6, day: 1), calendar: calendar) == DayKey(year: 2027, month: 7, day: 1), "month arithmetic handles multi-month steps")

        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        check(CalendarMath.addDays(1, to: DayKey(year: 2026, month: 3, day: 7), calendar: newYork) == DayKey(year: 2026, month: 3, day: 8), "day arithmetic survives the spring DST change")
        check(CalendarMath.addDays(1, to: DayKey(year: 2026, month: 10, day: 31), calendar: newYork) == DayKey(year: 2026, month: 11, day: 1), "day arithmetic survives the autumn DST change")

        // MARK: - Formatting

        check(CalendarMath.monthTitle(october, calendar: calendar, locale: locale) == "October", "the month title leaves the year out")
        check(CalendarMath.weekdayName(DayKey(year: 2026, month: 10, day: 25), calendar: calendar, locale: locale) == "Sunday", "the agenda names the weekday")
        check(CalendarMath.weekdayShortName(DayKey(year: 2026, month: 10, day: 25), calendar: calendar, locale: locale) == "Sun", "the glance's weekday label stays short")
        check(CalendarMath.monthShortTitle(october, calendar: calendar, locale: locale) == "Oct", "the glance's month label stays short")
        check(CalendarMath.googleCalendarDayURL(DayKey(year: 2026, month: 10, day: 5)) == "https://calendar.google.com/calendar/r/day/2026/10/5", "events open Google Calendar, not Calendar.app")
        check(CalendarMath.weekdaySymbols(calendar: calendar, locale: locale).count == 7, "seven weekday headings")
        check(CalendarMath.weekdaySymbols(calendar: calendar, locale: locale).first == "Su", "Sunday-first headings start at Su")
        check(CalendarMath.weekdaySymbols(calendar: utcCalendar(firstWeekday: 2), locale: locale).first == "Mo", "Monday-first headings start at Mo")

        let padded = CalendarMath.paddedTimeColumn(["9:30", "12:30", "All day"])
        check(Set(padded.map { $0.count }).count == 1, "time column pads to one width")
        check(padded[2] == "All day", "shortest label keeps its text")
        check(padded[0].hasSuffix("9:30"), "padding is leading whitespace")

        // MARK: - Events

        let allDay = DayEvent(identifier: "a", title: "Conference", start: date(2026, 10, 25, calendar: calendar), end: date(2026, 10, 26, calendar: calendar), isAllDay: true, calendarTitle: "Work")
        let morning = DayEvent(identifier: "b", title: "Standup", start: dateTime(2026, 10, 25, 9, 30, calendar: calendar), end: dateTime(2026, 10, 25, 10, 0, calendar: calendar), isAllDay: false, calendarTitle: "Work")
        let noon = DayEvent(identifier: "c", title: "Design review", start: dateTime(2026, 10, 25, 12, 0, calendar: calendar), end: dateTime(2026, 10, 25, 13, 0, calendar: calendar), isAllDay: false, calendarTitle: "Work")
        let sorted = DayEvent.sorted([noon, allDay, morning])
        check(sorted.map { $0.identifier } == ["a", "b", "c"], "all-day events lead, then start time")
        check(normalised(morning.timeText(calendar: calendar, locale: locale)) == "9:30 AM", "timed events show their clock time")
        check(allDay.timeText(calendar: calendar, locale: locale) == "All day", "all-day events say All day")

        // MARK: - Split month lake

        let today = DayKey(year: 2026, month: 10, day: 25)
        let busyDay = DayKey(year: 2026, month: 10, day: 28)
        let quietDay = DayKey(year: 2026, month: 10, day: 27)

        let monthState = LakeState(
            monthStart: october,
            today: today,
            selectedDay: today,
            snapshot: CalendarSnapshot(busyDays: [busyDay], dayEvents: sorted),
            todayEvents: sorted,
            load: .ready,
            calendar: calendar,
            locale: locale
        )

        let monthCommand = LakeView.lakeCommand(state: monthState, requestID: "test-1")
        let monthLake = monthCommand["lake"] as? [String: Any] ?? [:]
        check(monthCommand["type"] as? String == "lake", "month render is a lake command")
        check(monthCommand["schemaVersion"] as? Int == 1, "lake commands carry schema version 1")
        check(monthLake["hideHeader"] as? Bool == true, "the card hides DynamicLake's header row")
        check(content(of: monthCommand).count == 2, "the split view is a header plus one row")
        check(stackDepth(in: monthCommand) <= 4, "the split view stays within the stack nesting limit")
        check(componentCount(in: monthCommand) <= 160, "the split view stays within the component budget")

        // MARK: - DynaGlance

        let glance = monthLake["glance"] as? [String: Any] ?? [:]
        check(!glance.isEmpty, "the lake carries its own DynaGlance design")
        check(glance["hideHeader"] as? Bool == true, "the glance hides DynamicLake's header")
        let glanceTexts = findComponents(in: glance) { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
        check(glanceTexts.contains("25"), "the glance leads with today's date")
        let glanceWeekday = findComponents(in: glance) { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "SUN" }.first
        check(glanceWeekday?["tint"] as? String == "red", "the glance's weekday is red")
        check(glanceWeekday?["style"] as? String == "compact", "the glance's weekday stays small")
        let glanceMonth = findComponents(in: glance) { component in
            (component["type"] as? String) == "text" && ((component["text"] as? String) ?? "").contains("OCT")
        }.first
        check(glanceMonth?["tint"] as? String == "gray", "the glance's month keeps its own colour")
        check(((glanceMonth?["text"] as? String) ?? "").hasPrefix("·"), "the month keeps the separator with it, not the weekday")
        let glanceDayNumber = findComponents(in: glance) { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "25" }.first
        check(glanceDayNumber?["tint"] as? String == "white", "the glance's day number is white")
        check(glanceDayNumber?["style"] as? String == "large", "the glance's day number uses the biggest style")
        check(glanceDayNumber?["weight"] as? String == "bold", "the glance's day number is bold")

        let glanceMarkers = findComponents(in: glance) {
            ($0["type"] as? String) == "text"
                && ["●", "▮"].contains(($0["text"] as? String) ?? "")
                && ($0["tint"] as? String) != nil
        }
        check(glanceMarkers.count == 3, "every glance row carries a category marker")
        check(Set(glanceMarkers.compactMap { $0["tint"] as? String }).count == 1, "events from one calendar share a marker colour")
        check(LakeView.calendarTint(for: "Work") != LakeView.calendarTint(for: "Home"), "different calendars get different marker colours")
        check(LakeView.calendarTint(for: "") == "gray", "a feed without a name keeps a neutral marker")
        check(glanceTexts.contains("Standup"), "the glance previews today's agenda")
        let glanceTrimmed = glanceTexts.map { $0.trimmingCharacters(in: .whitespaces) }
        check(glanceTrimmed.contains("All day"), "the glance keeps all-day events")
        check(findComponents(in: glance) { ($0["contextMenu"] as? [[String: Any]]) != nil }.isEmpty, "glance rows carry no lake-only open action")
        check(findComponents(in: glance) { ($0["id"] as? String)?.hasPrefix("glance-") == true }.count == 3, "glance rows keep their own ids")
        check(buttons(in: glance).isEmpty, "the glance stays a read-only preview")

        // The glance's rows must live in a `scroll` that is a direct child of the
        // surface's content: DynamicLake says a scroll fills the surface's free
        // height, which it cannot do when nested inside a stack. The date stays
        // above it so it does not scroll away with the events.
        let glanceContent = glance["content"] as? [[String: Any]] ?? []
        check(glanceContent.count == 2, "the glance is a date block plus an event list")
        check(glanceContent.first?["type"] as? String == "vstack", "the date block sits above the list")
        check(glanceContent.last?["type"] as? String == "scroll", "the glance's events are a scroll")
        check((glanceContent.last?["children"] as? [Any])?.count == 3, "every glance row is inside that scroll")
        check((glanceContent.last?["axis"] as? String ?? "vertical") == "vertical", "the glance scrolls vertically")
        check(glanceContent.first.flatMap { findComponents(in: $0) { ($0["id"] as? String)?.hasPrefix("glance-event-") == true } }?.isEmpty == true,
              "the fixed date block holds no event rows")

        // A glance holds a busy day at 24 rows plus a summary line, so it cannot
        // run past DynamicLake's 160-component glance budget.
        let busyEvents = (0..<40).map { index in
            DayEvent(
                identifier: "busy-\(index)",
                title: "Meeting \(index)",
                start: dateTime(2026, 10, 25, 8 + index % 12, 0, calendar: calendar),
                end: dateTime(2026, 10, 25, 8 + index % 12, 30, calendar: calendar),
                isAllDay: false,
                calendarTitle: "Work"
            )
        }
        let busyGlance = LakeView.glanceSurface(LakeState(
            monthStart: october,
            today: today,
            selectedDay: today,
            snapshot: CalendarSnapshot(dayEvents: busyEvents),
            todayEvents: DayEvent.sorted(busyEvents),
            load: .ready,
            calendar: calendar,
            locale: locale
        ))
        let busyContent = busyGlance["content"] as? [[String: Any]] ?? []
        let busyRows = busyContent.last?["children"] as? [[String: Any]] ?? []
        check(busyRows.count == LakeView.glanceRowLimit + 1, "a busy glance caps its rows and adds one summary line")
        check(findComponents(in: busyGlance) { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "+16 more" }.count == 1, "the summary line counts the events it left out")
        check(findComponents(in: busyGlance) { _ in true }.count <= 160, "a busy glance stays inside DynamicLake's 160-component budget")

        // DynamicLake only accepts `size` on image, button and status components
        // in lake content; a glance is fixed-size, so a sized child makes it
        // reject the whole frame and fall back to its placeholder. Every glance
        // state is checked so a marker redesign cannot reintroduce the field.
        let glanceStates: [(String, LakeState)] = [
            ("ready", monthState),
            ("loading", LakeState(monthStart: october, today: today, load: .loading, calendar: calendar, locale: locale)),
            ("setup", LakeState(monthStart: october, today: today, load: .setup, calendar: calendar, locale: locale)),
            ("failed", LakeState(monthStart: october, today: today, load: .failed("offline"), calendar: calendar, locale: locale)),
        ]
        for (name, state) in glanceStates {
            let surface = LakeView.glanceSurface(state)
            check(findComponents(in: surface) { $0["size"] != nil }.isEmpty, "the \(name) glance sets no size field")
            check(findComponents(in: surface) { ($0["type"] as? String) == "image" }.isEmpty, "the \(name) glance carries no images")
        }

        let monthDayButtons = dayButtons(in: monthCommand)
        check(monthDayButtons.count == 31, "every day of the month is a button")
        check(monthDayButtons.allSatisfy { ($0["shape"] as? String) == "roundedRect" }, "days use capsule buttons so the number is visible")
        check(monthDayButtons.allSatisfy { ($0["id"] as? String) != nil }, "each day button has an id")
        check(monthDayButtons.allSatisfy { ($0["title"] as? String)?.allSatisfy(\.isNumber) == true }, "no dot rides along with the day number")
        check(actionIDs(in: monthCommand).contains("prevMonth"), "the split view offers a previous-month button")
        check(actionIDs(in: monthCommand).contains("nextMonth"), "the split view offers a next-month button")
        check(!actionIDs(in: monthCommand).contains("today"), "the current month hides the Today button")
        check(!allTexts(in: monthCommand).contains { $0.contains("feed failed") }, "a clean load says nothing about feeds")

        let degradedState = LakeState(
            monthStart: october,
            today: today,
            selectedDay: today,
            snapshot: CalendarSnapshot(busyDays: [busyDay], dayEvents: sorted),
            feedWarning: "1 feed failed",
            load: .ready,
            calendar: calendar,
            locale: locale
        )
        let degradedCommand = LakeView.lakeCommand(state: degradedState, requestID: "test-1b")
        let warningRow = findComponents(in: degradedCommand) { component in
            (component["children"] as? [[String: Any]])?.contains { ($0["text"] as? String) == "1 feed failed" } == true
        }.first
        check(warningRow != nil, "a partial feed failure is shown beside the agenda")
        check(((warningRow?["contextMenu"] as? [[String: Any]]) ?? []).contains { ($0["actionID"] as? String) == "openFeeds" }, "the warning reaches feeds.txt")
        check(allTexts(in: degradedCommand).contains { $0 == "Design review" }, "the feeds that answered are still shown")

        let awayMonthState = LakeState(
            monthStart: CalendarMath.addMonths(1, to: october, calendar: calendar),
            today: today,
            selectedDay: DayKey(year: 2026, month: 11, day: 1),
            snapshot: .empty,
            load: .ready,
            calendar: calendar,
            locale: locale
        )
        check(actionIDs(in: LakeView.lakeCommand(state: awayMonthState, requestID: "test-1a")).contains("today"), "another month offers a jump back to today")
        let awayGlanceTexts = findComponents(in: LakeView.glanceSurface(awayMonthState)) { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
        check(awayGlanceTexts.contains("25"), "the glance keeps describing today after paging the lake away")
        check(awayGlanceTexts.contains { $0.contains("OCT") }, "the glance labels today's month, not the browsed one")

        check(monthDayButtons.first { ($0["actionID"] as? String) == "day:2026-10-25" }?["tint"] as? String == "red", "the selected day is red")
        check(monthDayButtons.first { ($0["actionID"] as? String) == "day:2026-10-28" }?["tint"] as? String == "blue", "a day with events is blue")
        check(monthDayButtons.first { ($0["actionID"] as? String) == "day:2026-10-27" }?["tint"] as? String == "gray", "an empty day stays gray")

        let header = content(of: monthCommand).first ?? [:]
        check(header["type"] as? String == "hstack", "the month title lives in a stack")
        check(allTexts(in: header).contains("October"), "the header names the month without a year")
        check((header["padding"] as? [String: Any])?["top"] as? Int == 6, "the header carries air under the notch")
        check(findComponents(in: header) { ($0["contextMenu"] as? [[String: Any]]) != nil }.count == 1, "the header carries the feeds.txt right-click menu")
        let headerMenu = findComponents(in: header) { ($0["contextMenu"] as? [[String: Any]]) != nil }
            .compactMap { ($0["contextMenu"] as? [[String: Any]]) }
            .first ?? []
        check(headerMenu.compactMap { $0["actionID"] as? String }.contains("openFeeds"), "the right-click menu opens feeds.txt")
        check(headerMenu.compactMap { $0["actionID"] as? String }.contains("closeLake"), "the right-click menu can close the lake")

        let splitRow = content(of: monthCommand)[1]
        check((splitRow["contextMenu"] as? [[String: Any]]) != nil, "right-clicking the card body reaches the same menu")
        let columns = splitRow["children"] as? [[String: Any]] ?? []
        check(columns.count == 9, "the row is the agenda, the divider, and seven day columns")
        let agenda = columns.first ?? [:]
        check(agenda["type"] as? String == "vstack", "the agenda sits on the left")

        let agendaTexts = findComponents(in: agenda) { $0["type"] as? String == "text" }
        let dayNumber = agendaTexts.first { ($0["text"] as? String) == "25" }
        check(dayNumber?["style"] as? String == "large" && dayNumber?["weight"] as? String == "bold", "the selected day is big and bold over the agenda")
        check(dayNumber?["tint"] as? String == "red", "the agenda's date is red")
        check(agendaTexts.contains { ($0["text"] as? String) == "Sunday" }, "the weekday name sits beside the day number")

        // The lake's agenda only: the glance carries a scroll of its own.
        let scrolls = findComponents(in: content(of: monthCommand)) { $0["type"] as? String == "scroll" }
        check(scrolls.count == 1, "the agenda scrolls")
        check((scrolls.first?["children"] as? [Any])?.count == 3, "every event gets a row")
        let trimmed = allTexts(in: monthCommand).map { normalised($0).trimmingCharacters(in: .whitespaces) }
        check(trimmed.contains("All day"), "all-day events read All day")
        check(trimmed.contains("9:30 AM"), "timed events show their time")
        let rowMenus = findComponents(in: monthCommand) { ($0["contextMenu"] as? [[String: Any]]) != nil }
            .compactMap { $0["contextMenu"] as? [[String: Any]] }
            .filter { menu in menu.contains { (($0["actionID"] as? String) ?? "").hasPrefix("open:") } }
        check(rowMenus.count == 3, "every event row carries an open action")
        check(rowMenus.contains { menu in menu.contains { ($0["actionID"] as? String) == "open:1" } }, "the row action carries the event index")
        check(buttons(in: monthCommand).filter { ($0["actionID"] as? String)?.hasPrefix("open:") == true }.isEmpty, "no arrow button eats the row's width")

        check(columns.dropFirst().dropFirst().allSatisfy { $0["type"] as? String == "vstack" }, "the calendar columns sit on the right")
        check(columns[1]["type"] as? String == "vstack", "a divider separates the two halves")
        check(findComponents(in: columns[1]) { ($0["text"] as? String) == "│" }.count > 1, "the divider is drawn")

        let calendarDays = columns.dropFirst(2).flatMap { dayButtons(in: $0) }
        check(calendarDays.count == 31, "the right half holds the whole month")
        check(calendarDays.allSatisfy { ($0["size"] as? Int) == LakeView.daySize }, "grid days keep the compact capsule")
        check(invalidIdentifiers(in: monthCommand).isEmpty, "month identifiers stay inside DynamicLake's character set")

        let flatState = LakeState(
            monthStart: october,
            today: today,
            selectedDay: today,
            snapshot: CalendarSnapshot(busyDays: [busyDay], dayEvents: sorted),
            load: .ready,
            markBusyDays: false,
            calendar: calendar,
            locale: locale
        )
        let flatButtons = dayButtons(in: LakeView.lakeCommand(state: flatState, requestID: "test-8"))
        check(flatButtons.first { ($0["actionID"] as? String) == "day:2026-10-28" }?["tint"] as? String == "gray", "the highlight setting turns the blue off")

        let emptyDayState = LakeState(
            monthStart: october,
            today: today,
            selectedDay: quietDay,
            snapshot: .empty,
            load: .ready,
            calendar: calendar,
            locale: locale
        )
        let emptyCommand = LakeView.lakeCommand(state: emptyDayState, requestID: "test-3")
        check(allTexts(in: emptyCommand).contains("No events"), "an empty day says so")
        check(allTexts(in: LakeView.glanceSurface(emptyDayState)).contains("No events"), "an empty today leaves the glance saying so")
        check(findComponents(in: emptyCommand) { ($0["type"] as? String) == "scroll" }.isEmpty, "an empty day draws no scroll")
        check(dayButtons(in: emptyCommand).first { ($0["actionID"] as? String) == "day:2026-10-27" }?["tint"] as? String == "red", "the selection is red even with nothing to show")

        // MARK: - Compact week lake

        let compactStripState = LakeState(
            monthStart: october,
            today: today,
            selectedDay: today,
            snapshot: CalendarSnapshot(busyDays: [busyDay], dayEvents: sorted),
            load: .ready,
            layout: .compact,
            calendar: calendar,
            locale: locale
        )
        let stripCommand = LakeView.lakeCommand(state: compactStripState, requestID: "test-2")
        check(content(of: stripCommand).count == 2, "the small card is a week header plus the strip")
        check(stackDepth(in: stripCommand) <= 4, "the small card stays within the stack nesting limit")
        check(componentCount(in: stripCommand) <= 160, "the small card stays within the component budget")

        let stripDays = dayButtons(in: stripCommand)
        check(stripDays.count == 7, "the small card shows exactly one week")
        check(stripDays.first.map { ($0["actionID"] as? String) } == "day:2026-10-25", "the strip starts on the selected week")
        check(stripDays.last.map { ($0["actionID"] as? String) } == "day:2026-10-31", "the strip ends on Saturday")
        check(stripDays.first?["tint"] as? String == "red", "the selected day is red in the strip")
        check(stripDays[3]["tint"] as? String == "blue", "a busy day is blue in the strip")
        check(actionIDs(in: stripCommand).contains("prevWeek"), "the strip steps back a week")
        check(actionIDs(in: stripCommand).contains("nextWeek"), "the strip steps forward a week")
        check(!actionIDs(in: stripCommand).contains("prevMonth"), "the small card has no month arrows")
        check(!actionIDs(in: stripCommand).contains("today"), "the current week hides the Today button")

        let awayStripState = LakeState(
            monthStart: DayKey(year: 2026, month: 11, day: 1),
            today: today,
            selectedDay: CalendarMath.addDays(7, to: today, calendar: calendar),
            snapshot: .empty,
            load: .ready,
            layout: .compact,
            calendar: calendar,
            locale: locale
        )
        check(actionIDs(in: LakeView.lakeCommand(state: awayStripState, requestID: "test-2b")).contains("today"), "another week offers a jump back to today")
        check(allTexts(in: stripCommand).filter { ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"].contains($0) }.count == 7, "the strip keeps a heading per day")
        check(stripDays.allSatisfy { ($0["size"] as? Int) == LakeView.compactDaySize }, "the small card's days are large")
        let stripMonth = findComponents(in: stripCommand) { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "October" }.first
        check(stripMonth?["style"] as? String == "large", "the small card's month is a headline")
        check(invalidIdentifiers(in: stripCommand).isEmpty, "strip identifiers stay inside DynamicLake's character set")

        let compactDayState = LakeState(
            monthStart: october,
            today: today,
            selectedDay: DayKey(year: 2026, month: 10, day: 25),
            snapshot: CalendarSnapshot(busyDays: [busyDay], dayEvents: sorted),
            load: .ready,
            layout: .compact,
            compactShowsEvents: true,
            calendar: calendar,
            locale: locale
        )
        let compactDayCommand = LakeView.lakeCommand(state: compactDayState, requestID: "test-3a")
        check(content(of: compactDayCommand).count == 2, "a tapped day replaces the strip with its agenda")
        check(dayButtons(in: compactDayCommand).isEmpty, "the strip is gone while the agenda shows")
        check(actionIDs(in: compactDayCommand).contains("weekView"), "the agenda can go back to the week")
        check(!actionIDs(in: compactDayCommand).contains("today"), "today's agenda hides the Today button")

        let otherDayState = LakeState(
            monthStart: october,
            today: today,
            selectedDay: quietDay,
            snapshot: .empty,
            load: .ready,
            layout: .compact,
            compactShowsEvents: true,
            calendar: calendar,
            locale: locale
        )
        check(actionIDs(in: LakeView.lakeCommand(state: otherDayState, requestID: "test-3b")).contains("today"), "another day offers a jump back to today")
        let compactTexts = allTexts(in: compactDayCommand).map { normalised($0).trimmingCharacters(in: .whitespaces) }
        check(compactTexts.contains("Design review"), "the compact agenda names the events")
        check(compactTexts.contains("9:30 AM"), "the compact agenda keeps the times")
        // Scoped to the card's own content: the glance also renders the day
        // number (in white), and dictionary traversal order is not stable.
        let compactDayNumber = findComponents(in: content(of: compactDayCommand)) { ($0["type"] as? String) == "text" && ($0["text"] as? String) == "25" }.first
        check(compactDayNumber?["style"] as? String == "large", "the compact agenda leads with the day number")
        check(compactDayNumber?["tint"] as? String == "red", "the compact agenda's day number is red")
        check(findComponents(in: compactDayCommand) { ($0["type"] as? String) == "scroll" }.count == 1, "the compact agenda scrolls")
        check(invalidIdentifiers(in: compactDayCommand).isEmpty, "compact agenda identifiers stay inside DynamicLake's character set")

        // MARK: - Day rollover

        let october31 = DayKey(year: 2026, month: 10, day: 31)
        let november1 = DayKey(year: 2026, month: 11, day: 1)
        let followed = DayRollover.follow(previousToday: october31, today: november1, selectedDay: october31, monthStart: october, calendar: calendar)
        check(followed.selectedDay == november1, "midnight moves the card to the new day")
        check(followed.monthStart == DayKey(year: 2026, month: 11, day: 1), "the first of the month follows too")

        let browsed = DayRollover.follow(previousToday: october31, today: november1, selectedDay: quietDay, monthStart: october, calendar: calendar)
        check(browsed.selectedDay == quietDay, "a day the user browsed to is left alone")
        check(browsed.monthStart == october, "the browsed month is left alone")

        let unselected = DayRollover.follow(previousToday: october31, today: november1, selectedDay: nil, monthStart: october, calendar: calendar)
        check(unselected.selectedDay == november1, "an empty selection follows today")

        // MARK: - Feed states

        let setupState = LakeState(monthStart: october, today: today, selectedDay: nil, snapshot: .empty, load: .setup, calendar: calendar, locale: locale)
        let setupCommand = LakeView.lakeCommand(state: setupState, requestID: "test-4")
        check(allTexts(in: setupCommand).contains("Add your calendar"), "an unconfigured plugin explains the setup step")
        check(actionIDs(in: setupCommand).filter { $0 == "openFeeds" }.count == 1, "the setup card opens feeds.txt")
        check(invalidIdentifiers(in: setupCommand).isEmpty, "setup identifiers stay inside DynamicLake's character set")

        let compactSetupState = LakeState(monthStart: october, today: today, selectedDay: nil, snapshot: .empty, load: .setup, layout: .compact, calendar: calendar, locale: locale)
        check(allTexts(in: LakeView.lakeCommand(state: compactSetupState, requestID: "test-4a")).contains("Add your calendar"), "the small card explains the setup too")

        let failedState = LakeState(monthStart: october, today: today, selectedDay: nil, snapshot: .empty, load: .failed("You're offline. Reconnect and try again."), calendar: calendar, locale: locale)
        let failedCommand = LakeView.lakeCommand(state: failedState, requestID: "test-5")
        check(allTexts(in: failedCommand).contains("Can't load your calendar"), "a failed fetch says so")
        check(allTexts(in: failedCommand).contains("You're offline. Reconnect and try again."), "the failure reason is shown")
        check(actionIDs(in: failedCommand).contains("refresh"), "a failed fetch offers a retry")
        check(actionIDs(in: failedCommand).contains("openFeeds"), "a failed fetch also reaches feeds.txt")

        let loadingState = LakeState(monthStart: october, today: today, selectedDay: nil, snapshot: .empty, load: .loading, calendar: calendar, locale: locale)
        check(allTexts(in: LakeView.lakeCommand(state: loadingState, requestID: "test-6")).contains("Loading calendar"), "the first fetch shows a loading card")
        check(invalidIdentifiers(in: failedCommand).isEmpty, "error identifiers stay inside DynamicLake's character set")

        // MARK: - Long titles

        let longTitle = String(repeating: "Very long meeting title ", count: 6)
        let longEvent = DayEvent(identifier: "long", title: longTitle, start: date(2026, 10, 27, calendar: calendar), end: date(2026, 10, 27, calendar: calendar).addingTimeInterval(3600), isAllDay: false, calendarTitle: "Work")
        let longState = LakeState(
            monthStart: october,
            today: today,
            selectedDay: quietDay,
            snapshot: CalendarSnapshot(busyDays: [], dayEvents: [longEvent]),
            load: .ready,
            calendar: calendar,
            locale: locale
        )
        let longTexts = allTexts(in: LakeView.lakeCommand(state: longState, requestID: "test-7"))
        check(longTexts.contains { $0.count <= 34 && $0.hasSuffix("…") }, "long event titles are truncated with an ellipsis")

        // MARK: - Frame size

        func frameBytes(_ command: [String: Any]) -> Int {
            (try? JSONSerialization.data(withJSONObject: command))?.count ?? .max
        }
        check(frameBytes(monthCommand) < 64 * 1024, "the split frame fits DynamicLake's 64 KB message limit")
        check(frameBytes(stripCommand) < 64 * 1024, "the compact frame fits DynamicLake's 64 KB message limit")

        // MARK: - Layout detection

        check(LakeLayout(size: "small") == .compact, "a small lake gets the week card")
        check(LakeLayout(size: "notification") == .compact, "a notification-sized lake gets the week card")
        check(LakeLayout(size: "big") == .split, "a big lake gets the split card")
        check(LakeLayout(size: nil) == .split, "an unknown size falls back to the split card")

        print(failures == 0 ? "calendar model tests passed" : "\(failures) calendar model checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
