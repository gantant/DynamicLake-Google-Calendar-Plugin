#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer a real interpreter over Apple's /usr/bin/python3 shim.
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
    for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [ -x "$candidate" ]; then
            PYTHON="$candidate"
            break
        fi
    done
fi
PYTHON="${PYTHON:-/usr/bin/python3}"
echo "==> Using $PYTHON ($("$PYTHON" -V 2>&1))"

./src/build.sh

MODEL_BIN=$(mktemp -t gcal-model-tests)
ICAL_BIN=$(mktemp -t gcal-ical-tests)
SETTINGS_BIN=$(mktemp -t gcal-settings-tests)
trap 'rm -f "$MODEL_BIN" "$ICAL_BIN" "$SETTINGS_BIN"' EXIT

echo "==> Calendar model suite"
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$MODEL_BIN" \
    src/CalendarModel.swift src/EventModel.swift src/LakeView.swift tests/CalendarModelTests.swift
"$MODEL_BIN"

echo "==> iCal feed suite"
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$ICAL_BIN" \
    src/CalendarModel.swift src/EventModel.swift src/ICalendar.swift src/Recurrence.swift \
    src/SnapshotBuilder.swift src/AgendaPlanner.swift src/NotchPeek.swift src/DeadlinePlanner.swift \
    src/CalendarFeed.swift tests/ICalendarTests.swift
"$ICAL_BIN"

echo "==> Settings suite"
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" \
    -o "$SETTINGS_BIN" \
    src/PluginSettings.swift tests/SettingsTests.swift
"$SETTINGS_BIN"

"$PYTHON" tests/test_runtime.py
