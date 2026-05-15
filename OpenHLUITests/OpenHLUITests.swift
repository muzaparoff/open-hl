// SPDX-License-Identifier: MIT

import XCTest

// MARK: - Phase 0 regression

final class OpenHLUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPlaceholderLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["open-hl"].exists)
    }
}

// MARK: - Phase 1 critical paths

// NOTE (qa-automation): The entry → loaded happy-path UI test below requires
// the app to support a launch-environment injection point that swaps in a
// deterministic in-memory `HyperliquidClient` returning a fixture.
//
// The injection contract (to be implemented by ios-developer in OpenHLApp.swift):
//
//   1. Read `ProcessInfo.processInfo.environment["OPENHL_UI_TEST_STUB"]` at
//      app startup (in the `init()` of `OpenHLApp`).
//   2. When the value is `"clearinghouseState_single_long"`, construct an
//      `InMemoryHyperliquidClient` seeded with that fixture's data and pass
//      it to the composition root instead of `URLSessionHyperliquidClient`.
//   3. Also seed `UserDefaultsAddressStore` (or `InMemoryAddressStore`) with
//      the test address "0xabcdef1234567890abcdef1234567890abcdef12" so
//      the app skips the address-entry screen and lands directly on the
//      positions view.
//
// When the injection point lands, remove the `XCTSkip` call and uncomment
// the assertions marked TODO below.

final class AddressEntryUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // -------------------------------------------------------------------------
    // Happy path: paste address → positions view is shown
    // -------------------------------------------------------------------------

    func testEntryToLoadedHappyPath() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OPENHL_UI_TEST_STUB"] = "clearinghouseState_single_long"
        app.launch()

        // The stub pre-seeds the address, so the positions screen should appear.
        let accountValueLabel = app.staticTexts["Account value"]
        XCTAssertTrue(accountValueLabel.waitForExistence(timeout: 5))

        // Verify at least one position row is visible (stub returns BTC long).
        let btcRow = app.staticTexts["BTC"]
        XCTAssertTrue(btcRow.waitForExistence(timeout: 3))
    }

    // -------------------------------------------------------------------------
    // Address entry screen: valid address advances, invalid shows inline error
    // -------------------------------------------------------------------------

    func testAddressEntryValidationInlineError() throws {
        throw XCTSkip(
            """
            TODO (qa-automation): Requires ios-developer to implement the \
            AddressEntry screen with an accessibility-identified text field \
            ("Address input") and error label ("Address error"). \
            Remove this XCTSkip when the screen exists.
            """
        )

        // let app = XCUIApplication()
        // app.launch()
        //
        // let field = app.textFields["Address input"]
        // field.tap()
        // field.typeText("not-a-valid-address")
        //
        // // Dismiss keyboard / trigger validation
        // app.buttons["Continue"].tap()
        //
        // let errorLabel = app.staticTexts["Address error"]
        // XCTAssertTrue(errorLabel.waitForExistence(timeout: 2))
    }

    // -------------------------------------------------------------------------
    // Pull-to-refresh: refresh spinner appears and positions update
    // -------------------------------------------------------------------------

    func testPullToRefresh() throws {
        throw XCTSkip(
            """
            TODO (qa-automation): Requires OPENHL_UI_TEST_STUB injection point \
            and PositionsView to exist. Remove XCTSkip when both land.
            """
        )

        // let app = XCUIApplication()
        // app.launchEnvironment["OPENHL_UI_TEST_STUB"] = "clearinghouseState_single_long"
        // app.launch()
        //
        // let list = app.scrollViews.firstMatch
        // list.swipeDown()
        // // After refresh the same positions should still be visible.
        // XCTAssertTrue(app.staticTexts["BTC"].waitForExistence(timeout: 5))
    }

    // -------------------------------------------------------------------------
    // Error state: offline error renders actionable error view
    // -------------------------------------------------------------------------

    func testOfflineErrorStateIsRendered() throws {
        throw XCTSkip(
            """
            TODO (qa-automation): Requires OPENHL_UI_TEST_STUB injection with \
            an "offline" error mode. Define a second stub mode in OpenHLApp.swift \
            (e.g. OPENHL_UI_TEST_STUB=error_offline) and remove this XCTSkip.
            """
        )
    }
}
