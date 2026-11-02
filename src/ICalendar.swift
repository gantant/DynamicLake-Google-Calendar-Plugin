import Foundation

/// Minimal RFC 5545 reader: enough of VEVENT, RRULE, EXDATE and RDATE to show a
/// Google Calendar feed on a month grid. No network, no EventKit.
struct ICalEvent {
    var uid: String
    var summary: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var timeZone: TimeZone
    var calendarName: String
    var rule: RecurrenceRule?
    var exdates: [Date] = []
    var rdates: [Date] = []
    var recurrenceID: Date?
    var isCancelled = false
}

struct RecurrenceRule {
    enum Frequency: String {
        case daily = "DAILY"
        case weekly = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly = "YEARLY"
    }

    struct Weekday {
        /// 1 = Sunday … 7 = Saturday, matching Calendar's weekday numbering.
        var weekday: Int
        /// "2TU", "-1FR" and friends; nil for a plain weekday list.
        var ordinal: Int?
    }

    var frequency: Frequency
    var interval = 1
    var count: Int?
    var until: Date?
    var byDay: [Weekday] = []
    var byMonthDay: [Int] = []
    var byMonth: [Int] = []

    static let weekdayNames = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
}

enum ICalendarError: Error {
    case notACalendar
}

enum ICalendarParser {
    static func parse(_ text: String, defaultTimeZone: TimeZone = .current) throws -> [ICalEvent] {
        guard text.contains("BEGIN:VCALENDAR") else { throw ICalendarError.notACalendar }

        let lines = unfold(text)
        var events: [ICalEvent] = []
        var calendarName = ""
        var inEvent = false
        var fields: [String: String] = [:]
        var params: [String: [String: String]] = [:]
        var exdates: [Date] = []
        var rdates: [Date] = []

        for line in lines {
            if line == "BEGIN:VEVENT" {
                inEvent = true
                fields = [:]
                params = [:]
                exdates = []
                rdates = []
                continue
            }
            if line == "END:VEVENT" {
                inEvent = false
                if let event = makeEvent(fields: fields, params: params, exdates: exdates, rdates: rdates, calendarName: calendarName, timeZone: defaultTimeZone) {
                    events.append(event)
                }
                continue
            }

            guard let (name, value, parameters) = split(line) else { continue }

            if !inEvent {
                if name == "X-WR-CALNAME" { calendarName = unescape(value) }
                continue
            }

            switch name {
            case "EXDATE":
                exdates += value.split(separator: ",").compactMap { parseDate(String($0), parameters: parameters, timeZone: defaultTimeZone) }
            case "RDATE":
                rdates += value.split(separator: ",").compactMap { parseDate(String($0), parameters: parameters, timeZone: defaultTimeZone) }
            default:
                fields[name] = value
                params[name] = parameters
            }
        }

        return events
    }

    // MARK: - Structure

