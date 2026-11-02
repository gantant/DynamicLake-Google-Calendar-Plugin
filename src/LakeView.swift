import Foundation

/// The lake's shape is fixed by plugin.json, and DynamicLake reports it in
/// `lakeOpened`. A small lake only has room for a week, so the card has two
/// very different builds.
enum LakeLayout: Equatable {
    case split
    case compact

    init(size: String?) {
        switch (size ?? "").lowercased() {
        case "small", "compact", "notification":
            self = .compact
        default:
            self = .split
        }
    }
}

struct LakeState {
    enum Load: Equatable {
        case ready
        case loading
        case setup
        case failed(String)
    }

    var monthStart: DayKey
    var today: DayKey
    var selectedDay: DayKey?
    var busyDays: Set<DayKey>
    var dayEvents: [DayEvent]
    var todayEvents: [DayEvent]
    /// Set when only part of the calendar loaded, such as one feed failing.
    var feedWarning: String?
    var load: Load
    var markBusyDays: Bool
    var layout: LakeLayout
    var compactShowsEvents: Bool
    var calendar: Calendar
    var locale: Locale

    init(
        monthStart: DayKey,
        today: DayKey,
        selectedDay: DayKey? = nil,
        snapshot: CalendarSnapshot = .empty,
        todayEvents: [DayEvent] = [],
        feedWarning: String? = nil,
        load: Load,
        markBusyDays: Bool = true,
        layout: LakeLayout = .split,
        compactShowsEvents: Bool = false,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        self.monthStart = monthStart
        self.today = today
        self.selectedDay = selectedDay
        self.busyDays = snapshot.busyDays
        self.dayEvents = snapshot.dayEvents
        self.todayEvents = todayEvents
        self.feedWarning = feedWarning
        self.load = load
        self.markBusyDays = markBusyDays
        self.layout = layout
        self.compactShowsEvents = compactShowsEvents
        self.calendar = calendar
        self.locale = locale
    }

    /// The day the agenda describes: the selection, or today when nothing is
    /// selected yet.
    var agendaDay: DayKey { selectedDay ?? today }

    /// The Today button is a way back, so it only appears once the card has
    /// left the current month or week.
    var isViewingCurrentMonth: Bool {
        monthStart == DayKey(year: today.year, month: today.month, day: 1)
    }

    var isViewingCurrentWeek: Bool {
        CalendarMath.weekStart(containing: agendaDay, calendar: calendar)
            == CalendarMath.weekStart(containing: today, calendar: calendar)
    }
}

/// Builds the `lake` command payload. Every element here is a DynamicLake
/// component: the plugin never draws, it only describes.
enum LakeView {
    /// Capsule height for a day number. 16 still keeps six rows, the weekday
    /// labels and the header inside the normal (410 × 186) card, and leaves the
    /// agenda the width its rows need.
    static let daySize = 16
    /// The small card has the height to spare, so its days are much bigger.
    static let compactDaySize = 26
    /// Header chevrons are a touch taller than the day capsules, so they read as
    /// controls rather than labels.
    static let headerIconSize = 18
    static let compactHeaderIconSize = 16
    /// Fixed gap between calendar columns: flexible spacers would let the grid
    /// claim the agenda's half of the card.
    static let columnSpacing = 2
    static let dividerGlyphs = 9
    static let dividerPadding = 3

