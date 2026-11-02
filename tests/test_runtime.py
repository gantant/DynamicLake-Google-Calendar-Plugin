#!/usr/bin/env python3
"""Drives the real plugin binary over a mock DynamicLake socket and a local
iCal feed. No DynamicLake and no calendar access are needed.
"""

import json
import os
import pathlib
import re
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from datetime import date, datetime, time as dtime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parent.parent
BINARY = ROOT / "GoogleCalendar.dynamiclakeplugin" / "google-calendar"

failures = 0


def check(condition, label):
    global failures
    if condition:
        print(f"PASS {label}")
    else:
        print(f"FAIL {label}")
        failures += 1


def encode(payload):
    data = json.dumps(payload).encode("utf-8")
    return struct.pack(">I", len(data)) + data


def components(node):
    found = []
    if isinstance(node, dict):
        if isinstance(node.get("type"), str):
            found.append(node)
        for value in node.values():
            found.extend(components(value))
    elif isinstance(node, list):
        for value in node:
            found.extend(components(value))
    return found


def texts(frame):
    return [c.get("text", "") for c in components(frame) if c.get("type") == "text"]


def action_ids(frame):
    return [c.get("actionID") for c in components(frame) if isinstance(c.get("actionID"), str)]


def menu_ids(frame):
    ids = []
    for component in components(frame):
        for item in component.get("contextMenu") or []:
            if isinstance(item, dict) and isinstance(item.get("actionID"), str):
                ids.append(item["actionID"])
    return ids


def lake_content(frame):
    lake = frame.get("lake")
    if isinstance(lake, dict) and isinstance(lake.get("content"), list):
        return lake["content"]
    return []


def is_split_lake(frame):
    return frame.get("type") == "lake" and "prevMonth" in action_ids(frame)


def is_compact_strip(frame):
    return frame.get("type") == "lake" and "prevWeek" in action_ids(frame)


def is_compact_day(frame):
    return frame.get("type") == "lake" and "weekView" in action_ids(frame)


def has_text(frame, needle):
    return any(needle in value for value in texts(frame))


def header_title(frame):
    content = lake_content(frame)
    if not content:
        return None
    for child in content[0].get("children", []):
        if child.get("type") == "text":
            return child.get("text")
    return None


# MARK: - Feed server


