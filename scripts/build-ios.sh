#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
node scripts/prepare-ios.cjs
xcodebuild -version
xcrun swiftc -parse-as-library ios/Daylight/Models.swift ios/Daylight/BankSMS.swift ios/Daylight/BankNotification.swift ios/Daylight/RecordRepository.swift ios/Daylight/SMSInboxPolicy.swift ios/Daylight/SMSReceptionDiagnostics.swift ios/Daylight/BankScreenshotCore.swift ios/Daylight/BankScreenshotOCR.swift ios/Daylight/PlannerCore.swift ios/Daylight/ScheduleCore.swift ios/Daylight/PlannerNetworking.swift ios/Daylight/PlannerCredentials.swift ios/Daylight/CareerFeed.swift ios/Daylight/CareerNetworking.swift ios/Daylight/CareerModelMatching.swift tests/native/CareerTests.swift tests/native/CareerModelTests.swift tests/native/CoreTests.swift tests/native/SMSDiagnosticsTests.swift tests/native/BankNotificationTests.swift tests/native/ScheduleTests.swift tests/native/BankScreenshotTests.swift tests/native/BankBalanceOrderTests.swift tests/native/BankScreenshotOCRTests.swift tests/native/PlannerTests.swift tests/native/PlannerIntegrationTests.swift tests/native/PlannerNetworkTests.swift -o build/core-tests 2>&1 | tee build/core-compile.log
build/core-tests | tee build/core-tests.log
xcodebuild -project ios/Daylight.xcodeproj -scheme Daylight -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/simulator CODE_SIGNING_ALLOWED=NO build > build/simulator-build.log 2>&1 || { tail -n 100 build/simulator-build.log; exit 1; }
xcodebuild -project ios/Daylight.xcodeproj -scheme Daylight -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO build > build/device-build.log 2>&1 || { tail -n 100 build/device-build.log; exit 1; }
mkdir -p build/Payload
ditto build/device/Build/Products/Release-iphoneos/Daylight.app build/Payload/Daylight.app
ditto -c -k --keepParent build/Payload build/Daylight-0.3.9-unsigned.ipa
shasum -a 256 build/Daylight-0.3.9-unsigned.ipa > build/SHA256.txt
printf 'Unsigned IPA created. Install using your personal signing tool.\n'