    static func unfold(_ text: String) -> [String] {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines: [String] = []
        for raw in normalised.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix(" "), !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else if line.hasPrefix("\t"), !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else {
                lines.append(line)
            }
        }
        return lines
    }

    static func split(_ line: String) -> (name: String, value: String, parameters: [String: String])? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])

        var parts = head.split(separator: ";")
        guard let first = parts.first else { return nil }
        let name = String(first).uppercased()
        parts.removeFirst()

        var parameters: [String: String] = [:]
        for part in parts {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            parameters[String(pieces[0]).uppercased()] = String(pieces[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return (name, value, parameters)
    }

    static func unescape(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                case ",": result.append(",")
                case ";": result.append(";")
                case "\\": result.append("\\")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func makeEvent(fields: [String: String], params: [String: [String: String]], exdates: [Date], rdates: [Date], calendarName: String, timeZone: TimeZone) -> ICalEvent? {
        guard let rawStart = fields["DTSTART"] else { return nil }
        let startParameters = params["DTSTART"] ?? [:]
        guard let start = parseDate(rawStart, parameters: startParameters, timeZone: timeZone) else { return nil }

        let isAllDay = (startParameters["VALUE"] ?? "").uppercased() == "DATE" || rawStart.count == 8
        let eventZone = zone(from: startParameters, fallback: timeZone)

        var end: Date
        if let rawEnd = fields["DTEND"], let parsed = parseDate(rawEnd, parameters: params["DTEND"] ?? [:], timeZone: timeZone) {
            end = parsed
        } else if let rawDuration = fields["DURATION"], let seconds = parseDuration(rawDuration) {
            end = start.addingTimeInterval(seconds)
        } else {
            end = start.addingTimeInterval(isAllDay ? 24 * 3600 : 3600)
        }
        if end <= start {
            end = start.addingTimeInterval(isAllDay ? 24 * 3600 : 3600)
        }

        let uid = fields["UID"] ?? "\(start.timeIntervalSince1970)-\(fields["SUMMARY"] ?? "")"
        let status = (fields["STATUS"] ?? "").uppercased()

        return ICalEvent(
            uid: uid,
            summary: unescape(fields["SUMMARY"] ?? "Untitled event"),
            start: start,
            end: end,
            isAllDay: isAllDay,
            timeZone: eventZone,
            calendarName: calendarName,
            rule: fields["RRULE"].flatMap(parseRule),
            exdates: exdates,
            rdates: rdates,
            recurrenceID: fields["RECURRENCE-ID"].flatMap { parseDate($0, parameters: params["RECURRENCE-ID"] ?? [:], timeZone: timeZone) },
            // Only a cancelled event disappears. TRANSP:TRANSPARENT means the
            // event is marked "free", not that it stopped existing, so a free
            // meeting still belongs in the agenda.
            isCancelled: status == "CANCELLED"
        )
    }

    // MARK: - Values

    static func zone(from parameters: [String: String], fallback: TimeZone) -> TimeZone {
        if let identifier = parameters["TZID"], let zone = TimeZone(identifier: identifier) {
            return zone
        }
        return fallback
    }

    static func parseDate(_ value: String, parameters: [String: String], timeZone: TimeZone) -> Date? {
        let value = value.trimmingCharacters(in: .whitespaces)
        let zone: TimeZone
        if value.hasSuffix("Z") {
            zone = TimeZone(identifier: "UTC")!
        } else {
            zone = ICalendarParser.zone(from: parameters, fallback: timeZone)
        }
        let digits = value.hasSuffix("Z") ? String(value.dropLast()) : value

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = digits.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
        return formatter.date(from: digits)
    }

    static func parseDuration(_ value: String) -> TimeInterval? {
        var seconds: TimeInterval = 0
        var number = ""
        var inTime = false
        for character in value.uppercased() {
            switch character {
            case "P": continue
            case "T": inTime = true
            case "0"..."9": number.append(character)
            case "W": seconds += (Double(number) ?? 0) * 7 * 86400; number = ""
            case "D": seconds += (Double(number) ?? 0) * 86400; number = ""
            case "H": seconds += (Double(number) ?? 0) * 3600; number = ""
            case "M":
                if inTime { seconds += (Double(number) ?? 0) * 60 } else { seconds += (Double(number) ?? 0) * 30 * 86400 }
                number = ""
            case "S": seconds += Double(number) ?? 0; number = ""
            default: break
            }
        }
        return seconds > 0 ? seconds : nil
    }

    static func parseRule(_ value: String) -> RecurrenceRule? {
        var properties: [String: String] = [:]
        for part in value.split(separator: ";") {
            let pieces = part.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            properties[String(pieces[0]).uppercased()] = String(pieces[1])
        }

        guard let frequencyRaw = properties["FREQ"]?.uppercased(),
              let frequency = RecurrenceRule.Frequency(rawValue: frequencyRaw) else { return nil }

        var rule = RecurrenceRule(frequency: frequency)
        if let interval = properties["INTERVAL"].flatMap(Int.init), interval > 0 {
            rule.interval = interval
        }
        if let count = properties["COUNT"].flatMap(Int.init), count > 0 {
            rule.count = count
        }
        if let until = properties["UNTIL"] {
            rule.until = parseDate(until, parameters: [:], timeZone: TimeZone(identifier: "UTC")!)
        }
        if let byDay = properties["BYDAY"] {
            rule.byDay = byDay.split(separator: ",").compactMap { token in
                var text = String(token).uppercased()
                var ordinal: Int?
                let digits = text.prefix { $0 == "-" || $0.isNumber }
                if !digits.isEmpty, let parsed = Int(digits) {
                    ordinal = parsed
                    text.removeFirst(digits.count)
                }
                guard let weekday = RecurrenceRule.weekdayNames[text] else { return nil }
                return RecurrenceRule.Weekday(weekday: weekday, ordinal: ordinal)
            }
        }
        if let byMonthDay = properties["BYMONTHDAY"] {
            rule.byMonthDay = byMonthDay.split(separator: ",").compactMap { Int($0) }
        }
        if let byMonth = properties["BYMONTH"] {
            rule.byMonth = byMonth.split(separator: ",").compactMap { Int($0) }
        }
        return rule
    }
}
