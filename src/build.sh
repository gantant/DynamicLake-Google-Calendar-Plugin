#!/bin/bash
# Build the Google Calendar DynamicLake plugins:
#   arm64 + x86_64 slices -> lipo universal binary -> assemble packages -> zip
#
# Two packages come out of the same binary:
#   GoogleCalendar.dynamiclakeplugin      lake size normal: agenda beside the month
#   GoogleCalendarSmall.dynamiclakeplugin lake size small:  a week that opens a day
# DynamicLake fixes a lake's size at install, so a small lake needs its own
# package (and its own identifier) rather than a setting.
# Run from anywhere:  src/build.sh
set -euo pipefail
cd "$(dirname "$0")"

PKG="../GoogleCalendar.dynamiclakeplugin"
ZIP="../GoogleCalendar.dynamiclakeplugin.zip"
SMALL_PKG="../GoogleCalendarSmall.dynamiclakeplugin"
SMALL_ZIP="../GoogleCalendarSmall.dynamiclakeplugin.zip"
SLICE_DIR=$(mktemp -d)
trap 'rm -rf "$SLICE_DIR"' EXIT

PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
    for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
        if [ -x "$candidate" ]; then PYTHON="$candidate"; break; fi
    done
fi
PYTHON="${PYTHON:-/usr/bin/python3}"

SOURCES=(Shared/DynamicLakeSocket.swift CalendarModel.swift EventModel.swift ICalendar.swift Recurrence.swift SnapshotBuilder.swift AgendaPlanner.swift NotchPeek.swift DeadlinePlanner.swift CalendarFeed.swift PluginSettings.swift LakeView.swift GoogleCalendarPlugin.swift)
# AppKit is for NSWorkspace: opening feeds.txt or a Google Calendar link no longer
# spawns /usr/bin/open.
FRAMEWORKS=(-framework Foundation -framework AppKit)

for arch in arm64 x86_64; do
    echo "==> Compiling $arch slice"
    swiftc -parse-as-library -O -swift-version 5 -target "${arch}-apple-macosx14.0" \
        "${FRAMEWORKS[@]}" -o "$SLICE_DIR/google-calendar-$arch" "${SOURCES[@]}"
done

echo "==> Merging universal binary (lipo)"
lipo -create -output "$SLICE_DIR/google-calendar" \
    "$SLICE_DIR/google-calendar-arm64" "$SLICE_DIR/google-calendar-x86_64"
lipo -info "$SLICE_DIR/google-calendar"

# lipo keeps each slice's own linker signature, so the merged file reports the
# arm64 slice's identifier and its signature covers only that slice. Sign the
# universal file itself, with a stable identifier, so the whole binary verifies.
echo "==> Ad-hoc signing the universal binary"
codesign --force --sign - --identifier "com.nebulark.google-calendar" \
    --timestamp=none "$SLICE_DIR/google-calendar"
codesign --verify --strict "$SLICE_DIR/google-calendar"

assemble() { # $1 = package folder, $2 = manifest source
    local pkg="$1" manifest="$2"
    rm -rf "$pkg.old"
    [ -e "$pkg" ] && mv "$pkg" "$pkg.old"
    mkdir -p "$pkg"
    cp "$SLICE_DIR/google-calendar" "$pkg/google-calendar"
    cp "$manifest" "$pkg/plugin.json"
    cp icon.png "$pkg/icon.png"
    chmod +x "$pkg/google-calendar"
    rm -rf "$pkg.old"
    touch "$pkg"
}

echo "==> Assembling $PKG"
assemble "$PKG" plugin.json
cp "$SLICE_DIR/google-calendar" google-calendar   # keep the src copy in sync

echo "==> Deriving the small-lake manifest"
"$PYTHON" - "$PKG/plugin.json" "$SLICE_DIR/plugin-small.json" <<'PY'
import json, sys

source, destination = sys.argv[1], sys.argv[2]
with open(source) as handle:
    manifest = json.load(handle)

manifest["identifier"] = "com.nebulark.google-calendar-small"
manifest["name"] = "Google Calendar Week"
manifest["description"] = "A one-week calendar in the notch that opens a day's agenda, read from Google Calendar iCal feeds."
# Keep the lake's other keys (the DynaGlance button) and only change the size.
lake = manifest.get("lake")
if not isinstance(lake, dict):
    lake = {}
lake["size"] = "small"
manifest["lake"] = lake

with open(destination, "w") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

echo "==> Assembling $SMALL_PKG"
assemble "$SMALL_PKG" "$SLICE_DIR/plugin-small.json"

echo "==> Packaging $ZIP"
# --norsrc/--noextattr keep AppleDouble (._*) entries out of the archive.
ditto -c -k --keepParent --norsrc --noextattr "$PKG" "$ZIP"
touch "$ZIP"

echo "==> Packaging $SMALL_ZIP"
ditto -c -k --keepParent --norsrc --noextattr "$SMALL_PKG" "$SMALL_ZIP"
touch "$SMALL_ZIP"

echo "==> Done. Install via DynamicLake Playground > Settings > Plugins > Install Local"
