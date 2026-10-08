#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

# The tests use an isolated Debug-only simulator store, never the normal ledger.
# Keep every result, including failures, so an installation is never gated by
# a successful build that silently ran zero interaction tests.
RESULT="build/Daylight-UI-Tests.xcresult"
if [ -e "$RESULT" ]; then
  printf 'UI result already exists: %s. Use a clean CI checkout or archive it before rerunning.\n' "$RESULT" >&2
  exit 2
fi
if ! compgen -G 'ios/DaylightUITests/*.swift' >/dev/null; then
  printf 'No native UI test source files were found.\n' >&2
  exit 2
fi

finish() {
  status=$?
  trap - EXIT
  set +e
  if [ -d "$RESULT" ]; then
    xcrun xcresulttool get test-results summary --path "$RESULT" > build/ui-test-summary.json 2> build/ui-test-summary.log
    xcrun xcresulttool get test-results tests --path "$RESULT" > build/ui-test-cases.json 2> build/ui-test-cases.log
    xcrun xcresulttool export attachments --path "$RESULT" --output-path build/ui-test-attachments > build/ui-test-attachments.log 2>&1
    ditto -c -k --keepParent "$RESULT" build/Daylight-UI-Tests.xcresult.zip
  fi
  python3 - "$status" <<'PY'
import json, pathlib, re, sys
status = int(sys.argv[1])
expected_methods = []
for source in sorted(pathlib.Path('ios/DaylightUITests').glob('*.swift')):
    methods = re.findall(r'^\s*func\s+(test[A-Za-z0-9_]+)\s*\(\s*\)', source.read_text(encoding='utf-8'), flags=re.M)
    expected_methods.extend({'source': source.as_posix(), 'method': method} for method in methods)
expected = len(expected_methods)
pathlib.Path('build/ui-test-expected.json').write_text(json.dumps({'expectedTestCount': expected, 'methods': expected_methods}, indent=2) + '\n')
summary = {}
try:
    summary = json.loads(pathlib.Path('build/ui-test-summary.json').read_text())
except (OSError, ValueError):
    pass
def count(key):
    value = summary.get(key)
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None
total, passed, failed, skipped = (count(k) for k in ('totalTestCount', 'passedTests', 'failedTests', 'skippedTests'))
valid = status == 0 and summary.get('result') == 'Passed' and expected > 0 and total == expected and passed == expected and failed == 0 and skipped == 0
evidence = {
    'automation': 'XCUITest',
    'status': 'passed' if valid else 'failed',
    'xcodebuildExitCode': status,
    'expectedTestCount': expected,
    'expectedMethods': expected_methods,
    'totalTestCount': total,
    'passedTests': passed,
    'failedTests': failed,
    'skippedTests': skipped,
    'testResult': summary.get('result'),
    'environmentDescription': summary.get('environmentDescription'),
    'resultBundle': 'Daylight-UI-Tests.xcresult.zip',
    'data': 'synthetic, isolated simulator data',
    'physicalDeviceAutomationVerified': False,
}
pathlib.Path('build/ui-test-gate.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + '\n')
message = f"Native UI interaction tests: **{'passed' if valid else 'failed'}**. "
message += f"Expected from source: {expected}, total: {total}, passed: {passed}, failed: {failed}, skipped: {skipped}.\n\n"
message += 'Synthetic simulator data; real incoming SMS, signing and device permissions require separate iPhone acceptance.\n'
pathlib.Path('build/ui-test-summary.md').write_text(message)
print(message)
sys.exit(0 if valid else 1)
PY
  gate_status=$?
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f build/ui-test-summary.md ]; then
    cat build/ui-test-summary.md >> "$GITHUB_STEP_SUMMARY"
  fi
  if [ "$status" -ne 0 ]; then
    tail -n 100 build/ui-tests.log 2>/dev/null
    exit "$status"
  fi
  exit "$gate_status"
}
trap finish EXIT

# Select one concrete device, ordered by runtime version and device name rather
# than relying on the particular iPhone names that a hosted runner ships.
xcrun simctl list devices available --json > build/ui-test-simulators.json
UDID="$(python3 - <<'PY'
import json, pathlib, re
inventory = json.loads(pathlib.Path('build/ui-test-simulators.json').read_text())
candidates = []
for runtime, devices in inventory['devices'].items():
    match = re.search(r'\.iOS-(\d+)-(\d+)(?:-(\d+))?$', runtime)
    if not match:
        continue
    version = tuple(-int(x or 0) for x in match.groups())
    for device in devices:
        if device.get('isAvailable', True) and device['name'].startswith('iPhone'):
            candidates.append((version, device['name'], device['udid']))
if not candidates:
    raise SystemExit('No available iPhone simulator/runtime exists on this Mac runner.')
chosen = sorted(candidates)[0]
pathlib.Path('build/ui-test-device.json').write_text(json.dumps({'udid': chosen[2], 'name': chosen[1], 'runtimeVersion': '.'.join(str(-x) for x in chosen[0])}, indent=2) + '\n')
print(chosen[2])
PY
)"
STATE="$(python3 - "$UDID" <<'PY'
import json, pathlib, sys
inventory = json.loads(pathlib.Path('build/ui-test-simulators.json').read_text())
print(next(d['state'] for devices in inventory['devices'].values() for d in devices if d['udid'] == sys.argv[1]))
PY
)"
if [ "$STATE" != Booted ]; then xcrun simctl boot "$UDID"; fi
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100
xcrun simctl ui "$UDID" appearance light
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool NO

# Full save/edit/delete/relaunch scenarios need several launches and scrolls.
# Default each case to 3 minutes; the six-entry ledger scenario opts into 5.
# Enforce a total 30 minute xcodebuild deadline.
# No automatic retries: a failing interaction remains a failing delivery gate.
python3 - "$UDID" <<'PY' > build/ui-tests.log 2>&1
import os, signal, subprocess, sys
command = [
    'xcodebuild', 'test',
    '-project', 'ios/Daylight.xcodeproj', '-scheme', 'Daylight',
    '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,id=' + sys.argv[1],
    '-destination-timeout', '60', '-derivedDataPath', 'build/simulator',
    '-resultBundlePath', 'build/Daylight-UI-Tests.xcresult',
    '-only-testing:DaylightUITests', '-parallel-testing-enabled', 'NO',
    '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '180',
    '-maximum-test-execution-time-allowance', '300',
    'CODE_SIGNING_ALLOWED=NO',
]
print('Running native UI interaction tests on ' + sys.argv[1], flush=True)
process = subprocess.Popen(command, start_new_session=True)
try:
    code = process.wait(timeout=1800)
except subprocess.TimeoutExpired:
    print('UI test command exceeded its 1800 second deadline.', flush=True)
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
    code = 124
sys.exit(code)
PY
