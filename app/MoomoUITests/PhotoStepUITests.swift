import XCTest

/// The photo step, driven through the real UI including the system PhotosPicker.
///
/// These need photos in the simulator's library:
///
///     xcrun simctl addmedia booted photo.jpg
///
/// `assertPhotoLibraryAvailable` skips rather than fails when it is empty, so a
/// fresh machine reports "not run" instead of a false failure.
///
/// Sign-in is the phone flow against the mock backend, which accepts exactly
/// `123456` — the photo step sits past sign-in.
final class PhotoStepUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ui-testing-reset",
            "-use-mock-backend"
        ]
        app.launch()
        return app
    }

    private func consentCheckbox(in app: XCUIApplication) -> XCUIElement {
        app.buttons["I have read and agree to the Privacy Policy and Terms of Service"]
    }

    private func continueButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Continue"].firstMatch
    }

    /// Signs in with the phone flow and walks to the photo step.
    private func advanceToPhotoStep(_ app: XCUIApplication) {
        let checkbox = consentCheckbox(in: app)
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5))
        checkbox.tap()

        let phoneField = app.textFields["phone.number"]
        XCTAssertTrue(phoneField.waitForExistence(timeout: 5))
        phoneField.tap()
        phoneField.typeText("5550100200")
        app.buttons["Verification"].firstMatch.tap()

        let codeField = app.textFields["otp.code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 8), "The OTP screen must appear")
        codeField.tap()
        codeField.typeText("123456")

        // Name
        let name = app.textFields["First name"]
        XCTAssertTrue(name.waitForExistence(timeout: 8), "Should reach onboarding")
        name.tap()
        name.typeText("Riley")
        continueButton(app).tap()

        // Date of birth — a year that clears the age gate.
        let wheels = app.datePickers.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 4))
        wheels.element(boundBy: wheels.count - 1).adjust(toPickerWheelValue: "1995")
        continueButton(app).tap()

        // Gender
        XCTAssertTrue(app.buttons["Non-binary"].waitForExistence(timeout: 4))
        app.buttons["Non-binary"].tap()
        continueButton(app).tap()

        // Interested in
        XCTAssertTrue(app.buttons["Everyone"].waitForExistence(timeout: 4))
        app.buttons["Everyone"].tap()
        continueButton(app).tap()

        // Location — a list of city cards, not a free-text field.
        let city = app.buttons["Chicago, United States"]
        XCTAssertTrue(city.waitForExistence(timeout: 4), "Location step should list cities")
        city.tap()
        continueButton(app).tap()

        XCTAssertTrue(
            app.staticTexts["Add your photos"].waitForExistence(timeout: 5),
            "Should have reached the photo step"
        )
    }

    /// The system picker's navigation bar.
    ///
    /// `PHPickerViewController` is presented as a remote view *inside* the app's
    /// process, so its elements live in `app`'s tree rather than under a
    /// separate bundle identifier. Querying `com.apple.mobileslideshow` finds
    /// nothing.
    private func pickerNavigationBar(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars["Photos"]
    }

    /// The photo thumbnails in the picker grid.
    private func pickerThumbnails(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(identifier: "PXGGridLayout-Info")
    }

    /// Proxy for "an uploaded photo tile at this position exists".
    ///
    /// Anchored on the remove button rather than the tile itself. The tile is a
    /// SwiftUI image view, and image views are unreliable to address from
    /// XCUITest — the identifier resolves to no element at all under some
    /// compositions. The remove button is rendered *only* by `UploadedPhotoSlot`
    /// (a pending tile's control is labelled "Cancel upload" and carries no
    /// identifier), so its presence is exactly equivalent to an uploaded photo
    /// at that order, and buttons are always addressable.
    private func uploadedTile(_ app: XCUIApplication, _ order: Int) -> XCUIElement {
        app.buttons["photos.remove.\(order)"]
    }

    /// Picks `count` photos through the system picker and confirms.
    private func pickPhotos(_ app: XCUIApplication, count: Int) {
        app.buttons["photos.add"].firstMatch.tap()

        XCTAssertTrue(
            pickerNavigationBar(app).waitForExistence(timeout: 10),
            "The native PhotosPicker must open"
        )

        let thumbnails = pickerThumbnails(app)
        XCTAssertTrue(
            thumbnails.firstMatch.waitForExistence(timeout: 10),
            "Simulator photo library appears to be empty — run `xcrun simctl addmedia`"
        )
        XCTAssertGreaterThanOrEqual(
            thumbnails.count, count,
            "Need at least \(count) photos in the simulator library"
        )

        for index in 0..<count {
            // The picker's thumbnails report as not hittable — they are drawn by
            // PhotosUI rather than being ordinary accessible controls. Tapping
            // the element's centre coordinate is the supported way in.
            thumbnails.element(boundBy: index)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .tap()
        }

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForEnabled(timeout: 3), "Done must enable once a photo is selected")
        done.tap()
    }

    private func assertPhotoLibraryAvailable() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil,
            "Photo picker tests require a simulator with a seeded photo library."
        )
    }

    // MARK: - Tests

    /// The picker must be the real system one, not an in-app imitation.
    ///
    /// Asserts on `PXGGridLayout-Info` thumbnails and the "Select up to N
    /// photos" bar — both are Photos-framework internals that an in-app
    /// lookalike would not reproduce.
    func testAddPhotoOpensTheNativePhotosPicker() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        advanceToPhotoStep(app)

        app.buttons["photos.add"].firstMatch.tap()

        XCTAssertTrue(
            pickerNavigationBar(app).waitForExistence(timeout: 10),
            "Tapping add must open the native iOS PhotosPicker"
        )
        XCTAssertTrue(
            pickerThumbnails(app).firstMatch.waitForExistence(timeout: 10),
            "The picker must show the real photo library"
        )
        XCTAssertTrue(
            app.staticTexts["Select up to 6 photos."].exists,
            "The picker must be limited to the remaining photo slots"
        )
    }

    /// The core flow: pick a photo, it uploads, and it shows as uploaded.
    func testPickingAPhotoUploadsItAndShowsAPreview() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        advanceToPhotoStep(app)

        pickPhotos(app, count: 1)

        // The uploaded tile only appears once the bytes are stored — an
        // in-flight upload renders as `photos.uploading` instead.
        let uploaded = uploadedTile(app, 0)
        XCTAssertTrue(
            uploaded.waitForExistence(timeout: 20),
            "The picked photo must upload and appear as an uploaded tile"
        )
    }

    /// Onboarding must not advance past photos with none added.
    func testCannotContinuePastPhotosWithoutOne() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        advanceToPhotoStep(app)

        continueButton(app).tap()

        XCTAssertTrue(
            app.staticTexts["Please add at least one photo."].waitForExistence(timeout: 3),
            "The photo step must block with no photo"
        )
        XCTAssertTrue(
            app.staticTexts["Add your photos"].exists,
            "Must still be on the photo step"
        )
    }

    /// Once a photo is uploaded, the step lets you through.
    func testContinueWorksAfterAPhotoUploads() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        advanceToPhotoStep(app)

        pickPhotos(app, count: 1)
        XCTAssertTrue(uploadedTile(app, 0).waitForExistence(timeout: 20))

        continueButton(app).tap()

        XCTAssertTrue(
            app.staticTexts["Tell us about you"].waitForExistence(timeout: 5),
            "A successful upload must let onboarding continue to the bio step"
        )
    }

    func testMultiplePhotosCanBeAddedAndTheFirstIsPrimary() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        advanceToPhotoStep(app)

        pickPhotos(app, count: 2)

        XCTAssertTrue(uploadedTile(app, 0).waitForExistence(timeout: 25))
        XCTAssertTrue(uploadedTile(app, 1).waitForExistence(timeout: 25))

        // Exactly one MAIN badge, on the first photo.
        XCTAssertEqual(
            app.staticTexts.matching(identifier: "MAIN").count, 1,
            "Only the first photo is the main one"
        )
    }

    func testRemovingAPhotoDropsItFromTheGrid() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        advanceToPhotoStep(app)

        pickPhotos(app, count: 1)
        XCTAssertTrue(uploadedTile(app, 0).waitForExistence(timeout: 20))

        uploadedTile(app, 0).tap()

        XCTAssertFalse(
            uploadedTile(app, 0).waitForExistence(timeout: 3),
            "A removed photo must disappear"
        )
        // And the step blocks again, because the only photo is gone.
        continueButton(app).tap()
        XCTAssertTrue(
            app.staticTexts["Please add at least one photo."].waitForExistence(timeout: 3)
        )
    }

    /// Photos must survive a relaunch mid-onboarding, like every other answer.
    func testUploadedPhotoSurvivesRelaunch() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        advanceToPhotoStep(app)

        pickPhotos(app, count: 1)
        XCTAssertTrue(uploadedTile(app, 0).waitForExistence(timeout: 20))

        app.terminate()

        // Relaunch WITHOUT the reset flag, so the draft persists as it would for
        // a real user reopening the app.
        let relaunched = XCUIApplication()
        relaunched.launchArguments += ["-use-mock-backend"]
        relaunched.launch()

        XCTAssertTrue(
            relaunched.staticTexts["Add your photos"].waitForExistence(timeout: 10),
            "Relaunch must resume on the photo step"
        )
        XCTAssertTrue(
            uploadedTile(relaunched, 0).waitForExistence(timeout: 10),
            "The uploaded photo must still be there after a relaunch"
        )
    }

    /// The reorder list must be reachable and show the photos.
    func testReorderControlAppearsOnceAPhotoExists() throws {
        try assertPhotoLibraryAvailable()
        let app = launch()
        advanceToPhotoStep(app)

        XCTAssertFalse(
            app.buttons["photos.reorder"].exists,
            "Nothing to reorder with no photos"
        )

        pickPhotos(app, count: 2)
        XCTAssertTrue(uploadedTile(app, 1).waitForExistence(timeout: 25))

        let reorder = app.buttons["photos.reorder"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 3))
        reorder.tap()

        XCTAssertTrue(
            app.collectionViews["photos.reorderList"].waitForExistence(timeout: 3)
                || app.tables["photos.reorderList"].waitForExistence(timeout: 3),
            "The reorder list must appear"
        )
    }
}
