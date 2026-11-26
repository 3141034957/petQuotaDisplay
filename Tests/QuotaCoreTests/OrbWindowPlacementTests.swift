import XCTest
@testable import QuotaCore

final class OrbWindowPlacementTests: XCTestCase {
    func testDefaultOriginStaysInsideSmallVisibleFrame() {
        let screen = CGRect(x: -115, y: 20, width: 115, height: 120)
        let size = CGSize(width: 111, height: 111)
        let origin = OrbWindowPlacement.defaultOrigin(size: size, visibleFrame: screen)
        XCTAssertEqual(origin, CGPoint(x: -115, y: 29))
        XCTAssertTrue(screen.contains(CGRect(origin: origin, size: size)))
    }

    private let size = CGSize(width: 111, height: 111)
    private let screen = CGRect(x: 0, y: 30, width: 1440, height: 850)

    func testCornerPresetsUseTheEntireVisibleFrameOfTheSelectedScreen() {
        let left = CGRect(x: -1280, y: 48, width: 1280, height: 760)
        let expected = [
            CGPoint(x: -1256, y: 661), CGPoint(x: -135, y: 661),
            CGPoint(x: -1256, y: 84), CGPoint(x: -135, y: 84)
        ]
        let origins = OrbWindowPlacement.Corner.allCases.map {
            OrbWindowPlacement.origin(at: $0, size: size, visibleFrame: left)
        }
        XCTAssertEqual(origins, expected)
    }

    func testMovingBetweenDisplaysKeepsTheRelativePlaceInTheirVisibleAreas() {
        let source = CGRect(x: 0, y: 30, width: 1_111, height: 911)
        let target = CGRect(x: -1_200, y: -200, width: 911, height: 511)
        let origin = CGPoint(x: 250, y: 630)
        XCTAssertEqual(OrbWindowPlacement.translatedOrigin(origin, size: size, from: source, to: target),
                       CGPoint(x: -1_000, y: 100))
    }

    func testKeepsFullyVisiblePosition() {
        let origin = CGPoint(x: 800, y: 200)
        XCTAssertEqual(place(origin, screens: [screen]), origin)
    }

    func testClampsPartiallyVisibleOrbInsideUsableScreen() {
        XCTAssertEqual(
            place(CGPoint(x: 1430, y: 10), screens: [screen]),
            CGPoint(x: 1329, y: 30)
        )
    }

    func testDisconnectedDisplayMovesOrbToRemainingScreen() {
        XCTAssertEqual(
            place(CGPoint(x: 2000, y: 400), screens: [screen]),
            CGPoint(x: 1329, y: 400)
        )
    }

    func testChoosesNearestScreenIncludingNegativeCoordinates() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(
            place(CGPoint(x: -50, y: 400), screens: [screen, left]),
            CGPoint(x: 0, y: 400)
        )
        XCTAssertEqual(
            place(CGPoint(x: -90, y: 400), screens: [screen, left]),
            CGPoint(x: -111, y: 400)
        )
        XCTAssertEqual(
            place(CGPoint(x: -1800, y: -150), screens: [screen, left]),
            CGPoint(x: -1800, y: -150)
        )
    }

    func testMissingOrUndersizedScreenDoesNotProduceInvalidCoordinates() {
        let origin = CGPoint(x: 500, y: 500)
        XCTAssertEqual(place(origin, screens: []), origin)
        XCTAssertEqual(
            place(origin, screens: [CGRect(x: 20, y: 30, width: 80, height: 80)]),
            CGPoint(x: 20, y: 30)
        )
    }

    private func place(_ origin: CGPoint, screens: [CGRect]) -> CGPoint {
        OrbWindowPlacement.constrainedOrigin(origin, size: size, visibleFrames: screens)
    }
}
