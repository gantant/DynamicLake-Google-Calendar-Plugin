import AppKit
import Foundation

@main
struct GoogleCalendarMain {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard let socketPath = environment["DYNAMICLAKE_JSON_SOCKET"], !socketPath.isEmpty else {
            FileHandle.standardError.write(Data("DYNAMICLAKE_JSON_SOCKET is not set\n".utf8))
            exit(1)
        }
        // Keep a named reference: run() never returns, and the fetch queue holds
        // the instance weakly, so a temporary receiver would be a lifetime trap.
        let plugin = GoogleCalendarPlugin(environment: environment, socketPath: socketPath)
        plugin.run()
    }
}

final class GoogleCalendarPlugin {
    private let environment: [String: String]
    private let socket: JSONSocketClient
    private let loader: FeedLoader
    private let logURL: URL

    private var connected = false
    private var requestCounter = 0
    private var calendar: Calendar
    private let locale: Locale
    private let settingsStore: SettingsStore
    private var settings: PluginSettings

    private var load: LakeState.Load = .setup
    private var monthStart: DayKey
    private var today: DayKey
    private var selectedDay: DayKey?
    private var snapshot: CalendarSnapshot = .empty
    private var events: [ICalEvent] = []

    /// Declared in plugin.json and confirmed by DynamicLake's `lakeOpened`. A
    /// small lake only fits a week, so the card is built differently.
    private var lakeSize: String
    private var compactShowsEvents = false

    private var lakeVisible = false

    /// Wakes the plugin for frames from DynamicLake.
    private var socketSource: DispatchSourceRead?
    /// The only timer: armed to the next deadline the plugin actually has.
    private let deadlineTimer = DispatchSource.makeTimerSource(queue: .main)
    /// Seconds until the next reconnect attempt; doubles while the host is away.
    private var reconnectDelay: TimeInterval = 0.5
    /// Consecutive failed attempts, so a plugin orphaned by a quit host stops
    /// retrying instead of sitting in the notch forever.
    private var connectFailures = 0

    /// Events already warned about, by uid + start, so one meeting never peeks
    /// twice.
    private var warnedEvents = Set<String>()
    /// Same keys in arrival order, so the oldest can be dropped rather than
    /// throwing the whole set away.
    private var warnedOrder: [String] = []
    private var activityCreated = false
    private var warningActivityVisible = false
    private var warningDismissAt: Date?
    /// What the standing chip's peek currently shows, so the run loop only
    /// redraws it when the next event (or the date) changes.
    private var chipPeekKey: String?
    /// The peek itself, and when it stops being true. Expanding every recurrence
    /// rule twice a second just to redraw the same text is the plugin's most
    /// expensive habit, so the answer is kept until the next event starts.
    private var chipPeekCache: (key: String, text: String, validUntil: Date)?
    private var supportsSneakPeek = false
    private var lastFetch = Date.distantPast
    private var configStamp: Date?

    private let fetchQueue = DispatchQueue(label: "com.nebulark.google-calendar.fetch")
    private var fetchInFlight = false
    /// Set when a refresh was asked for while one was already running, such as a
    /// feed added mid-fetch. Without it that edit waited for the next interval.
    private var fetchQueued = false
    /// Set when only part of the calendar arrived, so the card can say so.
    private var feedWarning: String?

    /// Feeds change slowly; the default five minutes keeps the card honest
    /// without hammering Google.
    private var refreshInterval: TimeInterval { TimeInterval(settings.refreshMinutes) * 60 }

    init(environment: [String: String], socketPath: String) {
        self.environment = environment
        self.socket = JSONSocketClient(socketPath: socketPath)
        self.loader = FeedLoader(environment: environment)
        self.settingsStore = SettingsStore(environment: environment)
        self.settings = settingsStore.current
        self.locale = Locale.current
        self.supportsSneakPeek = (environment["DYNAMICLAKE_PLUGIN_FEATURES"] ?? "")
            .split(separator: ",")
            .contains("presentSneakPeek")

        let configured = GoogleCalendarPlugin.calendar(for: settings, locale: Locale.current)
        self.calendar = configured
        self.today = CalendarMath.today(in: configured)
        self.monthStart = CalendarMath.monthStart(for: Date(), calendar: configured)
        self.selectedDay = CalendarMath.today(in: configured)
        self.lakeSize = GoogleCalendarPlugin.manifestLakeSize(environment: environment)

        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        self.logURL = logs.appendingPathComponent("google-calendar.log")
    }

