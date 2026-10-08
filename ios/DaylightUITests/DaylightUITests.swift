import XCTest

/// These tests drive the installed simulator app through its accessibility tree.
/// Each test receives a new, simulator-only repository; relaunches keep that same
/// repository to verify persistence instead of injecting already-saved records.
final class DaylightUITests: XCTestCase {
    private var app: XCUIApplication!
    private var runID = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        runID = UUID().uuidString
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-run", runID]
    }

    override func tearDownWithError() throws {
        if (testRun?.failureCount ?? 0) > 0 {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Failure screen"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            if let app {
                let tree = XCTAttachment(string: String(app.debugDescription.prefix(30_000)))
                tree.name = "Failure accessibility tree (isolated synthetic data)"
                tree.lifetime = .keepAlways
                add(tree)
            }
        }
        app?.terminate()
        app = nil
    }

    func testFiveTabsAndCancelDoNotCreateRecords() {
        launch()
        assertText("today-record-count", equals: "0 笔")
        for title in ["账本", "计划", "运动", "设置", "今天"] {
            tab(title)
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        }
        openEntry("money")
        replaceText("entry-title", with: "UI 已取消记录")
        replaceText("entry-amount", with: "1.23")
        tap(element("entry-cancel"))
        assertText("today-record-count", equals: "0 笔")
        relaunch()
        assertText("today-record-count", equals: "0 笔")
    }

    func testExpenseCreateEditDeleteSurvivesRelaunch() {
        launch()
        createExpense(title: "UI 茶饮", amount: "1.23")
        assertText("today-net-expense", equals: "¥ 1.23")
        assertText("today-record-count", equals: "1 笔")
        relaunch()
        assertText("today-net-expense", equals: "¥ 1.23")
        assertText("today-record-count", equals: "1 笔")

        tab("账本")
        tap(element("finance-record-UI 茶饮"), scroll: true)
        XCTAssertTrue(element("entry-save").waitForExistence(timeout: 5))
        replaceText("entry-amount", with: "2.50")
        tap(element("entry-save"))
        tab("今天")
        assertText("today-net-expense", equals: "¥ 2.50")
        assertText("today-record-count", equals: "1 笔")

        tab("账本")
        tap(element("finance-record-UI 茶饮"), scroll: true)
        XCTAssertTrue(element("entry-save").waitForExistence(timeout: 5))
        tap(element("entry-delete"), scroll: true)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        tap(alert.buttons["删除"])
        tab("今天")
        assertText("today-net-expense", equals: "¥ 0.00")
        assertText("today-record-count", equals: "0 笔")
        relaunch()
        assertText("today-record-count", equals: "0 笔")
    }

    func testZeroAmountIsRejectedWithoutSaving() {
        launch()
        openEntry("money")
        replaceText("entry-title", with: "UI 无效金额")
        replaceText("entry-amount", with: "0")
        tap(element("entry-save"))
        let error = element("entry-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(error.label.isEmpty)
        XCTAssertTrue(element("entry-save").exists, "Validation must keep the editor open.")
        tap(element("entry-cancel"))
        assertText("today-record-count", equals: "0 笔")
        relaunch()
        assertText("today-record-count", equals: "0 笔")
    }

    func testDailyLedgerPreviewExpandsAndCollapsesWithoutChangingTotals() {
        executionTimeAllowance = 300
        launch()
        for index in 1...6 { createExpense(title: "UI 明细 \(index)", amount: "1.00") }
        assertText("today-record-count", equals: "6 笔")
        assertText("today-net-expense", equals: "¥ 6.00")
        tab("账本")
        let period = app.segmentedControls["finance-period"]
        XCTAssertTrue(period.waitForExistence(timeout:5))
        XCTAssertTrue(period.buttons["日"].isSelected)
        XCTAssertFalse(app.staticTexts["净支出趋势"].exists)
        assertText("finance-record-count", equals:"6 笔", scroll:true)
        XCTAssertFalse(element("finance-record-UI 明细 1").exists)
        tap(element("finance-toggle-details"), scroll:true)
        XCTAssertTrue(element("finance-record-UI 明细 1").exists)
        tap(element("finance-toggle-details"), scroll:true)
        XCTAssertFalse(element("finance-record-UI 明细 1").exists)
        tab("今天")
        assertText("today-record-count", equals:"6 笔")
        assertText("today-net-expense", equals:"¥ 6.00")
        relaunch()
        assertText("today-record-count", equals:"6 笔")
    }

    func testSpokenScheduleLocalSaveAndDuplicateSurviveRelaunch() {
        launch()
        tab("计划")
        tap(element("plan-spoken-schedule"), scroll: true)
        let sync = app.switches["schedule-sync-calendar"]
        toggle(sync)
        XCTAssertEqual(sync.value as? String, "0")
        replaceText("schedule-input", with: "今天九点UI会议；今天UI健身")
        tap(element("schedule-record"), scroll: true)
        assertText("schedule-added-count", equals: "新增 2 项安排", scroll: true)
        tap(element("schedule-record"), scroll: true)
        assertText("schedule-added-count", equals: "新增 0 项安排", scroll: true)
        tap(element("schedule-close"))
        scrollTo(element("plan-event-UI会议"))
        XCTAssertTrue(element("plan-event-UI会议").exists)
        relaunch()
        tab("计划")
        scrollTo(element("plan-event-UI会议"))
        XCTAssertTrue(element("plan-event-UI会议").exists)
        XCTAssertTrue(element("plan-event-UI健身").exists)
    }

    func testNotificationPromotionRejectedAndSmallPaymentPersists() {
        launch()
        tab("账本")
        tap(element("finance-import-notification"), scroll: true)
        replaceText("bank-notification-title", with: "支付好礼")
        replaceText("bank-notification-input", with: "绑卡支付享优惠，消费立减5元。")
        tap(element("bank-notification-parse"), scroll: true)
        XCTAssertTrue(element("bank-import-error").waitForExistence(timeout: 5))
        XCTAssertFalse(bankSwitch(0).exists)
        tap(element("bank-input-clear"), scroll: true)
        replaceText("bank-notification-title", with: "动账通知")
        let body = syntheticSMS(amount: "5", balance: "95.00")
            .replacingOccurrences(of: "，余额95.00元。【工商银行】", with: "。请点击查看详情。")
        replaceText("bank-notification-input", with: body)
        tap(element("bank-notification-parse"), scroll: true)
        XCTAssertTrue(bankSwitch(0).waitForExistence(timeout: 5))
        XCTAssertEqual(bankSwitch(0).value as? String, "1")
        tap(element("bank-import-confirm"), scroll: true)
        acknowledgeSave(count: 1)
        tab("今天")
        assertText("today-net-expense", equals: "¥ 5.00")
        assertText("today-record-count", equals: "1 笔")
        relaunch()
        assertText("today-record-count", equals: "1 笔")
        tab("账本")
        tap(element("finance-import-notification"), scroll: true)
        replaceText("bank-notification-input", with: body)
        tap(element("bank-notification-parse"), scroll: true)
        XCTAssertTrue(bankSwitch(0).waitForExistence(timeout: 5))
        XCTAssertFalse(bankSwitch(0).isEnabled)
        scrollTo(element("bank-import-confirm"))
        XCTAssertFalse(element("bank-import-confirm").isEnabled)
    }

    func testSmallSMSPreviewSaveBalanceAndDuplicate() {
        launch()
        let body = syntheticSMS(amount: "8.00", balance: "361.93")
        openSMS(body)
        let first = bankSwitch(0)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.value as? String, "1")
        tap(element("bank-import-confirm"), scroll: true)
        acknowledgeSave(count: 1)
        assertText("finance-balance-value", equals: "¥ 361.93")
        tab("今天")
        assertText("today-net-expense", equals: "¥ 8.00")
        assertText("today-record-count", equals: "1 笔")

        relaunch()
        assertText("today-record-count", equals: "1 笔")
        openSMS(body)
        let duplicate = bankSwitch(0)
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        XCTAssertFalse(duplicate.isEnabled, "An exact receipt must not be selectable twice.")
        XCTAssertEqual(duplicate.value as? String, "0")
        scrollTo(element("bank-import-confirm"))
        XCTAssertFalse(element("bank-import-confirm").isEnabled)
        tap(element("bank-import-close"))
        tab("今天")
        assertText("today-net-expense", equals: "¥ 8.00")
        assertText("today-record-count", equals: "1 笔")
    }

    func testScreenshotReviewSelectionEditingAndPersistentDuplicate() {
        // This neutral text fixture enters immediately after OCR. The separate
        // native Vision tests exercise actual image recognition; this test drives
        // the same parser, review editor, save path and repository as normal UI.
        app.launchArguments.append("--ui-test-bank-fixture")
        launch()
        tab("账本")
        tap(element("finance-import-screenshots"), scroll: true)
        let second = bankSwitch(1)
        scrollTo(second)
        XCTAssertEqual(second.value as? String, "1")
        toggle(second)
        XCTAssertEqual(second.value as? String, "0")

        scrollTo(element("bank-row-edit-0"), direction: .down)
        tap(element("bank-row-edit-0"))
        replaceText("bank-edit-title", with: "UI 截图核对")
        replaceText("bank-edit-amount", with: "8.50")
        tap(element("bank-edit-save"))
        XCTAssertTrue(bankSwitch(0).waitForExistence(timeout: 5))
        XCTAssertTrue(bankSwitch(0).label.contains("UI 截图核对"))
        tap(element("bank-import-confirm"), scroll: true)
        acknowledgeSave(count: 1)
        assertText("finance-balance-value", equals: "¥ 361.93")

        relaunch()
        tab("账本")
        assertText("finance-balance-value", equals: "¥ 361.93")
        tap(element("finance-import-screenshots"), scroll: true)
        let duplicate = bankSwitch(0)
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        XCTAssertFalse(duplicate.isEnabled)
        XCTAssertEqual(duplicate.value as? String, "0")
        scrollTo(bankSwitch(1))
        XCTAssertTrue(bankSwitch(1).isEnabled)
        XCTAssertEqual(bankSwitch(1).value as? String, "1")
        tap(element("bank-import-close"))
    }

    func testTaskCompletionPersistsAndCanBeUndone() {
        launch()
        openEntry("task")
        replaceText("entry-title", with: "UI 规划明天")
        replaceText("entry-notes", with: "先确定出发时间")
        tap(element("entry-save"))
        let completion = element("task-complete-UI 规划明天")
        scrollTo(completion)
        XCTAssertEqual(completion.value as? String, "pending")
        tap(completion)
        assertValue(completion, equals: "completed")

        relaunch()
        scrollTo(completion)
        assertValue(completion, equals: "completed")
        tap(completion)
        assertValue(completion, equals: "pending")
        relaunch()
        scrollTo(completion)
        assertValue(completion, equals: "pending")
    }

    func testWeightAndWorkoutMetricsPersist() {
        launch()
        openEntry("weight")
        replaceText("entry-amount", with: "72.5")
        tap(element("entry-save"))
        assertText("today-latest-weight", equals: "72.5 kg", scroll: true)

        openEntry("exercise")
        replaceText("entry-amount", with: "30")
        replaceText("entry-notes", with: "深蹲 3 组")
        tap(element("entry-save"))
        assertText("today-workout-minutes", equals: "30 分钟", scroll: true)
        relaunch()
        assertText("today-latest-weight", equals: "72.5 kg", scroll: true)
        assertText("today-workout-minutes", equals: "30 分钟", scroll: true)
    }

    func testManualBalanceChangesOnlyForMarkedBankExpense() {
        launch()
        tab("账本")
        tap(element("finance-set-balance"))
        replaceText("balance-amount", with: "100.00")
        tap(element("balance-save"))
        assertText("finance-balance-value", equals: "¥ 100.00")
        tab("今天")
        createExpense(title: "UI 现金消费", amount: "1.00")
        tab("账本")
        assertText("finance-balance-value", equals: "¥ 100.00")

        openEntry("money")
        replaceText("entry-title", with: "UI 银行卡消费")
        replaceText("entry-amount", with: "12.34")
        let affectsBalance = app.switches["entry-affects-bank"]
        scrollTo(affectsBalance)
        XCTAssertEqual(affectsBalance.value as? String, "0")
        toggle(affectsBalance)
        XCTAssertEqual(affectsBalance.value as? String, "1")
        tap(element("entry-save"))
        assertText("finance-balance-value", equals: "¥ 87.66")
        relaunch()
        tab("账本")
        assertText("finance-balance-value", equals: "¥ 87.66")
    }

    private enum ScrollDirection { case up, down }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["今天"].waitForExistence(timeout: 12))
    }

    private func relaunch() {
        app.terminate()
        launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testFinanceSearchKeyboardDismissesAndRecordOpens() {
        launch()
        createExpense(title: "UI keyboard", amount: "8.00")
        tab("账本")
        replaceText("finance-search", with: "keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        tap(element("finance-dismiss-keyboard"))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        assertValue(element("finance-search"), equals: "keyboard")
        tap(element("finance-record-UI keyboard"), scroll: true)
        XCTAssertTrue(element("entry-save").waitForExistence(timeout: 5))
        tap(element("entry-cancel"))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
    }

    func testCareerDirectoryDetailsPreferencesAndReport() {
        launch()
        tap(element("open-career"))
        XCTAssertTrue(app.navigationBars["求职与具身"].waitForExistence(timeout: 5))
        tap(element("career-preferences"))
        XCTAssertTrue(app.navigationBars["求职偏好"].waitForExistence(timeout: 5))
        tap(element("career-preferences-done"))
        tap(app.segmentedControls["career-section"].buttons["公司"])
        replaceText("career-company-search", with: "Torch")
        // Search by the Chinese brand also verifies CJK company content.
        replaceText("career-company-search", with: "炬坤")
        tap(element("career-company-torch"), scroll: true)
        XCTAssertTrue(app.navigationBars["公司介绍"].waitForExistence(timeout: 5))
        tap(app.navigationBars["公司介绍"].buttons["完成"])
        tap(app.segmentedControls["career-section"].buttons["具身观察"])
        tap(app.segmentedControls["career-report-period"].buttons["日报"])
        XCTAssertTrue(element("career-article-lerobot06").exists)
        XCTAssertFalse(element("career-article-lerobot05").exists)
        tap(app.segmentedControls["career-report-period"].buttons["周报"])
        scrollTo(element("career-article-lerobot05"))
        XCTAssertTrue(element("career-article-lerobot05").exists)
    }

    func testCareerProfileEditCancelSaveAndRelaunch() {
        launch()
        tap(element("open-career"))
        tap(element("career-preferences"))
        replaceText("career-profile-education", with: "UI 测试硕士")
        tap(element("career-profile-cancel"))
        tap(element("career-preferences"))
        XCTAssertNotEqual(element("career-profile-education").value as? String, "UI 测试硕士")
        replaceText("career-profile-education", with: "UI 测试硕士")
        tap(element("career-preferences-done"))
        relaunch()
        tap(element("open-career"))
        tap(element("career-preferences"))
        assertValue(element("career-profile-education"), equals: "UI 测试硕士")
    }

    func testCareerMultipleJobsBookmarkPersistenceAndRefreshFailureKeepsCache() {
        app.launchArguments.append("--ui-test-career-failure")
        launch()
        tap(element("open-career"))
        XCTAssertTrue(app.navigationBars["求职与具身"].waitForExistence(timeout: 5))
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "career-job-job-"))
        XCTAssertGreaterThan(cards.count, 1, "Multiple relevant jobs must be available independently of the company directory.")
        let first = cards.firstMatch
        let identifier = first.identifier
        tap(first, scroll: true)
        let bookmark = app.switches["career-save-job"]
        scrollTo(bookmark)
        XCTAssertEqual(bookmark.value as? String, "0")
        toggle(bookmark)
        assertValue(bookmark, equals: "1")
        tap(element("career-detail-done"))

        relaunch()
        tap(element("open-career"))
        tap(element(identifier), scroll: true)
        scrollTo(app.switches["career-save-job"])
        assertValue(app.switches["career-save-job"], equals: "1")
        tap(element("career-detail-done"))
        tap(element("career-refresh"), scroll: true)
        let error = element("career-service-error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(error.label.isEmpty)
        XCTAssertTrue(element(identifier).exists, "An offline refresh must not remove previous jobs.")
        tap(element("career-service-settings"), scroll: true)
        XCTAssertTrue(element("career-service-url").waitForExistence(timeout: 5))
        tap(element("career-service-done"))
        tap(element(identifier), scroll: true)
        scrollTo(app.switches["career-save-job"])
        assertValue(app.switches["career-save-job"], equals: "1")
    }

    private func bankSwitch(_ index: Int) -> XCUIElement {
        app.switches["bank-row-select-\(index)"]
    }

    private func tab(_ title: String) {
        tap(app.tabBars.buttons[title])
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func openEntry(_ kind: String) {
        tap(element("add-record"))
        tap(element("menu-action-\(kind)"))
        XCTAssertTrue(element("entry-save").waitForExistence(timeout: 5))
    }

    private func createExpense(title: String, amount: String) {
        openEntry("money")
        replaceText("entry-title", with: title)
        replaceText("entry-amount", with: amount)
        tap(element("entry-save"))
        XCTAssertTrue(element("entry-save").waitForNonExistence(timeout: 5))
    }

    private func openSMS(_ body: String) {
        tab("账本")
        tap(element("finance-import-sms"), scroll: true)
        replaceText("bank-sms-input", with: body)
        tap(element("bank-sms-parse"), scroll: true)
        XCTAssertTrue(bankSwitch(0).waitForExistence(timeout: 5))
    }

    private func acknowledgeSave(count: Int) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8))
        XCTAssertTrue(alert.staticTexts.allElementsBoundByIndex.contains { $0.label.contains("已保存 \(count) 笔") })
        tap(alert.buttons["知道了"])
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
    }

    private func syntheticSMS(amount: String, balance: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
        formatter.dateFormat = "yyyy年M月d日HH:mm"
        return "尾号9999卡\(formatter.string(from: Date()))支出(消费财付通-UI示例商店)\(amount)元，余额\(balance)元。【工商银行】"
    }

    private func replaceText(_ identifier: String, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier)
        scrollTo(field, file: file, line: line)
        tap(field, file: file, line: line)
        if let old = field.value as? String, !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
    }

    private func tap(_ target: XCUIElement, scroll: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        if scroll { scrollTo(target, file: file, line: line) }
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Missing element: \(target)", file: file, line: line)
        XCTAssertTrue(target.isHittable, "Element is not hittable: \(target)", file: file, line: line)
        target.tap()
    }

    private func toggle(_ target: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        scrollTo(target, file: file, line: line)
        XCTAssertTrue(target.isEnabled, file: file, line: line)
        // SwiftUI exposes the whole label row as the accessibility Switch.
        // Tap the actual trailing switch thumb rather than empty label space.
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    private func scrollTo(_ target: XCUIElement, direction: ScrollDirection = .up, file: StaticString = #filePath, line: UInt = #line) {
        if target.exists && target.isHittable { return }
        for _ in 0..<10 {
            // The coordinate gesture covers both SwiftUI ScrollView and List/Form.
            // It stops well above the tab bar and below the navigation toolbar.
            let frame = app.frame
            let keyboard = app.keyboards.firstMatch
            let lower = keyboard.exists
                ? min(0.75, max(0.40, (keyboard.frame.minY - frame.minY - 18) / frame.height))
                : 0.75
            let upper = min(0.30, lower - 0.15)
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: direction == .up ? lower : upper))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: direction == .up ? upper : lower))
            start.press(forDuration: 0.05, thenDragTo: end)
            if target.exists && target.isHittable { return }
        }
        XCTFail("Element could not be reached within 10 scrolls: \(target)", file: file, line: line)
    }

    private func assertText(_ identifier: String, equals expected: String, scroll: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        if scroll { scrollTo(target, file: file, line: line) }
        XCTAssertTrue(target.waitForExistence(timeout: 5), file: file, line: line)
        let correct = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: correct, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected \(expected), got \(target.label)", file: file, line: line)
    }

    private func assertValue(_ target: XCUIElement, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let correct = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: correct, object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected value \(expected), got \(String(describing: target.value))", file: file, line: line)
    }
}
