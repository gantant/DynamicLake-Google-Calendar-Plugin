import Foundation

enum FeedError: Error, Equatable {
    case offline
    case unknownHost(String)
    case timedOut
    case http(Int)
    case notACalendar
    case tooLarge
    case network(String)

    /// Short enough to survive the card's one-line detail text.
    var message: String {
        switch self {
        case .offline:
            return "You're offline. Reconnect and try again."
        case .unknownHost(let host):
            return host.isEmpty ? "Can't reach the calendar server." : "Can't find \(host)."
        case .timedOut:
            return "The calendar server didn't respond."
        case .http(let code):
            return "The calendar feed returned HTTP \(code)."
        case .notACalendar:
            return "That address isn't a calendar feed."
        case .tooLarge:
            return "That calendar feed is too large to read."
        case .network(let detail):
            return detail.isEmpty ? "The calendar couldn't be loaded." : detail
        }
    }
}

/// What one refresh produced: the events from every feed that answered, and one
/// entry per feed that did not. Keeping the failures is what lets the card say
/// that part of the calendar is missing instead of quietly showing less.
struct FeedLoad {
    struct Failure: Equatable {
        let host: String
        let error: FeedError
    }

    var events: [ICalEvent] = []
    var failures: [Failure] = []
    /// Feeds that answered and parsed, so "every feed failed" stays distinct
    /// from "there are no feeds".
    var succeeded = 0

    var isComplete: Bool { failures.isEmpty }
}

/// Reads the feed list from Application Support (never from the installed
/// package) and fetches every feed in it.
final class FeedLoader {
    static let configFileName = "feeds.txt"
    /// Feeds are independent HTTP requests, so they run together instead of
    /// adding one timeout to the next.
    static let concurrentFetches = 4
    /// A calendar feed is a small text file. Anything past this is either a
    /// wrong address or something we should not hold in memory.
    static let maximumFeedBytes = 8 * 1024 * 1024
    static let requestTimeout: TimeInterval = 15

    let configURL: URL

    init(environment: [String: String]) {
        if let override = environment["GOOGLE_CALENDAR_FEEDS"], !override.isEmpty {
            configURL = URL(fileURLWithPath: override)
        } else {
            let support = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("Google Calendar", isDirectory: true)
            configURL = support.appendingPathComponent(FeedLoader.configFileName)
        }
    }

    var folderURL: URL { configURL.deletingLastPathComponent() }

    /// Creates the folder and a commented template so there is something to edit.
    func prepareConfigFile() {
        let manager = FileManager.default
        try? manager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        guard !manager.fileExists(atPath: configURL.path) else { return }

        let template = """
        # Google Calendar feeds
        #
        # Paste the "Secret address in iCal format" for each calendar you want to
        # see, one per line, below this comment. Lines starting with # are ignored.
        #
        # To open this file again: right-click the lake and choose "Open feeds.txt".
        #
        # Google Calendar -> Settings -> click the calendar -> scroll to the bottom
        # -> Secret address in iCal format
        #
        # https://calendar.google.com/calendar/ical/.../basic.ics
        #
        # US holidays from Google's public calendar, off until you ask for it:
        # remove the # at the start of the line below to show US holidays.
        # https://calendar.google.com/calendar/ical/en.usa%23holiday%40group.v.calendar.google.com/public/basic.ics

        """
        try? template.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func feedURLs() -> [URL] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0) }
            .filter { $0.scheme == "http" || $0.scheme == "https" }
    }

    /// Fetches every feed at once, bounded to `concurrentFetches` requests.
    /// Results stay in feed order, so the agenda is stable between refreshes.
    func load(urls: [URL]) -> FeedLoad {
        var load = FeedLoad()
        guard !urls.isEmpty else { return load }

        var results = [Result<[ICalEvent], FeedError>?](repeating: nil, count: urls.count)
        let lock = NSLock()
        let lanes = DispatchSemaphore(value: FeedLoader.concurrentFetches)

        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            lanes.wait()
            let result: Result<[ICalEvent], FeedError>
            switch fetch(urls[index]) {
            case .success(let text):
                do { result = .success(try ICalendarParser.parse(text)) }
                catch { result = .failure(.notACalendar) }
            case .failure(let error):
                result = .failure(error)
            }
            lanes.signal()

            lock.lock()
            results[index] = result
            lock.unlock()
        }

        for (index, result) in results.enumerated() {
            guard let result = result else { continue }
            switch result {
            case .success(let events):
                load.events += events
                load.succeeded += 1
            case .failure(let error):
                load.failures.append(FeedLoad.Failure(host: urls[index].host ?? "", error: error))
            }
        }
        return load
    }

    private func fetch(_ url: URL) -> Result<String, FeedError> {
        var request = URLRequest(url: url)
        request.timeoutInterval = FeedLoader.requestTimeout
        request.setValue("GoogleCalendarDynamicLake/1.0", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<String, FeedError> = .failure(.network(""))
        let lock = NSLock()

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            let result: Result<String, FeedError>

            if let error = error as? URLError {
                switch error.code {
                case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                    result = .failure(.offline)
                case .cannotFindHost, .dnsLookupFailed:
                    result = .failure(.unknownHost(url.host ?? ""))
                case .timedOut:
                    result = .failure(.timedOut)
                default:
                    result = .failure(.network(error.localizedDescription))
                }
            } else if let error = error {
                result = .failure(.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(.http(http.statusCode))
            } else if let data = data, data.count > FeedLoader.maximumFeedBytes {
                result = .failure(.tooLarge)
            } else if let data = data, let text = String(data: data, encoding: .utf8) {
                result = .success(text)
            } else {
                result = .failure(.network("The calendar sent an empty response."))
            }

            lock.lock()
            outcome = result
            lock.unlock()
        }

        task.resume()
        semaphore.wait()
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}
