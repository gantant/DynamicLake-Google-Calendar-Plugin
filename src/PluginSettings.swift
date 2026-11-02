import Foundation

/// First column of the month grid and the week strip.
enum WeekStartPreference: String, CaseIterable {
    case system
    case sunday
    case monday
    case saturday

    static let settingLabels = ["System", "Sunday", "Monday", "Saturday"]

    init(settingValue: String?) {
        let raw = (settingValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = WeekStartPreference(rawValue: raw) ?? .system
    }

    /// nil keeps the user's system preference (Calendar.firstWeekday).
    var firstWeekday: Int? {
        switch self {
        case .system: return nil
        case .sunday: return 1
        case .monday: return 2
        case .saturday: return 7
        }
    }
}

/// Whether clock times read as 9:30 AM or 09:30.
enum HourCyclePreference: String, CaseIterable {
    case system
    case h12
    case h24

    static let settingLabels = ["System", "12-Hour", "24-Hour"]

    init(settingValue: String?) {
        let raw = (settingValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        switch raw {
        case "12-hour", "12hour", "h12": self = .h12
        case "24-hour", "24hour", "h23", "h24": self = .h24
        default: self = .system
        }
    }

    /// ICU reads an `@hours=` suffix, so one locale can express either cycle
    /// while keeping the user's own month and weekday names.
    func locale(_ base: Locale) -> Locale {
        let plain = base.identifier.components(separatedBy: "@").first ?? base.identifier
        switch self {
        case .system: return base
        case .h12: return Locale(identifier: plain + "@hours=h12")
        case .h24: return Locale(identifier: plain + "@hours=h23")
        }
    }
}

/// Everything the plugin takes from DynamicLake's settings window. Values come
/// from DYNAMICLAKE_PLUGIN_SETTINGS_PATH (the file DynamicLake rewrites), then
/// DYNAMICLAKE_PLUGIN_SETTINGS_JSON, then the per-setting environment variables.
struct PluginSettings: Equatable {
    static let defaultRefreshMinutes = 5
    static let refreshRange = 1...60
    static let defaultWarnMinutes = 10
    static let warnRange = 0...60

    var weekStart: WeekStartPreference
    var timeFormat: HourCyclePreference
    var markBusyDays: Bool
    var showAllDayEvents: Bool
    var refreshMinutes: Int
    /// Minutes before a timed event that the notch peeks it. 0 turns warnings off.
    var warnMinutes: Int
    /// Keep a low-priority chip in the notch, which is also the only way to open
    /// a lake from DynamicLake Playground.
    var persistentChip: Bool

    init(
        weekStart: WeekStartPreference = .system,
        timeFormat: HourCyclePreference = .system,
        markBusyDays: Bool = true,
        showAllDayEvents: Bool = true,
        refreshMinutes: Int = PluginSettings.defaultRefreshMinutes,
        warnMinutes: Int = PluginSettings.defaultWarnMinutes,
        persistentChip: Bool = true
    ) {
        self.weekStart = weekStart
        self.timeFormat = timeFormat
        self.markBusyDays = markBusyDays
        self.showAllDayEvents = showAllDayEvents
        self.refreshMinutes = min(
            max(refreshMinutes, PluginSettings.refreshRange.lowerBound),
            PluginSettings.refreshRange.upperBound
        )
        self.warnMinutes = min(
            max(warnMinutes, PluginSettings.warnRange.lowerBound),
            PluginSettings.warnRange.upperBound
        )
        self.persistentChip = persistentChip
    }

    init(values: [String: Any]) {
        self.init(
            weekStart: WeekStartPreference(settingValue: values["weekStartsOn"] as? String),
            timeFormat: HourCyclePreference(settingValue: values["timeFormat"] as? String),
            markBusyDays: PluginSettings.boolean(values["markBusyDays"], fallback: true),
            showAllDayEvents: PluginSettings.boolean(values["showAllDayEvents"], fallback: true),
            refreshMinutes: PluginSettings.integer(values["refreshMinutes"], fallback: PluginSettings.defaultRefreshMinutes),
            warnMinutes: PluginSettings.integer(values["warnMinutes"], fallback: PluginSettings.defaultWarnMinutes),
            persistentChip: PluginSettings.boolean(values["persistentChip"], fallback: true)
        )
    }