class FeedServer:
    def __init__(self, port=0):
        self.payload = b""
        self.requests = 0
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                outer.requests += 1
                body = outer.payload
                self.send_response(200)
                self.send_header("Content-Type", "text/calendar; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.port}/calendar.ics"

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def free_port():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def utc_stamp(moment):
    return moment.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def plain(text):
    """macOS puts a narrow no-break space before AM/PM."""
    return text.replace("\u202f", " ").replace("\u00a0", " ")


def build_feed():
    today = date.today()
    local = datetime.combine(today, dtime(9, 0)).astimezone()
    later = datetime.combine(today, dtime(14, 0)).astimezone()
    tomorrow = today + timedelta(days=1)
    day_after = today + timedelta(days=2)
    retro = datetime.combine(day_after, dtime(11, 0)).astimezone()
    return "\r\n".join([
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Nebulark//Test//EN",
        "X-WR-CALNAME:Test feed",
        "BEGIN:VEVENT",
        "UID:all-hands",
        f"DTSTART;VALUE=DATE:{today.strftime('%Y%m%d')}",
        f"DTEND;VALUE=DATE:{tomorrow.strftime('%Y%m%d')}",
        "SUMMARY:All Hands",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:design-review",
        f"DTSTART:{utc_stamp(local)}",
        f"DTEND:{utc_stamp(local + timedelta(hours=1))}",
        "SUMMARY:Design review",
        "END:VEVENT",
        # One event on the day after tomorrow, so a second day is busy without
        # relying on recurrence.
        "BEGIN:VEVENT",
        "UID:retro",
        f"DTSTART:{utc_stamp(retro)}",
        f"DTEND:{utc_stamp(retro + timedelta(hours=1))}",
        "SUMMARY:Retro",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:daily-sync",
        f"DTSTART:{utc_stamp(later)}",
        f"DTEND:{utc_stamp(later + timedelta(hours=1))}",
        "RRULE:FREQ=DAILY;COUNT=3",
        "SUMMARY:Daily sync",
        "END:VEVENT",
        "END:VCALENDAR",
        "",
    ]).encode("utf-8")


# MARK: - Mock DynamicLake


class MockDynamicLake:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.bind(str(path))
        self.socket.listen(1)
        self.socket.settimeout(10)
        self.connection = None
        self.buffer = b""
        self.frames = []

    def accept(self):
        self.connection, _ = self.socket.accept()
        self.connection.settimeout(0.2)

    def accept_within(self, timeout):
        """Waits for the plugin to come back on the same listening socket."""
        self.socket.settimeout(timeout)
        try:
            self.accept()
            return True
        except (socket.timeout, OSError):
            return False
        finally:
            self.socket.settimeout(10)
        
    def hang_up(self):
        """Drops the connection the way a quitting DynamicLake does."""
        if self.connection:
            try:
                self.connection.close()
            except OSError:
                pass
        self.connection = None
        self.buffer = b""

    def send(self, payload):
        self.connection.sendall(encode(payload))

    def read_frame(self, deadline):
        while time.time() < deadline:
            if len(self.buffer) >= 4:
                length = struct.unpack(">I", self.buffer[:4])[0]
                if len(self.buffer) >= 4 + length:
                    body = self.buffer[4:4 + length]
                    self.buffer = self.buffer[4 + length:]
                    return json.loads(body)
            try:
                chunk = self.connection.recv(65536)
                if chunk:
                    self.buffer += chunk
                    continue
            except socket.timeout:
                pass
            except OSError:
                return None
            time.sleep(0.02)
        return None

    def wait_for(self, predicate, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            frame = self.read_frame(deadline)
            if frame is None:
                continue
            self.frames.append(frame)
            if predicate(frame):
                return frame
        return None

    def close(self):
        if self.connection:
            self.connection.close()
        self.socket.close()


def start_plugin(socket_path, config_path, settings_path=None, package="GoogleCalendar.dynamiclakeplugin", features="lake,lakeLayout,imageAssets"):
    folder = ROOT / package
    environment = os.environ.copy()
    environment.update({
        "DYNAMICLAKE_JSON_SOCKET": str(socket_path),
        "DYNAMICLAKE_PLUGIN_IDENTIFIER": "com.nebulark.google-calendar",
        "DYNAMICLAKE_PLUGIN_PACKAGE": str(folder),
        "DYNAMICLAKE_PLUGIN_FEATURES": features,
        "GOOGLE_CALENDAR_FEEDS": str(config_path),
    })
    if settings_path is not None:
        environment["DYNAMICLAKE_PLUGIN_SETTINGS_PATH"] = str(settings_path)
    return subprocess.Popen([str(folder / "google-calendar")], env=environment)


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()


def action(action_id):
    return {"schemaVersion": 1, "type": "action", "activityID": "lake", "actionID": action_id, "surface": "lake"}


def lake_opened(size, trigger="click"):
    return {"schemaVersion": 1, "type": "lakeOpened", "trigger": trigger, "size": size}


# DynamicLake rejects a whole frame whose identifiers contain anything else, so
# the tests refuse them too (# in an open: action used to lose the week view).
IDENTIFIER = re.compile(r"^[A-Za-z0-9._:-]+$")


def invalid_identifiers(frame):
    bad = []
    for component in components(frame):
        for key in ("id", "actionID", "activityID"):
            value = component.get(key)
            if isinstance(value, str) and not IDENTIFIER.match(value):
                bad.append(f"{key}={value}")
    return bad


def check_identifiers(frames, label):
    bad = sorted({entry for frame in frames for entry in invalid_identifiers(frame)})
    detail = f" [{', '.join(bad[:3])}]" if bad else ""
    check(not bad, f"every {label} identifier stays inside DynamicLake's character set{detail}")


WEEKDAY_SYMBOLS = {"Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"}


def weekday_headings(frame):
    return [t for t in texts(frame) if t in WEEKDAY_SYMBOLS]


def day_button(frame, moment):
    wanted = f"day:{moment.isoformat()}"
    return next((c for c in components(frame) if c.get("actionID") == wanted), None)


def write_settings(path, values):
    path.write_text(json.dumps({
        "schemaVersion": 1,
        "identifier": "com.nebulark.google-calendar",
        "values": values,
    }))


# MARK: - Flows


def run_setup_flow(workspace):
    socket_path = workspace / "setup.sock"
    config_path = workspace / "setup-feeds.txt"
    config_path.write_text("# nothing configured\n")

    mock = MockDynamicLake(socket_path)
    process = start_plugin(socket_path, config_path)
    try:
        mock.accept()
        lake = mock.wait_for(lambda frame: frame.get("type") == "lake" and has_text(frame, "Add your calendar"))
        check(lake is not None, "an empty feed list shows the setup card")
        if lake:
            check("openFeeds" in action_ids(lake), "the setup card opens feeds.txt")
    finally:
        stop(process)
        mock.close()


def run_feed_flow(workspace):
    socket_path = workspace / "feed.sock"
    config_path = workspace / "feeds.txt"
    settings_path = workspace / "feed-settings.json"
    port = free_port()
    config_path.write_text(f"http://127.0.0.1:{port}/calendar.ics\n")
    # Warnings off here: an event close to the hour would otherwise create an
    # activity and make the "nothing sits in the notch" check flaky.
    write_settings(settings_path, {"warnMinutes": 0})

    mock = MockDynamicLake(socket_path)
    process = start_plugin(socket_path, config_path, settings_path)
    server = None

    try:
        mock.accept()

        error = mock.wait_for(lambda frame: frame.get("type") == "lake" and has_text(frame, "Can't load your calendar"))
        check(error is not None, "a dead feed shows the error card")
        if error:
            check("refresh" in action_ids(error), "the error card offers a retry")
            details = [t for t in texts(error) if t and t not in ("Can't load your calendar", "Try again", "Feeds")]
            check(bool(details), "the error card names the reason")

        server = FeedServer(port=port)
        server.payload = build_feed()
        mock.send(action("refresh"))

        split = mock.wait_for(is_split_lake)
        check(split is not None, "retrying after the feed comes up draws the month")
        if split is None:
            return

        check(server.requests > 0, "the plugin fetched the feed")

        created = [f for f in mock.frames if f.get("type") == "create" and f.get("activityID") == "calendar"]
        check(bool(created), "the standing notch chip is created so the lake can be opened")
        check(bool(created) and created[0].get("priority") == "low", "the chip stays low priority")

        write_settings(settings_path, {"warnMinutes": 0, "persistentChip": False})
        check(mock.wait_for(lambda frame: frame.get("type") == "dismiss" and frame.get("activityID") == "calendar", timeout=8) is not None,
              "turning the notch chip off clears it without a restart")
        write_settings(settings_path, {"warnMinutes": 0, "persistentChip": True})
        check(mock.wait_for(lambda frame: frame.get("type") in ("create", "update") and frame.get("activityID") == "calendar", timeout=8) is not None,
              "turning the notch chip on brings it back")

        today = date.today()
        tomorrow = today + timedelta(days=1)
        today_button = day_button(split, today)
        check(today_button is not None, "today is on the grid")
        check((today_button or {}).get("tint") == "red", "today opens selected and red")
        check((today_button or {}).get("title") == str(today.day), "day buttons carry only the number")

        titles = texts(split)
        check("Design review" in titles, "today's agenda is already on the left")
        check("Daily sync" in titles, "recurring events are expanded into the agenda")
        check("All Hands" in titles, "all-day events are listed")
        check("All day" in [t.strip() for t in titles], "all-day events read All day")

        agenda_texts = [plain(t).strip() for t in titles]
        check("9:00 AM" in agenda_texts or "9:00" in agenda_texts, "the agenda shows event times")
        open_items = [
            item.get("actionID")
            for component in components(split)
            for item in component.get("contextMenu") or []
            if isinstance(item, dict) and (item.get("actionID") or "").startswith("open:")
        ]
        check(len(open_items) == 3, "every agenda row carries an open action")
        check(not any((c.get("actionID") or "").startswith("open:") for c in components(split)),
              "no arrow buttons crowd the event rows")

        title = header_title(split)
        check(title is not None and str(today.year) not in title, "the month title leaves the year out")
        check(weekday_headings(split)[:7] == ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"], "the grid keeps its weekday headings")
        check("openFeeds" in menu_ids(split), "right-clicking the card reaches feeds.txt")
        check("prevMonth" in action_ids(split) and "nextMonth" in action_ids(split), "the month arrows are in the header")
        check("today" not in action_ids(split), "the current month hides the Today button")

        glance = (split.get("lake") or {}).get("glance")
        check(isinstance(glance, dict), "the lake sends its own DynaGlance design")
        if isinstance(glance, dict):
            check(glance.get("hideHeader") is True, "the glance skips DynamicLake's header row")
            check("bottom" not in glance, "the glance has no bottom section")
            glance_titles = [plain(t).strip() for t in texts(glance)]
            check("Design review" in glance_titles, "the glance previews today's agenda")
            check("Daily sync" in glance_titles, "the glance expands recurring events")
            check("All day" in glance_titles, "the glance keeps all-day events")
            check(str(today.day) in glance_titles, "the glance leads with today's date")
            check(not any((c.get("actionID") or "").startswith("open:") for c in components(glance)),
                  "glance rows carry no lake-only open action")

        busy_button = day_button(split, tomorrow)
        check((busy_button or {}).get("tint") == "blue", "a day with events is blue")

        quiet = today.replace(day=1) if today.day > 1 else today.replace(day=10)
        mock.send(action(f"day:{quiet.isoformat()}"))
        empty = mock.wait_for(lambda frame: is_split_lake(frame) and has_text(frame, "No events"))
        check(empty is not None, "tapping a quiet day shows an empty agenda beside the grid")
        if empty is not None:
            check((day_button(empty, quiet) or {}).get("tint") == "red", "the tapped day turns red")
            check((day_button(empty, today) or {}).get("tint") == "blue", "the day that was selected goes back to blue")

        mock.send(action("today"))
        restored = mock.wait_for(lambda frame: is_split_lake(frame) and has_text(frame, "Design review"))
        check(restored is not None, "Today returns the agenda to today")

        mock.send(action("nextMonth"))
        moved = mock.wait_for(is_split_lake)
        check(moved is not None and header_title(moved) != title, "next month redraws with a new title")
        check(moved is not None and "today" in action_ids(moved), "another month reveals the Today button")

        mock.send(action("today"))
        back = mock.wait_for(is_split_lake)
        check(back is not None and "today" not in action_ids(back), "Today disappears again on the current month")

        # A second, broken feed: the card keeps the working feed's events and
        # says that part of the calendar is missing.
        base_config = config_path.read_text()
        dead_feed = f"http://127.0.0.1:{free_port()}/missing.ics"
        config_path.write_text(base_config + dead_feed + "\n")
        degraded = mock.wait_for(lambda frame: is_split_lake(frame) and has_text(frame, "feed failed"), timeout=10)
        check(degraded is not None, "one broken feed leaves the rest of the calendar on screen")
        if degraded is not None:
            check("Design review" in texts(degraded), "the working feed still fills the agenda")
            check("openFeeds" in menu_ids(degraded), "the feed warning reaches feeds.txt")

        config_path.write_text(base_config)
        recovered = mock.wait_for(lambda frame: is_split_lake(frame) and not has_text(frame, "feed failed"), timeout=10)
        check(recovered is not None, "the warning clears once every feed answers")

        mock.send(lake_opened("small"))
        strip = mock.wait_for(is_compact_strip)
        check(strip is not None, "a small lake draws the week strip instead")
        if strip is not None:
            strip_days = [c for c in components(strip) if (c.get("actionID") or "").startswith("day:")]
            check(len(strip_days) == 7, "the small card shows exactly one week")
            check("prevWeek" in action_ids(strip) and "nextWeek" in action_ids(strip), "the small card steps by week")
            check("prevMonth" not in action_ids(strip), "the small card has no month arrows")
            check("today" not in action_ids(strip), "the current week hides the Today button")

            mock.send(action("nextWeek"))
            next_week = mock.wait_for(is_compact_strip)
            check(next_week is not None and "today" in action_ids(next_week), "another week reveals the Today button")

            mock.send(action("today"))
            current_week = mock.wait_for(is_compact_strip)
            check(current_week is not None and "today" not in action_ids(current_week), "Today disappears again on the current week")

            mock.send(action(f"day:{today.isoformat()}"))
            day_view = mock.wait_for(is_compact_day)
            check(day_view is not None, "tapping a day replaces the strip with the agenda")
            if day_view is not None:
                day_titles = [plain(t).strip() for t in texts(day_view)]
                check("Design review" in day_titles, "the compact agenda lists the day's events")
                check("No events" not in day_titles, "the compact agenda is not stuck on an empty day")
                check(str(today.day) in day_titles, "the compact agenda leads with the day number")
                check("today" not in action_ids(day_view), "today's agenda hides the Today button")

                mock.send(action("weekView"))
                check(mock.wait_for(is_compact_strip) is not None, "the back chevron restores the week strip")

        mock.send(lake_opened("normal"))
        check(mock.wait_for(is_split_lake) is not None, "opening the normal lake goes back to the split card")

        mock.send(action("closeLake"))
        check(mock.wait_for(lambda frame: frame.get("type") == "closeLake") is not None,
              "the Close menu item asks DynamicLake to close the lake")

        server.stop()
        server = None
        mock.send(action("refresh"))
        # Keep reading while the fetch fails, or the unread frames fill the
        # socket and the plugin gives up on this connection.
        mock.wait_for(lambda frame: False, timeout=1.5)
        mock.send(action("today"))
        stale = mock.wait_for(lambda frame: is_split_lake(frame) and has_text(frame, "Design review"), timeout=8)
        check(stale is not None, "a failed refresh keeps the last good agenda on screen")

        errors = [frame for frame in mock.frames if frame.get("type") == "error"]
        check(not errors, "DynamicLake reported no protocol errors")
        check_identifiers(mock.frames, "feed flow")
    finally:
        if server is not None:
            server.stop()
        stop(process)
        mock.close()


def run_small_package_flow(workspace):
    """The small package declares lake.size small, so it must draw a week from
    its very first frame, before DynamicLake has said anything."""
    socket_path = workspace / "small.sock"
    config_path = workspace / "small-feeds.txt"
    port = free_port()
    config_path.write_text(f"http://127.0.0.1:{port}/calendar.ics\n")

    server = FeedServer(port=port)
    server.payload = build_feed()
    mock = MockDynamicLake(socket_path)
    process = start_plugin(socket_path, config_path, package="GoogleCalendarSmall.dynamiclakeplugin")

    try:
        manifest = json.loads((ROOT / "GoogleCalendar.dynamiclakeplugin" / "plugin.json").read_text())
        small_manifest = json.loads((ROOT / "GoogleCalendarSmall.dynamiclakeplugin" / "plugin.json").read_text())
        normal_lake = manifest.get("lake") or {}
        small_lake = small_manifest.get("lake") or {}
        check((normal_lake.get("glance") or {}).get("systemImage") == "calendar",
              "the manifest puts a calendar button in DynaGlance")
        check((small_lake.get("glance") or {}).get("systemImage") == "calendar",
              "the small package keeps the DynaGlance button")
        check(small_lake.get("size") == "small", "the small package still declares itself small")

        mock.accept()
        # The loading card comes first; wait for the frame that actually draws days.
        first = mock.wait_for(lambda frame: any(a.startswith("day:") for a in action_ids(frame)))
        check(first is not None and is_compact_strip(first), "the small package starts in the week view without being told its size")
        check(first is not None and not is_split_lake(first), "the small package never draws the split card first")
        if first is not None:
            check(str(date.today().year) not in (header_title(first) or ""), "the small package leaves the year out")
            strip_days = [c for c in components(first) if (c.get("actionID") or "").startswith("day:")]
            check(len(strip_days) == 7, "the small package draws seven days")

            mock.send(action(f"day:{date.today().isoformat()}"))
            day_view = mock.wait_for(is_compact_day)
            check(day_view is not None, "the small package opens a day from its strip")
            if day_view is not None:
                check("Design review" in [t.strip() for t in texts(day_view)], "the small package lists that day's events")

                mock.send({"schemaVersion": 1, "type": "lakeClosed"})
                mock.send(lake_opened("small"))
                check(mock.wait_for(is_compact_strip) is not None, "closing and reopening the small lake returns to the week")

        check_identifiers(mock.frames, "small package")
        errors = [frame for frame in mock.frames if frame.get("type") == "error"]
        check(not errors, "the small package raises no protocol errors")
    finally:
        server.stop()
        stop(process)
        mock.close()


def build_warning_feed():
    start = datetime.now().astimezone() + timedelta(minutes=5)
    end = start + timedelta(minutes=30)
    return "\r\n".join([
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Nebulark//Test//EN",
        "BEGIN:VEVENT",
        "UID:standup-soon",
        f"DTSTART:{utc_stamp(start)}",
        f"DTEND:{utc_stamp(end)}",
        "SUMMARY:Standup soon",
        "END:VEVENT",
        "END:VCALENDAR",
        "",
    ]).encode("utf-8")


def run_warning_flow(workspace):
    socket_path = workspace / "warn.sock"
    config_path = workspace / "warn-feeds.txt"
    settings_path = workspace / "warn-settings.json"
    port = free_port()
    config_path.write_text(f"http://127.0.0.1:{port}/calendar.ics\n")
    write_settings(settings_path, {"warnMinutes": 10, "persistentChip": False})

    server = FeedServer(port=port)
    server.payload = build_warning_feed()
    mock = MockDynamicLake(socket_path)
    process = start_plugin(
        socket_path,
        config_path,
        settings_path,
        features="lake,lakeLayout,imageAssets,presentSneakPeek",
    )

    try:
        mock.accept()
        # The chip is off here, so the warning itself brings the activity up.
        warning = mock.wait_for(
            lambda frame: frame.get("type") == "create" and frame.get("activityID") == "calendar",
            timeout=15,
        )
        check(warning is not None, "an event about to start peeks the notch")
        if warning is not None:
            check(warning.get("presentSneakPeek") == 5, "the peek opens itself for a few seconds")
            check(warning.get("priority") == "normal" and warning.get("size") == "small",
                  "the warning is a normal, small activity")
            check("Standup soon" in json.dumps(warning), "the warning names the event")
            check("sneakPeek" in warning.get("surfaces", {}), "the warning has sneak peek content")

        dismissed = mock.wait_for(
            lambda frame: frame.get("type") == "dismiss" and frame.get("activityID") == "calendar",
            timeout=15,
        )
        check(dismissed is not None, "the warning chip clears itself afterwards")

        extra = [
            frame for frame in mock.frames
            if frame.get("type") == "create" and frame.get("activityID") == "calendar"
        ]
        check(len(extra) == 1, "the same event is only warned about once")
        check_identifiers(mock.frames, "warning flow")
        errors = [frame for frame in mock.frames if frame.get("type") == "error"]
        check(not errors, "DynamicLake reported no protocol errors for warnings")
    finally:
        server.stop()
        stop(process)
        mock.close()


def build_upcoming_feed(start):
    end = start + timedelta(minutes=30)
    return "\r\n".join([
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Nebulark//Test//EN",
        "BEGIN:VEVENT",
        "UID:next-up",
        f"DTSTART:{utc_stamp(start)}",
        f"DTEND:{utc_stamp(end)}",
        "SUMMARY:Next up",
        "END:VEVENT",
        "END:VCALENDAR",
        "",
    ]).encode("utf-8")


def run_peek_flow(workspace):
    """The standing chip's sneak peek names the next event still to come today."""
    start = datetime.now().astimezone() + timedelta(minutes=3)
    if start.date() != date.today():
        # There is no future time left today, so the peek has nothing to name.
        print("SKIP peek flow (the upcoming event falls after midnight)")
        return

    socket_path = workspace / "peek.sock"
    config_path = workspace / "peek-feeds.txt"
    settings_path = workspace / "peek-settings.json"
    port = free_port()
    config_path.write_text(f"http://127.0.0.1:{port}/calendar.ics\n")
    write_settings(settings_path, {"warnMinutes": 0, "persistentChip": True})

    server = FeedServer(port=port)
    server.payload = build_upcoming_feed(start)
    mock = MockDynamicLake(socket_path)
    process = start_plugin(socket_path, config_path, settings_path)

    try:
        mock.accept()
        chip = mock.wait_for(
            lambda frame: frame.get("activityID") == "calendar"
            and frame.get("type") in ("create", "update")
            and "Next up" in json.dumps(frame),
            timeout=15,
        )
        check(chip is not None, "the standing chip peeks the next event of the day")
        if chip is not None:
            peek = (chip.get("surfaces") or {}).get("sneakPeek") or {}
            center = peek.get("center") or {}
            check("Next up" in (center.get("text") or ""), "the peek names the next event")
            check(chip.get("priority") == "low", "the next-event peek stays a low-priority chip")

        check_identifiers(mock.frames, "peek flow")
        errors = [frame for frame in mock.frames if frame.get("type") == "error"]
        check(not errors, "DynamicLake reported no protocol errors for the peek")
    finally:
        server.stop()
        stop(process)
        mock.close()


def run_settings_flow(workspace):
    socket_path = workspace / "settings.sock"
    config_path = workspace / "settings-feeds.txt"
    settings_path = workspace / "plugin-settings.json"
    port = free_port()
    config_path.write_text(f"http://127.0.0.1:{port}/calendar.ics\n")
    write_settings(settings_path, {"weekStartsOn": "Monday", "timeFormat": "24-Hour"})

    server = FeedServer(port=port)
    server.payload = build_feed()
    mock = MockDynamicLake(socket_path)
    process = start_plugin(socket_path, config_path, settings_path)

    try:
        mock.accept()
        split = mock.wait_for(is_split_lake)
        check(split is not None, "the month draws with the settings file DynamicLake passes")
        if split is None:
            return

        check(weekday_headings(split)[:7] == ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"],
              "the week-start setting rotates the weekday headings")
        check("09:00" in [plain(t).strip() for t in texts(split)], "the 24-hour setting writes 09:00 instead of 9:00 AM")

        tomorrow = date.today() + timedelta(days=1)
        check((day_button(split, tomorrow) or {}).get("tint") == "blue", "busy days are blue while the setting is on")

        write_settings(settings_path, {"weekStartsOn": "Sunday", "markBusyDays": False, "timeFormat": "24-Hour"})
        updated = mock.wait_for(
            lambda frame: is_split_lake(frame) and weekday_headings(frame)[:1] == ["Su"],
            timeout=8,
        )
        check(updated is not None, "changing a setting redraws the month without a restart")
        if updated is not None:
            check((day_button(updated, tomorrow) or {}).get("tint") == "gray",
                  "turning the highlight off leaves busy days gray")

        write_settings(settings_path, {"weekStartsOn": "Monday", "timeFormat": "24-Hour", "showAllDayEvents": False})
        hidden = mock.wait_for(lambda frame: is_split_lake(frame) and not has_text(frame, "All Hands"), timeout=8)
        check(hidden is not None, "the agenda redraws after the all-day switch")
        if hidden is not None:
            titles = [t.strip() for t in texts(hidden)]
            check("All Hands" not in titles, "turning off all-day events drops them from the agenda")
            check("Design review" in titles, "timed events stay in the agenda")

        settings_path.write_text("{ \"values\": ")
        mock.send(action("today"))
        check(mock.wait_for(is_split_lake) is not None, "a half-written settings file leaves the card working")

        check_identifiers(mock.frames, "settings flow")
        errors = [frame for frame in mock.frames if frame.get("type") == "error"]
        check(not errors, "DynamicLake reported no protocol errors with settings")
    finally:
        server.stop()
        stop(process)
        mock.close()


def run_reconnect_flow(workspace):
    """The plugin reads its socket instead of polling it, so a host that goes
    away and comes back has to be noticed and repainted, not waited on."""
    socket_path = workspace / "reconnect.sock"
    config_path = workspace / "reconnect-feeds.txt"
    port = free_port()
    config_path.write_text(f"http://127.0.0.1:{port}/calendar.ics\n")

    server = FeedServer(port=port)
    server.payload = build_feed()
    mock = MockDynamicLake(socket_path)
    process = start_plugin(socket_path, config_path)

    try:
        check(mock.accept_within(10), "the plugin connects to a fresh socket")
        check(mock.wait_for(is_split_lake) is not None, "the first connection draws the card")
        before = len(mock.frames)

        mock.hang_up()
        check(mock.accept_within(6), "the plugin reconnects after DynamicLake drops the socket")
        repaint = mock.wait_for(is_split_lake, timeout=6)
        check(repaint is not None, "the reconnected plugin repaints without being asked")
        check(repaint is not None and len(mock.frames) > before, "the repaint is a new frame, not a replay")
        check(process.poll() is None, "the plugin is still running after one reconnect")

        check_identifiers(mock.frames, "reconnect flow")
        errors = [frame for frame in mock.frames if frame.get("type") == "error"]
        check(not errors, "DynamicLake reported no protocol errors across the reconnect")
    finally:
        server.stop()
        stop(process)
        mock.close()


def main():
    if not BINARY.exists():
        print(f"missing binary: {BINARY}")
        return 1

    with tempfile.TemporaryDirectory(prefix="gcal") as directory:
        workspace = pathlib.Path(directory)
        run_setup_flow(workspace)
        run_feed_flow(workspace)
        run_warning_flow(workspace)
        run_peek_flow(workspace)
        run_small_package_flow(workspace)
        run_settings_flow(workspace)
        run_reconnect_flow(workspace)

    print("runtime tests passed" if failures == 0 else f"{failures} runtime checks failed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
