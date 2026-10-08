#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/screenshots
UDID="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for runtime,items in d["devices"].items() if "iOS" in runtime for x in items if x["name"].startswith("iPhone")))')"
STATE="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["state"] for items in d["devices"].values() for x in items if x["udid"]==sys.argv[1]))' "$UDID")"
if [ "$STATE" != Booted ]; then xcrun simctl boot "$UDID"; fi
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100
xcrun simctl install "$UDID" build/simulator/Build/Products/Debug-iphonesimulator/Daylight.app
for theme in light dark; do
  xcrun simctl ui "$UDID" appearance "$theme"
  for tab in today finance plan health settings; do
    xcrun simctl launch --terminate-running-process "$UDID" com.personalassistant.Daylight --capture-tab "$tab"
    sleep 2
    xcrun simctl io "$UDID" screenshot "build/screenshots/$tab-$theme.png"
  done
  for page in planner planner-settings planner-preview planner-analysis schedule; do
    xcrun simctl launch --terminate-running-process "$UDID" com.personalassistant.Daylight --capture-tab plan "--capture-$page"
    # First Keychain access and sheet presentation can take longer on a fresh runner.
    sleep 8
    xcrun simctl io "$UDID" screenshot "build/screenshots/$page-$theme.png"
  done
  for page in bank-import bank-review bank-notification; do
    xcrun simctl launch --terminate-running-process "$UDID" com.personalassistant.Daylight --capture-tab finance "--capture-$page"
    sleep 3
    xcrun simctl io "$UDID" screenshot "build/screenshots/$page-$theme.png"
  done
  for page in career career-companies career-observation; do
    xcrun simctl launch --terminate-running-process "$UDID" com.personalassistant.Daylight --capture-tab today "--capture-$page"
    sleep 5
    xcrun simctl io "$UDID" screenshot "build/screenshots/$page-$theme.png"
  done
  xcrun simctl launch --terminate-running-process "$UDID" com.personalassistant.Daylight --capture-tab settings --capture-sms-diagnostics
  sleep 3
  xcrun simctl io "$UDID" screenshot "build/screenshots/sms-diagnostics-$theme.png"
done