    static func lakeCommand(state: LakeState, requestID: String) -> [String: Any] {
        var lake: [String: Any] = ["hideHeader": true]

        switch state.load {
        case .ready:
            lake["content"] = state.layout == .compact ? compactContent(state) : splitContent(state)
        case .loading:
            lake["content"] = noticeContent(
                state,
                symbol: "calendar",
                tint: "gray",
                heading: "Loading calendar",
                detail: "Fetching your feeds",
                buttons: []
            )
        case .setup:
            lake["content"] = noticeContent(
                state,
                symbol: "calendar.badge.plus",
                tint: "blue",
                heading: "Add your calendar",
                detail: "Paste the secret iCal address into feeds.txt",
                buttons: [("Open feeds.txt", "openFeeds")]
            )
        case .failed(let message):
            lake["content"] = noticeContent(
                state,
                symbol: "wifi.exclamationmark",
                tint: "orange",
                heading: "Can't load your calendar",
                detail: message,
                buttons: [("Feeds", "openFeeds"), ("Try again", "refresh")]
            )
        }

        // DynaGlance's right side is much smaller than a lake, so it gets its
        // own design rather than a squeezed copy of the card.
        lake["glance"] = glanceSurface(state)

        return [
            "schemaVersion": 1,
            "requestID": requestID,
            "type": "lake",
            "lake": lake,
        ]
    }

    // MARK: - DynaGlance

    /// What DynaGlance shows when the user picks the calendar. It always
    /// describes today, not whatever day the lake happens to have selected.
    static func glanceSurface(_ state: LakeState) -> [String: Any] {
        switch state.load {
        case .ready:
            return ["hideHeader": true, "content": glanceContent(state)]
        case .loading:
            return glanceNotice(tint: "gray", text: "Loading calendar")
        case .setup:
            return glanceNotice(tint: "blue", text: "Add your calendar")
        case .failed:
            return glanceNotice(tint: "orange", text: "Calendar offline")
        }
    }

    /// Three levels, like the card: a small uppercase weekday and month, the
    /// oversized day number, then the day's events.
    private static func glanceContent(_ state: LakeState) -> [[String: Any]] {
        let day = state.today
        // Today's month, not the month the lake has been paged to.
        let month = DayKey(year: day.year, month: day.month, day: 1)
        let weekday = CalendarMath.weekdayShortName(day, calendar: state.calendar, locale: state.locale)
            .uppercased(with: state.locale)
        let monthLabel = "· " + CalendarMath.monthShortTitle(month, calendar: state.calendar, locale: state.locale)
            .uppercased(with: state.locale)

        return [
            [
                "type": "vstack",
                "spacing": 1,
                "alignment": "leading",
                "children": [
                    // Weekday and month are separate texts so only the weekday
                    // carries the red; a single text could not split the colour.
                    [
                        "type": "hstack",
                        "spacing": 4,
                        "alignment": "center",
                        "children": [
                            [
                                "type": "text",
                                "text": weekday,
                                "style": "compact",
                                "weight": "semibold",
                                "tint": "red",
                            ],
                            [
                                "type": "text",
                                "text": monthLabel,
                                "style": "compact",
                                "weight": "semibold",
                                "tint": "gray",
                            ],
                        ],
                    ],
                    // `large` is the kit's biggest text style; a glance has no
                    // `size` field to push past it (see glanceMarker).
                    ["type": "text", "text": CalendarMath.dayTitle(day), "style": "large", "weight": "bold", "tint": "white"],
                ],
            ],
            glanceEventList(state),
        ]
    }

    /// Each event gets a coloured marker derived from its calendar, so the same
    /// calendar always reads the same colour and a busy day scans as stripes
    /// rather than a wall of text. All-day events use a calendar glyph instead
    /// of the dot. No open actions here: their index points into the lake's
    /// selected day, which is often not today.
    /// Rows the glance draws before summarising the rest. The glance has its own
    /// 160-component budget; six fixed components plus five per row caps it at 30
    /// rows, so 24 leaves room for the summary line and stays well inside it.
    static let glanceRowLimit = 24

