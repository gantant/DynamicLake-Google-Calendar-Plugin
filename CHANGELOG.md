# Changelog

All notable changes to the Google Calendar plugin. The latest release is also summarized in the [README](README.md).

## 1.1.0

The DynaGlance view is designed rather than squeezed, and the release audit turned up four defects in how the plugin picks its window and its day.

- **DynaGlance**: the tile gets its own design instead of a copy of the card — a small red weekday and gray month above an oversized white day number, then a scrolling agenda where every event carries a coloured marker for the calendar it came from (a stable colour per feed, since iCal carries no event colours). The glance describes today even after the lake has been paged to another month, which used to label it with the browsed month.
- **Glance frames that were silently rejected**: `size` is a lake-content-only field, and a glance is a fixed-size surface, so an SF Symbol marker carrying one made DynamicLake discard the whole frame — the tile sat on "fetching calendar" with nothing drawn. Markers are tinted glyphs now, and every glance state (ready, loading, setup, failed) is asserted to carry no `size` and no images.
- **Day rollover**: a plugin left running overnight kept yesterday selected, and on the first of a month kept yesterday's month too, so today's events — including an all-day event — did not appear until **Today** was pressed. Midnight now follows the new day and month unless the user has browsed to another one, which is left alone.
- **Old series**: expansion jumped no further than its 1,200-period budget, so a rule that began in 2015 stopped generating somewhere in 2018 and its occurrences vanished from every later window. Expansion now skips ahead to the window, keeping `COUNT` counted from the series start (where the count itself bounds the work), and gives a multi-day occurrence that began before the window room to still overlap it.
- **Stale feeds behind a closed lake**: refreshes only ran while the lake was open, so a chip-only install never refreshed at all and the glance could show yesterday's download indefinitely. The interval now applies regardless, one GET per feed per interval. A feed edited while a fetch was already running is reloaded as soon as that fetch lands instead of waiting for the next tick.
- **Event-driven instead of polling**: the plugin used to wake sixty times a second to re-poll its socket, its feeds and its settings; a read source on DynamicLake's socket, one timer armed to the next deadline it actually has, and file watchers on `feeds.txt` and the settings file replaced the tick. Idle work is a handful of milliseconds every twenty seconds, and a settings or feeds edit applies the moment it is saved.
- **No subprocesses**: opening the settings folder, `feeds.txt` or a help URL goes through `NSWorkspace` instead of spawning `/usr/bin/open`, so the plugin runs no child processes at all.
- **Reconnects back off and give up**: a host that quits is retried from half a second out to eight, and after about a minute the plugin exits so DynamicLake can relaunch it instead of leaving an orphan rewriting its log forever. The runtime suite now covers a dropped socket and the repaint that follows it.
- **Busy days**: a day with more than 24 events ends the glance's agenda with `+N more` rather than pushing the tile past DynamicLake's 160-component glance budget.
- All-day occurrences advance by calendar days rather than 24-hour blocks, so a series no longer marks the day after a DST change busy or shows an event a day late.
- A partial feed failure is reported (`1 feed failed`) while the feeds that answered stay on screen, and every feed failing reads `Can't refresh` over the last good month. Feeds load in parallel, with a 15-second timeout and an 8 MB cap each.
- `feeds.txt` ships Google's US holidays feed commented out, with a note that removing the `#` turns it on.
- New icon: square, full-bleed 512 × 512, with no baked rounded corners so DynamicLake's own radius is the only one.

## 1.0.0

Initial release: a month card with a daily agenda, a small week strip in its own package, busy-day colouring, the standing notch chip and pre-event warnings, read from Google Calendar's secret iCal feeds.
