import XCTest

/// Taps through the real app on an iPhone simulator, like a person would.
/// Each test starts the app fresh with its data in memory only (-ui-testing), in Slovenian
/// number format (12,50 €) so the checks match what Tosve and Milica will see.
final class BudgetUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @discardableResult
    func launch(_ extra: [String] = []) -> XCUIApplication {
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-fake-receipt", "-AppleLocale", "sl_SI", "-AppleLanguages", "(en)"] + extra
        app.launch()
        return app
    }

    // MARK: helpers

    func tab(_ name: String) { app.tabBars.buttons[name].tap() }

    func addEntry(amount: String, category: String, kind: String = "Expense", note: String? = nil) {
        app.buttons["addEntry"].tap()
        if kind != "Expense" { app.segmentedControls.buttons[kind].tap() }
        let field = app.textFields["amountField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(amount)
        pick(category)
        if let note {
            app.textFields["noteField"].tap()
            app.textFields["noteField"].typeText(note)
        }
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["addEntry"].waitForExistence(timeout: 5), "editor closed")
    }

    func pick(_ category: String) {
        app.buttons["categoryPicker"].tap()
        let option = app.buttons[category].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "category \(category) offered")
        option.tap()
    }

    func text(_ id: String) -> String { app.staticTexts[id].label }

    func entries() -> XCUIElementQuery { app.descendants(matching: .any).matching(identifier: "entry") }

    func scrollTo(_ element: XCUIElement, in list: XCUIElement? = nil) {
        let l = list ?? app.collectionViews.firstMatch
        var n = 0
        while !element.isHittable && n < 8 { l.swipeUp(); n += 1 }
    }

    // MARK: tests

    func testFreshStartShowsAnEmptyMonth() {
        launch()
        XCTAssertTrue(app.navigationBars["Personal"].exists)
        XCTAssertTrue(text("spentAmount").contains("0"))
        XCTAssertTrue(app.staticTexts["Nothing spent yet this month."].exists)
        XCTAssertTrue(app.staticTexts["No entries yet. Tap + to add one."].exists)
    }

    func testAddAnExpenseAndSeeTheTotals() {
        launch()
        addEntry(amount: "12,50", category: "Groceries", note: "Lidl")
        XCTAssertTrue(text("spentAmount").contains("12,50"), text("spentAmount"))
        XCTAssertEqual(entries().count, 1)
        XCTAssertTrue(entries().firstMatch.label.contains("Groceries"))
        XCTAssertTrue(entries().firstMatch.label.contains("Lidl"))
        XCTAssertTrue(app.buttons["category.Groceries"].exists, "category shows up under spending")

        addEntry(amount: "2000", category: "Salary", kind: "Income")
        let income = app.buttons["addIncome"].value as? String ?? ""
        XCTAssertTrue(income.contains("2.000"), income)
        XCTAssertTrue(text("spentAmount").contains("12,50"), "income does not count as spending")
    }

    func testTappingIncomeOrSpentOpensTheRightAddScreen() {
        launch()
        app.buttons["addIncome"].tap()
        XCTAssertTrue(app.textFields["amountField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Income"].isSelected, "income is preselected")
        app.textFields["amountField"].typeText("1500")
        pick("Salary")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["addIncome"].waitForExistence(timeout: 5), "editor closed")
        XCTAssertTrue((app.buttons["addIncome"].value as? String ?? "").contains("1.500"))

        app.buttons["addExpense"].tap()
        XCTAssertTrue(app.textFields["amountField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Expense"].isSelected, "expense is preselected")
        app.textFields["amountField"].typeText("9,99")
        pick("Groceries")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(app.buttons["addExpense"].waitForExistence(timeout: 5))
        XCTAssertTrue(text("spentAmount").contains("9,99"))
        XCTAssertEqual(entries().count, 2)
        let balance = app.descendants(matching: .any)["balance"].label
        XCTAssertTrue(balance.contains("+") && balance.contains("1.490,01"), "income minus spent: \(balance)")
    }

    func testBalanceTurnsNegativeWhenSpendingMoreThanIncome() {
        launch()
        addEntry(amount: "100", category: "Salary", kind: "Income")
        addEntry(amount: "150", category: "Groceries")
        let balance = app.descendants(matching: .any)["balance"].label
        XCTAssertTrue(balance.contains("−") && balance.contains("50"), balance)
    }

    func testCannotSaveWithoutAmountOrCategory() {
        launch()
        app.buttons["addEntry"].tap()
        app.buttons["saveEntry"].tap()
        XCTAssertEqual(text("formProblem"), "Enter an amount bigger than 0.")
        app.textFields["amountField"].typeText("5")
        app.buttons["saveEntry"].tap()
        XCTAssertEqual(text("formProblem"), "Pick a category.")
        app.buttons["Cancel"].tap()
        XCTAssertEqual(entries().count, 0, "nothing was saved")
    }

    func testEditAndDeleteAnEntry() {
        launch()
        addEntry(amount: "10", category: "Gas")
        entries().firstMatch.tap()
        let field = app.textFields["amountField"]
        field.tap()
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        field.typeText("45,90")
        app.buttons["saveEntry"].tap()
        XCTAssertTrue(text("spentAmount").contains("45,90"), text("spentAmount"))

        entries().firstMatch.tap()
        app.buttons["deleteEntry"].tap()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No entries yet. Tap + to add one."].waitForExistence(timeout: 5))
    }

    func testReceiptFillsItemsTotalAndComparesPrices() {
        launch(["-demo-data"]) // demo data has MLEKO ALPSKO 3,5% 1L at 1,19 € earlier this month
        app.buttons["addEntry"].tap()
        app.buttons["scanReceipt"].tap()
        XCTAssertTrue(app.staticTexts["readNote"].waitForExistence(timeout: 5))
        XCTAssertEqual(text("readNote"), "Found 2 items. Check them; tap to fix a name or price.")
        XCTAssertEqual(app.textFields["amountField"].value as? String, "2,78", "total from SKUPAJ")
        XCTAssertEqual(app.textFields.matching(identifier: "itemName").count, 2)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '▲ +8,4%'")).firstMatch.exists
                      || app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH '▲ +8.4%'")).firstMatch.exists,
                      "milk is 8.4% dearer than last time")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Same as'")).firstMatch.exists, "bread unchanged")
        app.buttons["saveEntry"].tap() // Groceries was picked automatically

        tab("Prices")
        XCTAssertTrue(app.staticTexts["MLEKO ALPSKO 3,5% 1L"].waitForExistence(timeout: 5))
        app.staticTexts["MLEKO ALPSKO 3,5% 1L"].tap()
        XCTAssertTrue(app.staticTexts["History"].exists || app.staticTexts["HISTORY"].exists)
    }

    func testPersonalIsSeparateFromHouse() {
        launch()
        addEntry(amount: "30", category: "Barber")
        tab("House")
        XCTAssertTrue(app.navigationBars["House"].waitForExistence(timeout: 3))
        XCTAssertEqual(entries().count, 0, "personal entry is not in the House")
        addEntry(amount: "80", category: "Groceries")
        XCTAssertEqual(entries().count, 1)
        XCTAssertTrue(entries().firstMatch.label.contains("Tosve"), "House entries show who added them")
        tab("Personal")
        XCTAssertEqual(entries().count, 1)
    }

    func testMilicaHasHerOwnPersonalSpace() {
        launch(["-demo-data"])
        tab("Settings")
        app.buttons["whoPicker"].tap()
        app.buttons["Milica"].firstMatch.tap()
        tab("Personal")
        XCTAssertEqual(entries().count, 0, "Tosve's personal entries are not shown to Milica")
        tab("House")
        XCTAssertEqual(entries().count, 1, "the House is shared")
    }

    func testBudgetShowsWhatIsLeft() {
        launch()
        tab("Settings")
        app.buttons["editPersonalCategories"].tap()
        app.buttons["categoryRow.Groceries"].tap()
        let budget = app.textFields["categoryBudget"]
        XCTAssertTrue(budget.waitForExistence(timeout: 5), "tapping a category opens its editor")
        budget.tap()
        budget.typeText("300")
        app.buttons["saveCategory"].tap()
        tab("Personal")
        addEntry(amount: "100", category: "Groceries")
        XCTAssertTrue(text("leftAmount").contains("200"), text("leftAmount"))
        XCTAssertTrue(app.staticTexts["Left this month"].exists)
        addEntry(amount: "250", category: "Groceries")
        XCTAssertTrue(app.staticTexts["Over budget"].exists)
        XCTAssertTrue(text("leftAmount").contains("50"), text("leftAmount"))
    }

    func testHiddenCategoryIsNotOffered() {
        launch()
        tab("Settings")
        app.buttons["editPersonalCategories"].tap()
        app.buttons["categoryRow.Nicotine"].tap()
        XCTAssertTrue(app.buttons["toggleHidden"].waitForExistence(timeout: 5))
        app.buttons["toggleHidden"].tap()
        tab("Personal")
        app.buttons["addEntry"].tap()
        app.buttons["categoryPicker"].tap()
        XCTAssertTrue(app.buttons["Groceries"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Nicotine"].exists)
    }

    func testAddOwnCategory() {
        launch()
        tab("Settings")
        app.buttons["editHouseCategories"].tap()
        let add = app.buttons["addCategory.expense"]
        scrollTo(add)
        add.tap()
        let name = app.textFields["categoryName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Pets")
        app.buttons["saveCategory"].tap()
        XCTAssertTrue(app.buttons["categoryRow.Pets"].waitForExistence(timeout: 3))
        tab("House")
        addEntry(amount: "15", category: "Pets")
        XCTAssertTrue(entries().firstMatch.label.contains("Pets"))
    }

    func testFreeVersionHasFewerCategoriesAndNoCustomOnes() {
        launch(["-free-plan"])
        app.buttons["addEntry"].tap()
        app.buttons["categoryPicker"].tap()
        XCTAssertTrue(app.buttons["Groceries"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Nicotine"].exists, "not in the free version")
        app.buttons["Groceries"].firstMatch.tap()
        app.buttons["Cancel"].tap()
        tab("Settings")
        app.buttons["editPersonalCategories"].tap()
        XCTAssertFalse(app.buttons["addCategory.expense"].exists)
    }

    func testMonthSwitching() {
        launch(["-demo-data"])
        let thisMonth = text("monthTitle")
        XCTAssertGreaterThan(entries().count, 0)
        app.buttons["prevMonth"].tap()
        XCTAssertNotEqual(text("monthTitle"), thisMonth)
        XCTAssertEqual(entries().count, 0, "last month is empty")
        app.buttons["nextMonth"].tap()
        XCTAssertEqual(text("monthTitle"), thisMonth)
        XCTAssertGreaterThan(entries().count, 0)
    }

    func testTappingACategoryFiltersTheEntries() {
        launch(["-demo-data"])
        let all = entries().count
        app.buttons["category.Groceries"].tap()
        XCTAssertTrue(app.buttons["clearFilter"].waitForExistence(timeout: 5))
        XCTAssertEqual(entries().count, 1)
        app.buttons["clearFilter"].tap()
        XCTAssertEqual(entries().count, all)
    }

    func testPartnerBalanceSuggestion() {
        launch()
        addEntry(amount: "2500", category: "Salary", kind: "Income")
        tab("Settings")
        app.buttons["whoPicker"].tap()
        app.buttons["Milica"].firstMatch.tap()
        tab("Personal")
        addEntry(amount: "1500", category: "Salary", kind: "Income")
        tab("Settings")
        let t = app.staticTexts["partnerBalanceText"]
        XCTAssertTrue(t.waitForExistence(timeout: 3))
        XCTAssertTrue(t.label.contains("Tosve sends Milica 500"), t.label)
    }

    func testBackupCanBeSaved() {
        launch(["-demo-data"])
        tab("Settings")
        let b = app.buttons["exportBackup"]
        scrollTo(b)
        b.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5) || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 5))
    }

    func testSharingScreenExplainsWhenNotSetUp() {
        launch()
        tab("Settings")
        let s = app.buttons["sharing"]
        scrollTo(s)
        s.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Sharing is not switched on'")).firstMatch.waitForExistence(timeout: 3))
    }

    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) { launch(["-demo-data"]) }
    }
}
