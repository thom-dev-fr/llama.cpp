import XCTest

/// The demo's journeys through its interface, with the catalog model already
/// installed in the app (download it once from the library). Slow on the
/// simulator's CPU: run them on purpose, with the `LlamaFMDemoUITests` scheme.
@MainActor
final class QwenScenarioUITests: XCTestCase {
    private let app = XCUIApplication()
    private let answerTimeout: TimeInterval = 600

    /// Launches the app; skips when no model is installed.
    private func start() throws {
        continueAfterFailure = false
        app.launch()
        guard composer.waitForExistence(timeout: 20) else {
            throw XCTSkip("no model installed in the app: download the catalog model from the library first")
        }
    }

    private var composer: XCUIElement { app.descendants(matching: .any)["composer.text"] }
    private var send: XCUIElement { app.buttons["composer.send"] }
    private var stop: XCUIElement { app.buttons["composer.stop"] }

    private func ask(_ text: String) {
        composer.tap()
        composer.typeText(text)
        send.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the request did not start")
    }

    private func waitUntilIdle() {
        XCTAssertTrue(send.waitForExistence(timeout: answerTimeout), "the answer did not end")
    }

    private func choose(_ mode: String) {
        app.buttons["composer.mode"].tap()
        app.buttons[mode].tap()
    }

    /// Tools: both local tools are called and their outputs shown, then the answer.
    func testToolLoop() throws {
        try start()
        choose("Chat")
        ask("How much are 3 pens and a mug in total?")
        waitUntilIdle()
        // The model samples (no greedy setting here): check the loop, log the content.
        let calls = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'lookup_product(' OR label BEGINSWITH 'calculate('"))
        let outputs = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'lookup_product →' OR label BEGINSWITH 'calculate →'"))
        let answer = app.staticTexts.matching(identifier: "turn.answer").firstMatch
        print("demo ui tools: calls \(calls.allElementsBoundByIndex.map(\.label)) outputs \(outputs.allElementsBoundByIndex.map(\.label)) answer '\(answer.label)'")
        XCTAssertGreaterThanOrEqual(calls.count, 1)
        XCTAssertGreaterThanOrEqual(outputs.count, 1)
        XCTAssertFalse(answer.label.isEmpty)
        XCTAssertTrue(app.staticTexts["Last measure"].exists)
    }

    /// Structured output: a `@Generable` city guide fills its fields.
    func testCityGuide() throws {
        try start()
        choose("City guide")
        ask("Lyon")
        waitUntilIdle()
        let card = app.descendants(matching: .any)["turn.cityGuide"]
        XCTAssertTrue(card.exists)
        print("demo ui city guide: \(app.staticTexts.allElementsBoundByIndex.map(\.label).suffix(8))")
        XCTAssertTrue(app.staticTexts["Lyon"].exists)
        XCTAssertTrue(app.staticTexts["France"].exists)
    }

    /// Stop keeps the fragments as interrupted, Retry submits again; on iOS,
    /// moving to the background interrupts the retried request.
    func testStopRetryAndBackground() throws {
        try start()
        choose("Chat")
        ask("Count from 1 to 400, separated by commas.")
        let answer = app.staticTexts.matching(identifier: "turn.answer").firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: answerTimeout), "no fragment before stopping")
        stop.tap()
        XCTAssertTrue(app.staticTexts["Stopped"].waitForExistence(timeout: 10))
        let retry = app.buttons["turn.retry"]
        XCTAssertTrue(retry.exists)

        retry.tap()
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(identifier: "turn.answer").element(boundBy: 1)
            .waitForExistence(timeout: answerTimeout))
        #if os(iOS)
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        XCTAssertTrue(app.staticTexts["Interrupted: the app moved to the background"].waitForExistence(timeout: 10))
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["turn.retry"].exists)
        #else
        stop.tap()                                            // macOS never interrupts on its own
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        #endif
    }
}