    private static func glanceEventList(_ state: LakeState) -> [String: Any] {
        let all = state.todayEvents
        guard !all.isEmpty else {
            return ["type": "text", "text": "No events", "style": "compact", "tint": "gray"]
        }

        let events = Array(all.prefix(glanceRowLimit))
        let hidden = all.count - events.count
        let times = CalendarMath.paddedTimeColumn(events.map { $0.timeText(calendar: state.calendar, locale: state.locale) })
        var rows: [[String: Any]] = events.enumerated().map { index, event in
            [
                "type": "hstack",
                "id": "glance-event-\(index)",
                "spacing": 5,
                "alignment": "center",
                "children": [
                    glanceMarker(for: event),
                    ["type": "text", "text": times[index], "style": "compact", "tint": "gray"],
                    ["type": "text", "text": truncated(event.title, limit: 40), "style": "compact", "weight": "semibold"],
                    ["type": "spacer"],
                ],
            ]
        }

        // A day with more events than the tile can hold says so, instead of
        // quietly dropping the tail.
        if hidden > 0 {
            rows.append(["type": "text", "text": "+\(hidden) more", "style": "compact", "tint": "gray"])
        }

        return [
            "type": "scroll",
            "spacing": 4,
            "softFade": "both",
            "children": rows,
        ]
    }

    /// A tinted glyph, not an image: DynamicLake only accepts `size` on images,
    /// buttons and status components inside *lake* content, and rejects the whole
    /// frame when a glance component carries one. Text has no size to set, so the
    /// marker renders at the glance's own type size and the frame validates.
    private static func glanceMarker(for event: DayEvent) -> [String: Any] {
        [
            "type": "text",
            "text": event.isAllDay ? "▮" : "●",
            "style": "compact",
            "tint": calendarTint(for: event.calendarTitle),
        ]
    }

    /// Google's iCal feeds carry no event colour, so the calendar a feed
    /// belongs to is the closest thing to a category. A stable hash keeps the
    /// same calendar on the same colour between launches.
    static func calendarTint(for calendarTitle: String) -> String {
        guard !calendarTitle.isEmpty else { return "gray" }
        let hash = calendarTitle.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
        return calendarPalette[hash % calendarPalette.count]
    }

    private static let calendarPalette = ["blue", "green", "orange", "purple", "pink", "teal", "indigo", "red"]

    /// Text only, for the same reason as the markers: a glance never carries a
    /// `size` field. The tint alone carries the state's colour.
    private static func glanceNotice(tint: String, text: String) -> [String: Any] {
        [
            "hideHeader": true,
            "content": [
                [
                    "type": "hstack",
                    "spacing": 6,
                    "alignment": "center",
                    "children": [
                        ["type": "text", "text": text, "style": "compact", "tint": tint],
                        ["type": "spacer"],
                    ],
                ],
            ],
        ]
    }

    // MARK: - Content

    static func splitContent(_ state: LakeState) -> [[String: Any]] {
        [
            headerRow(state),
            [
                "type": "hstack",
                "spacing": 4,
                "alignment": "top",
                // Right-clicking the card body reaches feeds.txt too. A context
                // menu only takes the right-click, so left clicks still fall
                // through to the lake, exactly as before.
                "contextMenu": feedMenu,
                "children": [agendaColumn(state), verticalDivider()] + calendarColumns(state),
            ],
        ]
    }

    static func compactContent(_ state: LakeState) -> [[String: Any]] {
        if state.compactShowsEvents, let day = state.selectedDay {
            return compactDayContent(state, day: day)
        }
        return compactWeekContent(state)
    }

    // MARK: - Split header

    private static func headerRow(_ state: LakeState) -> [String: Any] {
        var children: [[String: Any]] = [
            [
                "type": "text",
                "text": CalendarMath.monthTitle(state.monthStart, calendar: state.calendar, locale: state.locale),
                "style": "large",
                "weight": "bold",
            ],
            ["type": "spacer"],
        ]
        // Stepping into another month is the only time Today has a job.
        if !state.isViewingCurrentMonth {
            children.append(capsuleButton(id: "today", title: "Today", actionID: "today", size: daySize))
        }
        children.append(iconButton(id: "prev", symbol: "chevron.left", actionID: "prevMonth", size: headerIconSize, tint: "gray"))
        children.append(iconButton(id: "next", symbol: "chevron.right", actionID: "nextMonth", size: headerIconSize, tint: "gray"))

        return [
            "type": "hstack",
            "spacing": 6,
            "alignment": "center",
            "padding": ["top": 6] as [String: Any],
            "contextMenu": feedMenu,
            "children": children,
        ]
    }