    // MARK: - Coercion

    /// DynamicLake writes real JSON types, but the per-setting environment
    /// variables are strings ("1", "Monday"), so both shapes are accepted.
    static func boolean(_ raw: Any?, fallback: Bool) -> Bool {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        if let text = raw as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return fallback
            }
        }
        return fallback
    }

    static func integer(_ raw: Any?, fallback: Int) -> Int {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String, let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        return fallback
    }
}

/// Reads the settings file DynamicLake passes in the environment and notices
/// when the user changes a setting while the plugin is running.
final class SettingsStore {
    static let pathEnvironmentKey = "DYNAMICLAKE_PLUGIN_SETTINGS_PATH"
    static let jsonEnvironmentKey = "DYNAMICLAKE_PLUGIN_SETTINGS_JSON"

    /// Setting id -> the variable DynamicLake also exposes it under.
    static let environmentKeys = [
        "weekStartsOn": "DYNAMICLAKE_SETTING_WEEK_STARTS_ON",
        "timeFormat": "DYNAMICLAKE_SETTING_TIME_FORMAT",
        "markBusyDays": "DYNAMICLAKE_SETTING_MARK_BUSY_DAYS",
        "showAllDayEvents": "DYNAMICLAKE_SETTING_SHOW_ALL_DAY_EVENTS",
        "refreshMinutes": "DYNAMICLAKE_SETTING_REFRESH_MINUTES",
        "warnMinutes": "DYNAMICLAKE_SETTING_WARN_MINUTES",
        "persistentChip": "DYNAMICLAKE_SETTING_PERSISTENT_CHIP",
    ]

    private let environment: [String: String]
    private let fileURL: URL?
    private var lastStamp: Date?
    private(set) var current = PluginSettings()

    /// The file DynamicLake rewrites, when there is one. The plugin watches its
    /// folder so a settings change applies without being polled for.
    var watchedURL: URL? { fileURL }

    init(environment: [String: String]) {
        self.environment = environment
        if let path = environment[SettingsStore.pathEnvironmentKey], !path.isEmpty {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = nil
        }
        if let values = SettingsStore.readValues(environment: environment, fileURL: fileURL) {
            current = PluginSettings(values: values)
        }
        lastStamp = SettingsStore.stamp(for: fileURL)
    }

    /// True when the settings changed since the last call. An unreadable file
    /// keeps the previous values, so a half-written save never resets the card.
    @discardableResult
    func refresh() -> Bool {
        let stamp = SettingsStore.stamp(for: fileURL)
        guard stamp != lastStamp else { return false }
        lastStamp = stamp

        guard let values = SettingsStore.readValues(environment: environment, fileURL: fileURL) else { return false }
        let next = PluginSettings(values: values)
        guard next != current else { return false }
        current = next
        return true
    }

    /// Re-reads the file even when its timestamp is unchanged, for the case where
    /// a watcher reported a write that landed within the filesystem's timestamp
    /// resolution.
    @discardableResult
    func reload() -> Bool {
        lastStamp = SettingsStore.stamp(for: fileURL)
        guard let values = SettingsStore.readValues(environment: environment, fileURL: fileURL) else { return false }
        let next = PluginSettings(values: values)
        guard next != current else { return false }
        current = next
        return true
    }

    // MARK: - Loading

    static func readValues(environment: [String: String], fileURL: URL?) -> [String: Any]? {
        if let fileURL = fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return nil
            }
            return values(from: object)
        }

        if let text = environment[jsonEnvironmentKey], !text.isEmpty,
           let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return values(from: object)
        }

        var collected: [String: Any] = [:]
        for (id, key) in environmentKeys {
            if let raw = environment[key] { collected[id] = raw }
        }
        return collected.isEmpty ? nil : collected
    }

    /// The file holds `{schemaVersion, identifier, values}`; the JSON variable is
    /// documented as the values themselves, but either shape is accepted.
    static func values(from object: [String: Any]) -> [String: Any] {
        (object["values"] as? [String: Any]) ?? object
    }

    static func stamp(for fileURL: URL?) -> Date? {
        guard let fileURL = fileURL else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }
}
