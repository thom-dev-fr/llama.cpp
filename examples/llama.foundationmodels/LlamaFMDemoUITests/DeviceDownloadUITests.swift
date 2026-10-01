import XCTest

/// The catalog download from an empty installation, on a device (P7): the
/// background session keeps transferring while the app is suspended, and
/// after the app is terminated by the test runner (not a force quit from the
/// app switcher) the relaunched app reattaches the transfers and installs the
/// model. Skipped when a model is already installed. Takes the time of a
/// 1.95 GB download: run it on purpose,
///
///   xcodebuild test -scheme LlamaFMDemoUITests -only-testing:LlamaFMDemoUITests/DeviceDownloadUITests ...
@MainActor
final class DeviceDownloadUITests: XCTestCase {
    private let app = XCUIApplication()

    private var composer: XCUIElement { app.descendants(matching: .any)["composer.text"] }
    private var status: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading' OR label BEGINSWITH 'Paused' "
            + "OR label BEGINSWITH 'Interrupted' OR label BEGINSWITH 'Verifying' OR label BEGINSWITH 'Installing' "
            + "OR label BEGINSWITH 'Failed'")).firstMatch
    }
    private var installed: XCUIElement { app.staticTexts["Installed"] }

    private func openLibrary() {
        let empty = app.buttons["Open the model library"]
        if empty.waitForExistence(timeout: 10) {
            empty.tap()
        } else {
            app.buttons["Model library"].tap()
        }
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
    }

    private func log(_ step: String) {
        let text = status.exists ? status.label : (installed.exists ? "Installed" : "no status")
        print("P7 device download [\(Date().formatted(.iso8601))] \(step): \(text)")
    }

    func testBackgroundDownloadFromEmptyInstallation() throws {
        continueAfterFailure = false
        app.launch()
        if composer.waitForExistence(timeout: 10) {
            throw XCTSkip("a model is already installed: delete the app for an empty installation")
        }
        openLibrary()
        app.buttons["Download"].firstMatch.tap()
        XCTAssertTrue(status.waitForExistence(timeout: 60), "the download did not start")
        sleep(20)
        log("foreground")

        // Suspended: the transfer belongs to the background session.
        XCUIDevice.shared.press(.home)
        sleep(90)
        app.activate()
        XCTAssertTrue(status.waitForExistence(timeout: 20) || installed.exists)
        log("back from 90 s in the background")

        // Terminated by the system's tools: the transfers outlive the process.
        app.terminate()
        sleep(90)
        app.launch()
        if !composer.waitForExistence(timeout: 10) {
            openLibrary()
        }
        log("relaunched after 90 s terminated")

        let deadline = Date().addingTimeInterval(45 * 60)
        var last = Date()
        while !installed.exists, !composer.exists, Date() < deadline {
            if status.exists, status.label.hasPrefix("Failed") || status.label.hasPrefix("Interrupted") {
                XCTFail("download stopped: \(status.label)")
                return
            }
            if Date().timeIntervalSince(last) > 60 {
                log("waiting")
                last = Date()
            }
            sleep(5)
        }
        log("end")
        XCTAssertTrue(installed.exists || composer.exists, "the model was not installed in time")
    }
}