    /// The only way back to feeds.txt once the card is drawing a month: the
    /// settings window can only open http and https links.
    private static var feedMenu: [[String: Any]] {
        [
            ["title": "Open feeds.txt", "systemImage": "doc.text", "actionID": "openFeeds"],
            ["title": "Refresh now", "systemImage": "arrow.clockwise", "actionID": "refresh"],
            ["title": "Google Calendar settings", "systemImage": "gearshape", "actionID": "googleSettings"],
            // DynamicLake closes the lake from the notch, not from a click on
            // the card's background, so the menu offers a way out.
            ["title": "Close", "systemImage": "xmark", "actionID": "closeLake"],
        ]
    }

    // MARK: - Agenda (left half)

    private static func agendaColumn(_ state: LakeState) -> [String: Any] {
        let day = state.agendaDay
        let weekday = CalendarMath.weekdayName(day, calendar: state.calendar, locale: state.locale)

        var children: [[String: Any]] = [[
            "type": "hstack",
            "spacing": 6,
            "alignment": "center",
            "children": [
                ["type": "text", "text": CalendarMath.dayTitle(day), "style": "large", "weight": "bold", "tint": "red"],
                ["type": "text", "text": weekday, "style": "compact", "tint": "gray"],
                ["type": "spacer"],
            ],
        ]]
        if let warning = state.feedWarning { children.append(feedWarningRow(warning)) }
        children.append(eventsList(state, limit: 30))

        return [
            "type": "vstack",
            "spacing": 4,
            "alignment": "leading",
            "children": children,
        ]
    }

    /// A quiet one-line note when only part of the calendar loaded. Right-click
    /// reaches feeds.txt, which is where the broken address lives.
    private static func feedWarningRow(_ text: String) -> [String: Any] {
        [
            "type": "hstack",
            "spacing": 4,
            "alignment": "center",
            "contextMenu": [
                ["title": "Open feeds.txt", "systemImage": "doc.text", "actionID": "openFeeds"],
            ],
            "children": [
                ["type": "image", "source": "sfSymbol", "systemImage": "exclamationmark.triangle.fill", "size": 10, "tint": "orange"],
                ["type": "text", "text": text, "style": "compact", "tint": "orange"],
                ["type": "spacer"],
            ],
        ]
    }

    // MARK: - Calendar (right half)

    /// One column per weekday, heading on top, so the grid stays aligned. They
    /// are direct children of the split row to save a level of nesting.
    private static func calendarColumns(_ state: LakeState) -> [[String: Any]] {
        let rows = CalendarMath.monthRows(monthStart: state.monthStart, calendar: state.calendar)
        let symbols = CalendarMath.weekdaySymbols(calendar: state.calendar, locale: state.locale)

        return (0..<7).map { index in
            var cells: [[String: Any]] = [[
                "type": "text",
                "text": symbols[index],
                "style": "compact",
                "tint": "gray",
            ]]

            for row in rows {
                if let day = row[index] {
                    cells.append(dayButton(day, state: state, size: daySize))
                } else {
                    cells.append(["type": "spacer", "length": daySize])
                }
            }

            return ["type": "vstack", "spacing": 2, "alignment": "center", "children": cells] as [String: Any]
        }
    }

    /// There is no divider component, so a thin stack of vertical bars stands in
    /// for one.
    private static func verticalDivider() -> [String: Any] {
        [
            "type": "vstack",
            "spacing": 0,
            "alignment": "center",
            "padding": ["leading": dividerPadding, "trailing": dividerPadding] as [String: Any],
            "children": Array(
                repeating: ["type": "text", "text": "│", "style": "compact", "tint": "gray"] as [String: Any],
                count: dividerGlyphs
            ),
        ]
    }