    // MARK: - Run loop

    /// Runs until the process ends, woken only by something happening: a frame
    /// from DynamicLake, a settings or feeds file being rewritten, or the single
    /// deadline timer reaching the next thing the plugin actually has to do.
    /// There is no fixed tick and no idle wake-up.
    func run() {
        loader.prepareConfigFile()
        prepareInitialLoad()
        log("started, feeds=\(loader.feedURLs().count) config=\(loader.configURL.path) settings=\(describeSettings())")

        installTimer()
        installFileWatchers()
        connectIfNeeded()
        dispatchMain()
    }

    private func prepareInitialLoad() {
        let urls = loader.feedURLs()
        if urls.isEmpty {
            load = .setup
        } else {
            load = .loading
            startFetch()
        }
    }

    // MARK: - Connection

    private func connectIfNeeded() {
        guard !connected else { return }
        do {
            try socket.connect()
        } catch {
            connectFailures += 1
            log("connect failed: \(error) (attempt \(connectFailures))")
            // Roughly a minute of nothing, at the 8 s ceiling: the host is gone,
            // not restarting, so leave so DynamicLake can relaunch the plugin.
            guard connectFailures < 12 else {
                log("giving up: dynamiclake has been away for \(connectFailures) attempts")
                exit(0)
            }
            backOffAndRetry()
            return
        }

        connected = true
        connectFailures = 0
        reconnectDelay = 0.5
        requestCounter = 0
        lakeVisible = false
        warningActivityVisible = false
        warningDismissAt = nil
        log("connected")
        installSocketSource()
        sendLake()
        if settings.persistentChip { sendChip() }
        scheduleNextDeadline()
    }

