import XCTest

final class NearWireDemoUITests: XCTestCase {
  @MainActor
  func testLaunchesReferenceSurface() {
    let application = XCUIApplication()
    application.launch()

    XCTAssertTrue(
      application.staticTexts["NearWire Integration Demo"].waitForExistence(timeout: 10))
    XCTAssertTrue(application.textFields["Viewer pairing code"].exists)
    XCTAssertTrue(application.staticTexts["Not Connected"].exists)
    XCTAssertTrue(application.buttons["Send Message"].exists)
    XCTAssertTrue(application.buttons["Start Performance"].exists)
    XCTAssertTrue(application.staticTexts["Stopped"].exists)
  }
}