    // MARK: - Compact (small lake)

    private static func compactWeekContent(_ state: LakeState) -> [[String: Any]] {
        let week = CalendarMath.weekDays(containing: state.agendaDay, calendar: state.calendar)
        let symbols = CalendarMath.weekdaySymbols(calendar: state.calendar, locale: state.locale)

        var columns: [[String: Any]] = []
        for (index, day) in week.enumerated() {
            columns.append([
                "type": "vstack",
                "spacing": 2,
                "alignment": "center",
                "children": [
                    ["type": "text", "text": symbols[index], "style": "compact", "tint": "gray"],
                    dayButton(day, state: state, size: compactDaySize),
                ],
            ])
            if index < 6 { columns.append(["type": "spacer"]) }
        }

        var headerChildren: [[String: Any]] = [
            iconButton(id: "prevWeek", symbol: "chevron.left", actionID: "prevWeek", size: compactHeaderIconSize, tint: "gray"),
            [
                "type": "text",
                "text": CalendarMath.monthTitle(state.monthStart, calendar: state.calendar, locale: state.locale),
                "style": "large",
                "weight": "bold",
            ],
            ["type": "spacer"],
        ]
        // Same rule as the month card: only a different week earns a way back.
        if !state.isViewingCurrentWeek {
            headerChildren.append(capsuleButton(id: "today", title: "Today", actionID: "today", size: daySize))
        }
        headerChildren.append(iconButton(id: "nextWeek", symbol: "chevron.right", actionID: "nextWeek", size: compactHeaderIconSize, tint: "gray"))

        return [
            [
                "type": "hstack",
                "spacing": 6,
                "alignment": "center",
                "padding": ["top": 4] as [String: Any],
                "contextMenu": feedMenu,
                "children": headerChildren,
            ],
            [
                "type": "hstack",
                "spacing": 0,
                "alignment": "center",
                "padding": ["top": 6] as [String: Any],
                "contextMenu": feedMenu,
                "children": columns,
            ],
        ]
    }

    private static func compactDayContent(_ state: LakeState, day: DayKey) -> [[String: Any]] {
        var headerChildren: [[String: Any]] = [
            iconButton(id: "back", symbol: "chevron.backward", actionID: "weekView", size: compactHeaderIconSize, tint: "gray"),
            ["type": "text", "text": CalendarMath.dayTitle(day), "style": "large", "weight": "bold", "tint": "red"],
            [
                "type": "text",
                "text": CalendarMath.weekdayName(day, calendar: state.calendar, locale: state.locale),
                "style": "compact",
                "tint": "gray",
            ],
            ["type": "spacer"],
        ]
        // Browsing another day is a step away from today, so offer the way back.
        if day != state.today {
            headerChildren.append(capsuleButton(id: "today", title: "Today", actionID: "today", size: daySize))
        }

        var content: [[String: Any]] = [[
            "type": "hstack",
            "spacing": 6,
            "alignment": "center",
            "padding": ["top": 4] as [String: Any],
            "contextMenu": feedMenu,
            "children": headerChildren,
        ]]
        if let warning = state.feedWarning { content.append(feedWarningRow(warning)) }
        content.append(eventsList(state, limit: 60))

        return content
    }

    // MARK: - Agenda rows

    static func eventsList(_ state: LakeState, limit: Int) -> [String: Any] {
        eventList(state.dayEvents, state: state, limit: limit, includeOpenAction: true, idPrefix: "")
    }