    /// Frames wake the plugin instead of being polled for. The handler runs on the
    /// main queue, so the plugin's state stays single-threaded.
    private func installSocketSource() {
        socketSource?.cancel()
        socketSource = nil
        guard socket.descriptor >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: socket.descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            for message in self.socket.receiveAvailable() {
                self.handle(message)
            }
            // A read source keeps firing while the descriptor sits at end of
            // file, so an orderly close has to be noticed here or the plugin spins.
            if self.socket.peerClosed {
                self.dropConnection("dynamiclake closed the socket")
            } else {
                self.scheduleNextDeadline()
            }
        }
        source.resume()
        socketSource = source
    }

    private func dropConnection(_ reason: String) {
        guard connected else { return }
        log("disconnected: \(reason)")
        connected = false
        socketSource?.cancel()
        socketSource = nil
        socket.reset()
        backOffAndRetry()
    }

    /// Attempts start fast and back off, so a host that is restarting is picked
    /// up quickly without the plugin waking twice a second forever.
    private func backOffAndRetry() {
        reconnectDelay = min(max(reconnectDelay, 0.5) * 2, 8)
        scheduleNextDeadline()
    }

    // MARK: - The one timer

    private func installTimer() {
        deadlineTimer.setEventHandler { [weak self] in self?.fireDeadline() }
        deadlineTimer.resume()
    }

    private func scheduleNextDeadline() {
        let now = Date()
        guard connected else {
            deadlineTimer.schedule(deadline: .now() + reconnectDelay)
            return
        }

        let deadline = DeadlinePlanner.next(
            now: now,
            events: events,
            calendar: calendar,
            locale: settings.timeFormat.locale(locale),
            warnMinutes: settings.warnMinutes,
            persistentChip: settings.persistentChip,
            refreshInterval: refreshInterval,
            lastFetch: lastFetch,
            warningDismissAt: warningDismissAt,
            skipping: warnedEvents,
            warningsAllowed: !lakeVisible
        )
        deadlineTimer.schedule(deadline: .now() + max(0.05, deadline.date.timeIntervalSince(now)))
    }

    private func fireDeadline() {
        guard connected else {
            connectIfNeeded()
            return
        }

        let now = Date()

        let currentToday = CalendarMath.today(in: calendar)
        if currentToday != today {
            // A plugin left running overnight used to keep yesterday selected, so
            // the card showed yesterday's agenda — and yesterday's month, on the
            // first of a month. Follow the new day unless the user has browsed
            // to another one; browsing is deliberate, so it is left alone.
            let followed = DayRollover.follow(
                previousToday: today,
                today: currentToday,
                selectedDay: selectedDay,
                monthStart: monthStart,
                calendar: calendar
            )
            today = currentToday
            selectedDay = followed.selectedDay
            monthStart = followed.monthStart
            chipPeekCache = nil
            rebuildSnapshot()
            sendLake()
        }

        // Feeds refresh whether or not the lake is open, because the glance is a
        // surface of its own.
        if load == .ready, now.timeIntervalSince(lastFetch) >= refreshInterval {
            startFetch()
        }

        checkEventWarning(now: now)
        dismissWarningIfDone(now: now)

        refreshChipIfNeeded(now: now)
        scheduleNextDeadline()
    }

    /// The chip's peek names the next event of the day, so it has to move on when
    /// that event starts, when a refresh brings a closer one in, and when the day
    /// rolls over.
    private func refreshChipIfNeeded(now: Date) {
        guard settings.persistentChip, activityCreated, !warningActivityVisible, let shown = chipPeekKey else { return }
        guard chipPeek(now: now).key != shown else { return }
        sendChip()
    }

    // MARK: - Files

    private enum WatchedFile {
        case settings
        case feeds
    }

    private var fileWatchers: [WatchedFile: DispatchSourceFileSystemObject] = [:]

    /// Settings and feeds change when the user saves them, not on a timetable, so
    /// they are watched instead of stat-ed twice a second.
    private func installFileWatchers() {
        armWatcher(.settings, url: settingsStore.watchedURL)
        armWatcher(.feeds, url: loader.configURL)
    }

    /// Watches the file itself: a save that rewrites it in place only changes the
    /// file's vnode, so a directory watcher would never hear about it. A vnode
    /// source follows the descriptor rather than the path, which means a replace
    /// (rename over the file, or delete and rewrite) leaves it pointing at an
    /// unlinked file — so every event re-arms, and a missing file is watched
    /// through its folder until it appears.
    private func armWatcher(_ slot: WatchedFile, url: URL?) {
        fileWatchers[slot]?.cancel()
        fileWatchers[slot] = nil
        guard let url = url else { return }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let target = exists ? url : url.deletingLastPathComponent()
        let fd = open(target.path, O_EVTONLY)
        guard fd >= 0 else {
            log("cannot watch \(url.lastPathComponent); changes apply on the next launch")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Re-arm before reading. The read is what sends frames, and a save
            // that lands while they are being sent would otherwise be missed:
            // armed first, it is either caught by this read (already on disk) or
            // by the new watcher (written after).
            self.armWatcher(slot, url: url)
            switch slot {
            case .settings:
                self.applySettingsIfChanged(force: true)
            case .feeds:
                self.applySettingsIfChanged()
                self.checkConfig()
            }
            self.checkEventWarning(now: Date())
            self.scheduleNextDeadline()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatchers[slot] = source
    }

    // MARK: - Settings

    /// DynamicLake hands settings over through a JSON file and rewrites it when
    /// the user changes one, so the card has to watch it rather than read the
    /// launch environment once.
    /// `force` is for the file watcher, where a reported write is evidence enough
    /// and a save landing inside the timestamp's resolution must not be missed.
    private func applySettingsIfChanged(force: Bool = false) {
        guard force ? settingsStore.reload() : settingsStore.refresh() else { return }
        let hadChip = settings.persistentChip
        settings = settingsStore.current
        calendar = GoogleCalendarPlugin.calendar(for: settings, locale: locale)
        chipPeekCache = nil
        log("settings changed: \(describeSettings())")
        rebuildSnapshot()
        sendLake()
        if hadChip != settings.persistentChip { syncChip() }
        refreshChipIfNeeded(now: Date())
        scheduleNextDeadline()
    }

    private var layout: LakeLayout { LakeLayout(size: lakeSize) }

    /// DynamicLake fixes a lake's size at install, so the package's own manifest
    /// is the only way to know the shape before the lake is opened.
    static func manifestLakeSize(environment: [String: String]) -> String {
        var folders: [URL] = []
        if let executable = CommandLine.arguments.first, !executable.isEmpty {
            folders.append(URL(fileURLWithPath: executable).deletingLastPathComponent())
        }
        if let package = environment["DYNAMICLAKE_PLUGIN_PACKAGE"], !package.isEmpty {
            folders.append(URL(fileURLWithPath: package))
        }

        for folder in folders {
            let manifest = folder.appendingPathComponent("plugin.json")
            guard let data = try? Data(contentsOf: manifest),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let lake = object["lake"] as? [String: Any],
                  let size = lake["size"] as? String,
                  !size.isEmpty else { continue }
            return size
        }
        return "normal"
    }

    private func describeSettings() -> String {
        "weekStart=\(settings.weekStart.rawValue) timeFormat=\(settings.timeFormat.rawValue) busy=\(settings.markBusyDays) allDay=\(settings.showAllDayEvents) refresh=\(settings.refreshMinutes)m warn=\(settings.warnMinutes)m chip=\(settings.persistentChip)"
    }

    /// The user's system calendar, with the week-start setting applied on top.
    static func calendar(for settings: PluginSettings, locale: Locale) -> Calendar {
        var configured = Calendar.current
        configured.locale = locale
        if let firstWeekday = settings.weekStart.firstWeekday {
            configured.firstWeekday = firstWeekday
        }
        return configured
    }

    // MARK: - Config

    private func checkConfig() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: loader.configURL.path)[.modificationDate]) as? Date
        guard stamp != configStamp else { return }
        configStamp = stamp
        loader.prepareConfigFile()

        let urls = loader.feedURLs()
        log("config changed, feeds=\(urls.count)")
        if urls.isEmpty {
            events = []
            snapshot = .empty
            load = .setup
            feedWarning = nil
            sendLake()
        } else {
            startFetch()
        }
    }

    // MARK: - Fetching

    private func startFetch() {
        guard !fetchInFlight else {
            fetchQueued = true
            return
        }
        let urls = loader.feedURLs()
        guard !urls.isEmpty else {
            load = .setup
            scheduleNextDeadline()
            return
        }

        fetchInFlight = true
        let loader = self.loader
        fetchQueue.async { [weak self] in
            let result = loader.load(urls: urls)
            // The download finishes on its own queue; hand the answer back to the
            // main queue rather than have a loop poll for it.
            DispatchQueue.main.async {
                self?.applyFetchOutcome(result)
            }
        }
    }

    private func applyFetchOutcome(_ outcome: FeedLoad) {
        fetchInFlight = false
        lastFetch = Date()

        for failure in outcome.failures {
            let source = failure.host.isEmpty ? "feed" : failure.host
            log("feed failed: \(source) - \(failure.error.message)")
        }

        if outcome.succeeded == 0, let first = outcome.failures.first {
            // Every feed failed. Keep the last good month if there is one, but
            // say that it is no longer being updated.
            if events.isEmpty {
                load = .failed(first.error.message)
                snapshot = .empty
                feedWarning = nil
            } else {
                feedWarning = "Can't refresh"
            }
        } else {
            events = outcome.events
            load = .ready
            // A refresh can name a different next event, so the peek must look
            // again instead of serving the cached one.
            chipPeekCache = nil
            feedWarning = GoogleCalendarPlugin.warningText(for: outcome)
            rebuildSnapshot()
            log("loaded \(outcome.events.count) events, busy=\(snapshot.busyDays.count), day=\(snapshot.dayEvents.count), feeds failed=\(outcome.failures.count)")
        }

        sendLake()

        // A refresh can bring in the event that is about to start, so the warning
        // and the chip's line are updated as soon as the events land rather than
        // at the next clock deadline.
        let now = Date()
        checkEventWarning(now: now)
        refreshChipIfNeeded(now: now)

        // A refresh asked for during this one (a feed added mid-fetch) runs now,
        // against the config as it stands rather than waiting for the interval.
        if fetchQueued {
            fetchQueued = false
            startFetch()
        }

        scheduleNextDeadline()
    }

    /// The one-line note under the agenda when only part of the calendar
    /// arrived. One feed keeps its name out of it; the count is enough.
    private static func warningText(for load: FeedLoad) -> String? {
        guard !load.failures.isEmpty else { return nil }
        if load.succeeded == 0 { return "Can't refresh" }
        return load.failures.count == 1 ? "1 feed failed" : "\(load.failures.count) feeds failed"
    }

    private func rebuildSnapshot() {
        let rows = CalendarMath.monthRows(monthStart: monthStart, calendar: calendar)
        snapshot = SnapshotBuilder.build(
            events: events,
            monthRows: rows,
            selectedDay: selectedDay,
            calendar: calendar,
            includeAllDay: settings.showAllDayEvents
        )
    }

    // MARK: - Messages

    private func handle(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }

        switch type {
        case "lakeOpened":
            lakeVisible = true
            if let size = message["size"] as? String, size != lakeSize {
                lakeSize = size
                log("lake size \(size)")
            }
            rebuildSnapshot()
            sendLake()
            startFetch()

        case "lakeClosed":
            lakeVisible = false
            // A small lake reopens on the week, not on the last day it showed.
            compactShowsEvents = false
            // Warnings are held back while the lake is open, so catch up now that
            // it has closed instead of waiting for the next deadline.
            checkEventWarning(now: Date())
            scheduleNextDeadline()

        case "action":
            handleAction(message)

        case "error":
            log("dynamiclake error: \((message["error"] as? String) ?? "\(message)")")

        default:
            break
        }
    }

    private func handleAction(_ message: [String: Any]) {
        guard let actionID = message["actionID"] as? String else { return }
        log("action \(actionID)")

        switch actionID {
        case let id where id.hasPrefix("day:"):
            guard let day = parseDay(String(id.dropFirst(4))) else { return }
            selectedDay = day
            if day.year != monthStart.year || day.month != monthStart.month {
                monthStart = DayKey(year: day.year, month: day.month, day: 1)
            }
            // In a small lake the week strip is replaced by the day's agenda.
            if layout == .compact { compactShowsEvents = true }
            rebuildSnapshot()

        case "prevMonth":
            monthStart = CalendarMath.addMonths(-1, to: monthStart, calendar: calendar)
            clampSelectionToMonth()
            rebuildSnapshot()

        case "nextMonth":
            monthStart = CalendarMath.addMonths(1, to: monthStart, calendar: calendar)
            clampSelectionToMonth()
            rebuildSnapshot()

        case "prevWeek":
            shiftWeek(-7)

        case "nextWeek":
            shiftWeek(7)

        case "today":
            let current = CalendarMath.today(in: calendar)
            today = current
            selectedDay = current
            monthStart = CalendarMath.monthStart(for: Date(), calendar: calendar)
            rebuildSnapshot()

        case "weekView":
            compactShowsEvents = false
            rebuildSnapshot()

        case "closeLake":
            requestCounter += 1
            send([
                "schemaVersion": 1,
                "requestID": "close-\(requestCounter)",
                "type": "closeLake",
            ])
            return

        case "googleSettings":
            openExternally("https://calendar.google.com/calendar/r/settings")
            return

        case "refresh":
            loader.prepareConfigFile()
            if loader.feedURLs().isEmpty {
                load = .setup
            } else {
                if events.isEmpty { load = .loading }
                startFetch()
            }

        case "openSetup":
            loader.prepareConfigFile()
            openExternally(loader.folderURL.path)

        case "openFeeds":
            // Opens feeds.txt itself, not the folder, so the next step is a paste.
            loader.prepareConfigFile()
            openExternally(loader.configURL.path)

        case let id where id.hasPrefix("open:"):
            openInCalendar(String(id.dropFirst(5)))

        default:
            return
        }

        sendLake()
        // An action moves the selection, the month or the chip, so the next
        // deadline may have changed with it.
        scheduleNextDeadline()
    }

    /// Month arrows keep a day selected, but only one that is on screen.
    private func clampSelectionToMonth() {
        if let day = selectedDay, day.year == monthStart.year, day.month == monthStart.month { return }
        selectedDay = monthStart
    }

    private func shiftWeek(_ days: Int) {
        let moved = CalendarMath.addDays(days, to: selectedDay ?? today, calendar: calendar)
        selectedDay = moved
        monthStart = DayKey(year: moved.year, month: moved.month, day: 1)
        rebuildSnapshot()
    }

    private func parseDay(_ text: String) -> DayKey? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return DayKey(year: parts[0], month: parts[1], day: parts[2])
    }

    // MARK: - Sending

    private func sendLake() {
        guard connected else { return }
        requestCounter += 1
        // DynaGlance has its own fixed-size design, and it always describes
        // today rather than the day the lake has browsed to.
        let todayEvents = SnapshotBuilder.dayAgenda(
            events: events,
            day: today,
            calendar: calendar,
            includeAllDay: settings.showAllDayEvents
        )

        let state = LakeState(
            monthStart: monthStart,
            today: today,
            selectedDay: selectedDay,
            snapshot: snapshot,
            todayEvents: todayEvents,
            feedWarning: feedWarning,
            load: load,
            markBusyDays: settings.markBusyDays,
            layout: layout,
            compactShowsEvents: compactShowsEvents,
            calendar: calendar,
            locale: settings.timeFormat.locale(locale)
        )
        send(LakeView.lakeCommand(state: state, requestID: "lake-\(requestCounter)"))
    }

    // MARK: - Notch activity

    /// One activity carries both jobs: the standing chip that opens the lake,
    /// and the short sneak peek before an event starts. The chip is optional,
    /// because a plugin with no activity shows nothing to click in DynamicLake
    /// Playground.
    private func sendChip() {
        guard connected else { return }
        requestCounter += 1

        let peek = chipPeek(now: Date())

        send([
            "schemaVersion": 1,
            "requestID": "chip-\(requestCounter)",
            "type": activityCreated ? "update" : "create",
            "activityID": "calendar",
            "priority": "low",
            "size": "small",
            "surfaces": [
                "compactLiveActivity": [
                    "leftSlot": [
                        "type": "image",
                        "source": "sfSymbol",
                        "systemImage": "calendar",
                        "tint": "blue",
                    ],
                ],
                "sneakPeek": [
                    "center": [
                        "type": "text",
                        "text": peek.text,
                        "style": "compact",
                    ],
                ],
            ],
        ])

        activityCreated = true
        warningActivityVisible = false
        chipPeekKey = peek.key
    }

    /// What the standing chip's peek says. With the persistent chip on it names
    /// the next event still to come today; otherwise, and when the day is done,
    /// it keeps showing the date.
    private func chipPeek(now: Date) -> (key: String, text: String) {
        if let cached = chipPeekCache, now < cached.validUntil {
            return (cached.key, cached.text)
        }
        let computed = computeChipPeek(now: now)
        chipPeekCache = computed
        return (computed.key, computed.text)
    }

    /// The cache expires when the named event starts, or at midnight when the
    /// peek is showing an all-day event or the date.
    private func computeChipPeek(now: Date) -> (key: String, text: String, validUntil: Date) {
        let peek = NotchPeek.content(
            now: now,
            events: events,
            calendar: calendar,
            locale: settings.timeFormat.locale(locale),
            persistentChip: settings.persistentChip
        )
        return (peek.key, peek.text, peek.validUntil)
    }

    private func dismissActivity() {
        guard connected, activityCreated else { return }
        requestCounter += 1
        send([
            "schemaVersion": 1,
            "requestID": "dismiss-\(requestCounter)",
            "type": "dismiss",
            "activityID": "calendar",
        ])
        activityCreated = false
        warningActivityVisible = false
    }

    /// Follows the "Notch Chip" switch without waiting for a restart.
    private func syncChip() {
        guard connected else { return }
        if settings.persistentChip {
            sendChip()
        } else if warningDismissAt == nil {
            dismissActivity()
        }
    }

    // MARK: - Event warnings

    private func checkEventWarning(now: Date) {
        guard connected, !lakeVisible else { return }
        let lead = TimeInterval(settings.warnMinutes * 60)
        guard lead > 0 else { return }

        let window = DateInterval(start: now, end: now.addingTimeInterval(lead))
        guard let warning = AgendaPlanner.firstStarting(
            in: window,
            events: events,
            calendar: calendar,
            skipping: warnedEvents
        ) else { return }
        warnedEvents.insert(warning.key)
        warnedOrder.append(warning.key)
        // Drop the oldest warnings instead of all of them: an event still inside
        // its warning window must not peek a second time.
        if warnedOrder.count > 500 {
            for stale in warnedOrder.prefix(100) { warnedEvents.remove(stale) }
            warnedOrder.removeFirst(100)
        }
        presentWarning(title: warning.title, start: warning.start)
    }

    private func presentWarning(title: String, start: Date) {
        guard connected else { return }
        requestCounter += 1

        let time = CalendarMath.timeLabel(start, calendar: calendar, locale: settings.timeFormat.locale(locale))
        let text = truncated("\(title) · \(time)", limit: 60)

        var command: [String: Any] = [
            "schemaVersion": 1,
            "requestID": "warn-\(requestCounter)",
            "type": activityCreated ? "update" : "create",
            "activityID": "calendar",
            "priority": "normal",
            "size": "small",
            "surfaces": [
                "compactLiveActivity": [
                    "leftSlot": [
                        "type": "image",
                        "source": "sfSymbol",
                        "systemImage": "calendar.badge.clock",
                        "tint": "red",
                    ],
                ],
                "sneakPeek": [
                    "leftSlot": [
                        "type": "image",
                        "source": "sfSymbol",
                        "systemImage": "calendar.badge.clock",
                        "tint": "red",
                    ],
                    "center": ["type": "text", "text": text, "style": "compact"],
                ],
            ],
        ]

        // Older DynamicLake versions reject the field outright, so only send it
        // when the app advertises the feature.
        if supportsSneakPeek { command["presentSneakPeek"] = 5 }

        send(command)
        activityCreated = true
        warningActivityVisible = true
        warningDismissAt = Date().addingTimeInterval(7)
        log("warning \(title) at \(time)")
    }

    private func dismissWarningIfDone(now: Date) {
        guard let deadline = warningDismissAt, now >= deadline else { return }
        guard warningActivityVisible else {
            warningDismissAt = nil
            return
        }
        // Never pull the chip while the user is reading the lake it opened;
        // keep the pending dismissal and try again on the next tick.
        guard !lakeVisible else { return }
        warningDismissAt = nil
        warningActivityVisible = false

        // With a chip the warning just shrinks back into it; without one the
        // activity disappears entirely.
        if settings.persistentChip {
            sendChip()
        } else {
            dismissActivity()
        }
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private func send(_ payload: [String: Any]) {
        do {
            try socket.send(payload)
        } catch {
            log("send failed: \(error)")
            dropConnection("send failed")
        }
    }

    // MARK: - Calendar app

    /// Opens Google Calendar on the event's day. iCal feeds carry Google's UID,
    /// not a local Calendar item identifier, so neither Calendar.app nor
    /// Google's event URL can be targeted; the day view is the closest link.
    private func openInCalendar(_ indexText: String) {
        var day = selectedDay ?? today
        if let index = Int(indexText), snapshot.dayEvents.indices.contains(index) {
            day = DayKey(date: snapshot.dayEvents[index].start, calendar: calendar)
        }
        openExternally(CalendarMath.googleCalendarDayURL(day))
    }

    /// Opens a URL, file or folder with the user's default app. `NSWorkspace`
    /// does it in process, so the plugin never spawns `/usr/bin/open` and never
    /// parks a thread in `waitUntilExit`.
    private func openExternally(_ target: String) {
        if let url = URL(string: target), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: target))
        }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attributes[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: logURL)
        }

        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}
