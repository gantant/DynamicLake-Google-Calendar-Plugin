# Google Calendar for DynamicLake

A DynamicLake plugin that puts a month calendar, a week strip and a daily agenda in the notch, read from Google Calendar's secret iCal feeds. Nothing is written back to Google: the plugin only reads the feeds you list.

## Features

- **Month card** (410 × 186): the month beside the selected day's agenda, with busiest-first colouring — the selection red, days with events blue, quiet days gray. The **Today** button appears only once you have paged away from the current month, so it never sits there as decoration.
- **Week card** (390 × 110, its own package): seven days with the same colours. Tapping a day swaps the strip for that day's agenda; a back chevron returns to the week, and **Today** appears only when the week you are looking at is not the current one.
- **DynaGlance**: the same calendar in DynamicLake's split view, designed for the space rather than squeezed into it. A small red weekday and a gray month over an oversized white day number, then a scrolling agenda where each event carries a coloured marker for the calendar it belongs to. A day with more than 24 events ends with `+N more` instead of overrunning the glance's component budget.
- **Notch chip**: a low-priority chip whose peek names the next event still to start today. With nothing timed left it names an all-day event, and only an empty day falls back to the date.
- **Warnings**: an optional peek N minutes before a timed event starts, once per event.
- **All-day events** appear in the agenda and the chip, and can be switched off entirely.

## Requirements

- macOS 14.0 or later, Apple Silicon or Intel (one universal binary).
- DynamicLake or DynamicLake Playground with the `lake` and `lakeLayout` features. Without them the live activity still works and the lake is simply not offered.

## Install

Open `GoogleCalendar.dynamiclakeplugin.zip` with DynamicLake, or install locally: DynamicLake Playground → Settings → Plugins → Install Local → `GoogleCalendar.dynamiclakeplugin`.

For the small card, install `GoogleCalendarSmall.dynamiclakeplugin.zip` — a separate package because DynamicLake fixes a lake's size at install, and it needs its own identifier (`com.nebulark.google-calendar-small`).

```
GoogleCalendar.dynamiclakeplugin/
├── plugin.json   # manifest, id com.nebulark.google-calendar
├── google-calendar  # universal binary, arm64 + x86_64
└── icon.png
```

## Adding your calendars

Right-click the lake → **Open feeds.txt** (or the settings row's button), then paste one **Secret address in iCal format** per line. Google Calendar → Settings → pick the calendar → scroll to the bottom → Secret address in iCal format.

The file at `~/Library/Application Support/Google Calendar/feeds.txt` is created with a template that already contains Google's **US holidays** calendar, commented out — remove the leading `#` from its line to show those holidays. Lines starting with `#` are ignored, so the file is safe to annotate.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Week Starts On | System | First column of the month grid and the week strip |
| Time Format | System | `9:30 AM` or `09:30` |
| Highlight Days With Events | On | Off leaves every day gray |
| Show All-Day Events | On | Off drops them from the agenda and the dots |
| Keep a Notch Chip | On | Off keeps the notch clear between events |
| Warn Before Events | 10 min | 0 turns warnings off |
| Refresh Interval | 5 min | Applies with the lake closed too |

## How it reads a feed

The parser covers the parts of RFC 5545 that Google actually emits: `DAILY`/`WEEKLY`/`MONTHLY`/`YEARLY` with `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY` (including `2TU`, `-1FR`), `BYMONTHDAY`, `BYMONTH`, plus `EXDATE`, `RDATE` and `RECURRENCE-ID` overrides. `STATUS:CANCELLED` hides an event; `TRANSP:TRANSPARENT` (marked free in Google) does not, because a free meeting still exists.

Two time-zone rules, both covered by tests:

- Recurrence candidates are rebuilt from the event's wall-clock time, so a 09:00 series stays at 09:00 across a DST change.
- All-day occurrences advance by **calendar days**, not 24-hour blocks, so a series ending at local midnight still ends at midnight on a 23- or 25-hour day. Advancing by seconds used to mark the day after a DST change busy.

Feeds download in parallel (four at a time), with a 15-second timeout and an 8 MB cap per feed. A feed that fails is reported on the card as `1 feed failed` (or `N feeds failed`) while the feeds that answered stay on screen; every feed failing shows `Can't refresh` over the last good month.

## How it stays idle

Nothing ticks. The plugin sleeps in the run loop and is woken only by something that happened:

- **DynamicLake's socket** is a read source, so a frame wakes the plugin instead of the plugin asking for one. A socket the host closes is noticed immediately rather than at the next tick.
- **One timer**, armed to the next thing the plugin actually has to do — a warning, a chip repaint, a feed refresh — plus a clock deadline. An idle plugin wakes roughly once every twenty seconds, not sixty times a second.
- **`feeds.txt` and the settings file** are followed by file watchers, so an edit applies at once (including the in-place rewrite an editor does) with no re-read on a timer.
- **Opening a folder or URL** goes through `NSWorkspace`, so the plugin spawns no processes at all.

If DynamicLake quits, reconnects start at half a second and back off to eight, and after roughly a minute of nothing the plugin exits so DynamicLake can relaunch it rather than sitting orphaned in the notch.

## Build and test

```bash
./src/build.sh    # both slices, lipo, assemble both packages, zip
./tests/run.sh    # four suites: model and glance, iCal, settings, runtime
```

The runtime suite drives the real binary over DynamicLake's framed socket — mock host, mock feeds — covering the lake and glance frames, actions, settings changes, feed failures, the chip peek, reconnecting to a host that dropped the socket, and every identifier character rule.

## Privacy

- The only network requests are the feed URLs in `feeds.txt`.
- No telemetry, no analytics, no account access — the feeds are read-only and unauthenticated.
- The log at `~/Library/Logs/google-calendar.log` records lifecycle events and the *host* of a failed feed, never its path or query, and rotates at 1 MB.

## Changelog

Current version: **1.1.0** — see [CHANGELOG.md](CHANGELOG.md) for the full history.