    /// One scrollable agenda. The glance asks for no open action, because its
    /// rows are today's while the action's index counts the lake's day.
    private static func eventList(_ events: [DayEvent], state: LakeState, limit: Int, includeOpenAction: Bool, idPrefix: String) -> [String: Any] {
        guard !events.isEmpty else {
            return ["type": "text", "text": "No events", "style": "compact", "tint": "gray"]
        }

        let times = CalendarMath.paddedTimeColumn(events.map { $0.timeText(calendar: state.calendar, locale: state.locale) })
        var rows: [[String: Any]] = []

        for (index, event) in events.enumerated() {
            var row: [String: Any] = [
                "type": "hstack",
                "id": "\(idPrefix)event-\(index)",
                "spacing": 4,
                // Text is not pressable in DynamicLake, so the row carries the
                // open action as a right-click item. That also leaves the title
                // the width the arrow button used to take.
                // Index, not the event UID: identifier-like fields may only hold
                // letters, numbers, . _ : and -, and a UID containing "#" makes
                // DynamicLake reject the whole lake frame.
                "children": [
                    [
                        "type": "text",
                        "text": times[index],
                        "style": "compact",
                        "tint": "gray",
                    ],
                    [
                        "type": "text",
                        "text": truncated(event.title, limit: limit),
                        "style": "compact",
                    ],
                    ["type": "spacer"],
                ],
            ]
            if includeOpenAction {
                row["contextMenu"] = [
                    ["title": "Open Calendar", "systemImage": "calendar", "actionID": "open:\(index)"],
                ]
            }
            rows.append(row)
        }

        return [
            "type": "scroll",
            "spacing": 4,
            "softFade": "both",
            "children": rows,
        ]
    }

    // MARK: - Components

    static func dayButton(_ day: DayKey, state: LakeState, size: Int) -> [String: Any] {
        var tint = "gray"
        if state.selectedDay == day {
            tint = "red"
        } else if state.markBusyDays, state.busyDays.contains(day) {
            tint = "blue"
        }

        return capsuleButton(
            id: "day-\(day)",
            title: CalendarMath.dayTitle(day),
            actionID: "day:\(day)",
            size: size,
            tint: tint
        )
    }

    private static func capsuleButton(id: String, title: String, actionID: String, size: Int, tint: String? = nil) -> [String: Any] {
        var component: [String: Any] = [
            "type": "button",
            "id": id,
            "title": title,
            "shape": "roundedRect",
            "size": size,
            "actionID": actionID,
        ]
        if let tint = tint { component["tint"] = tint }
        return component
    }

    private static func iconButton(id: String, symbol: String, actionID: String, size: Int, tint: String? = nil) -> [String: Any] {
        var component: [String: Any] = [
            "type": "button",
            "id": id,
            "systemImage": symbol,
            "shape": "plain",
            "size": size,
            "actionID": actionID,
        ]
        if let tint = tint { component["tint"] = tint }
        return component
    }

    /// One line of explanation with optional action buttons, used for the
    /// setup, loading and error cards.
    private static func noticeContent(_ state: LakeState, symbol: String, tint: String, heading: String, detail: String, buttons: [(title: String, actionID: String)]) -> [[String: Any]] {
        let compact = state.layout == .compact

        var children: [[String: Any]] = [
            [
                "type": "image",
                "source": "sfSymbol",
                "systemImage": symbol,
                "size": compact ? 20 : 26,
                "tint": tint,
            ],
            [
                "type": "vstack",
                "spacing": 2,
                "alignment": "leading",
                "children": [
                    ["type": "text", "text": heading, "weight": "semibold"],
                    ["type": "text", "text": detail, "style": "compact", "tint": "gray"],
                ],
            ],
        ]

        if !buttons.isEmpty {
            children.append(["type": "spacer"])
            for button in buttons {
                children.append(capsuleButton(id: button.actionID, title: button.title, actionID: button.actionID, size: daySize))
            }
        }

        return [[
            "type": "hstack",
            "spacing": 10,
            "alignment": "center",
            "padding": ["top": compact ? 2 : 6] as [String: Any],
            "children": children,
        ]]
    }

    private static func truncated(_ title: String, limit: Int) -> String {
        guard title.count > limit else { return title }
        return String(title.prefix(limit - 1)) + "…"
    }
}
