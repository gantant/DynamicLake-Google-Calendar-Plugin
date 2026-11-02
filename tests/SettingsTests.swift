import Foundation

// Settings suite: how DynamicLake's settings reach the plugin, and what the
// values mean. No DynamicLake and no calendar access are needed.

var failures = 0

func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS \(name)")
    } else {
        print("FAIL \(name)")
        failures += 1
    }
}

func normalised(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
}

func clockLabel(_ date: Date, cycle: HourCyclePreference, localeID: String = "en_US") -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = cycle.locale(Locale(identifier: localeID))
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return normalised(formatter.string(from: date))
}

@main
enum SettingsTests {
    static func main() {
        // MARK: - Defaults

        let defaults = PluginSettings()
        check(defaults.weekStart == .system, "week start defaults to the system")
        check(defaults.timeFormat == .system, "time format defaults to the system")
        check(defaults.markBusyDays, "busy dots default on")
        check(defaults.showAllDayEvents, "all-day events default on")
        check(defaults.refreshMinutes == 5, "refresh defaults to five minutes")
        check(defaults.warnMinutes == 10, "warnings default to ten minutes before an event")
        check(defaults.persistentChip, "the notch chip defaults on so the lake can be opened")
        check(defaults == PluginSettings(values: [:]), "an empty value map yields the defaults")

        // MARK: - Values

        let configured = PluginSettings(values: [
            "weekStartsOn": "Monday",
            "timeFormat": "24-Hour",
            "markBusyDays": false,
            "showAllDayEvents": false,
            "refreshMinutes": 12,
            "warnMinutes": 25,
            "persistentChip": false,
        ])
        check(configured.weekStart == .monday, "the week start select is read")
        check(configured.weekStart.firstWeekday == 2, "Monday is Calendar weekday 2")
        check(configured.timeFormat == .h24, "the time format select is read")
        check(!configured.markBusyDays, "the highlight switch can be turned off")
        check(!configured.showAllDayEvents, "the all-day switch can be turned off")
        check(configured.refreshMinutes == 12, "the refresh slider is read")
        check(configured.warnMinutes == 25, "the warning slider is read")
        check(!configured.persistentChip, "the notch chip switch is read")

        check(WeekStartPreference(settingValue: "Sunday") == .sunday, "Sunday is understood as a label")
        check(WeekStartPreference(settingValue: "saturday") == .saturday, "select labels are case-insensitive")
        check(WeekStartPreference(settingValue: "Fortnightly") == .system, "an unknown week start falls back to the system")
        check(WeekStartPreference(settingValue: nil) == .system, "a missing week start falls back to the system")
        check(WeekStartPreference.sunday.firstWeekday == 1, "Sunday is Calendar weekday 1")
        check(WeekStartPreference.saturday.firstWeekday == 7, "Saturday is Calendar weekday 7")
        check(WeekStartPreference.system.firstWeekday == nil, "System keeps the user's own first weekday")

        check(HourCyclePreference(settingValue: "12-Hour") == .h12, "12-hour is understood as a label")
        check(HourCyclePreference(settingValue: "24 hour") == .h24, "24-hour survives a missing hyphen")
        check(HourCyclePreference(settingValue: "h23") == .h24, "the ICU cycle name is accepted")
        check(HourCyclePreference(settingValue: "Sometimes") == .system, "an unknown time format falls back to the system")

        // MARK: - Coercion and clamping

        check(PluginSettings.boolean("1", fallback: false), "environment 1 reads as true")
        check(!PluginSettings.boolean("0", fallback: true), "environment 0 reads as false")
        check(PluginSettings.boolean("yes", fallback: false), "yes reads as true")
        check(PluginSettings.boolean("sideways", fallback: true), "an unreadable bool keeps the fallback")
        check(PluginSettings(values: ["markBusyDays": 0]).markBusyDays == false, "a JSON number reads as a bool")
        check(PluginSettings(values: ["refreshMinutes": "20"]).refreshMinutes == 20, "an environment string reads as a number")
        check(PluginSettings(values: ["refreshMinutes": 0]).refreshMinutes == 1, "the refresh interval clamps to one minute")
        check(PluginSettings(values: ["refreshMinutes": 999]).refreshMinutes == 60, "the refresh interval clamps to an hour")
        check(PluginSettings(values: ["refreshMinutes": "later"]).refreshMinutes == 5, "an unreadable interval keeps the default")
        check(PluginSettings(values: ["warnMinutes": 0]).warnMinutes == 0, "zero turns warnings off")
        check(PluginSettings(values: ["warnMinutes": 999]).warnMinutes == 60, "the warning lead clamps to an hour")

        // MARK: - Clock labels

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 10
        parts.day = 26
        parts.hour = 14
        parts.minute = 5
        let afternoon = utc.date(from: parts)!

        check(clockLabel(afternoon, cycle: .system) == "2:05 PM", "the system cycle keeps en_US on 12 hours")
        check(clockLabel(afternoon, cycle: .h12, localeID: "en_GB") == "2:05 pm", "12-hour overrides a 24-hour region")
        check(clockLabel(afternoon, cycle: .h24, localeID: "en_US") == "14:05", "24-hour overrides a 12-hour region")
        check(clockLabel(afternoon, cycle: .h24, localeID: "en_GB") == "14:05", "24-hour leaves a 24-hour region alone")

        // MARK: - Reading the settings file

        let workspace = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gcal-settings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let fileURL = workspace.appendingPathComponent("plugin-settings.json")
        let document = """
        {"schemaVersion": 1, "identifier": "com.nebulark.google-calendar",
         "values": {"weekStartsOn": "Saturday", "markBusyDays": false}}
        """
        try? document.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = SettingsStore(environment: [SettingsStore.pathEnvironmentKey: fileURL.path])
        check(store.current.weekStart == .saturday, "the settings file is the source of truth")
        check(!store.current.markBusyDays, "switches arrive from the file")
        check(store.refresh() == false, "an unchanged file reports no change")

        let rewritten = """
        {"schemaVersion": 1, "identifier": "com.nebulark.google-calendar",
         "values": {"weekStartsOn": "Monday", "markBusyDays": true, "refreshMinutes": 30}}
        """
        try? rewritten.write(to: fileURL, atomically: true, encoding: .utf8)
        check(store.refresh(), "rewriting the file reports a change")
        check(store.current.weekStart == .monday, "the new week start is picked up while running")
        check(store.current.refreshMinutes == 30, "the new interval is picked up while running")

        try? "{\"values\": ".write(to: fileURL, atomically: true, encoding: .utf8)
        check(store.refresh() == false, "a half-written file reports no change")
        check(store.current.weekStart == .monday, "a half-written file keeps the last good settings")

        // MARK: - Environment fallbacks

        let jsonEnvironment = SettingsStore(environment: [
            SettingsStore.jsonEnvironmentKey: "{\"weekStartsOn\": \"Monday\", \"timeFormat\": \"12-Hour\"}"
        ])
        check(jsonEnvironment.current.weekStart == .monday, "DYNAMICLAKE_PLUGIN_SETTINGS_JSON is read")
        check(jsonEnvironment.current.timeFormat == .h12, "the JSON variable carries every value")

        let perSetting = SettingsStore(environment: [
            "DYNAMICLAKE_SETTING_WEEK_STARTS_ON": "Sunday",
            "DYNAMICLAKE_SETTING_MARK_BUSY_DAYS": "0",
            "DYNAMICLAKE_SETTING_REFRESH_MINUTES": "15",
        ])
        check(perSetting.current.weekStart == .sunday, "per-setting variables are read")
        check(!perSetting.current.markBusyDays, "per-setting switches read 0 as off")
        check(perSetting.current.refreshMinutes == 15, "per-setting numbers are read")

        let warningSetting = SettingsStore(environment: ["DYNAMICLAKE_SETTING_WARN_MINUTES": "20"])
        check(warningSetting.current.warnMinutes == 20, "the warning lead is read from its variable")

        let chipSetting = SettingsStore(environment: ["DYNAMICLAKE_SETTING_PERSISTENT_CHIP": "0"])
        check(!chipSetting.current.persistentChip, "the notch chip switch reads 0 as off")

        let bare = SettingsStore(environment: [:])
        check(bare.current == PluginSettings(), "no settings anywhere means defaults")

        print(failures == 0 ? "settings tests passed" : "\(failures) settings checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
