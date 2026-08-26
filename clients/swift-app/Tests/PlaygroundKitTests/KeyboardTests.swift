import XCTest
@testable import PlaygroundKit

final class KeyboardTests: XCTestCase {
    /// The arena's y grows downward. Getting this backwards makes W move you
    /// down the screen, which is exactly what it did.
    func testMoveYIsPositiveDownwards() {
        let keyboard = Keyboard()

        keyboard.press("w")
        XCTAssertEqual(keyboard.moveY, -1, "W should decrease y, which is up the screen")
        keyboard.release("w")

        keyboard.press("s")
        XCTAssertEqual(keyboard.moveY, 1, "S should increase y, which is down the screen")
        keyboard.release("s")

        keyboard.press("up")
        XCTAssertEqual(keyboard.moveY, -1)
        keyboard.release("up")

        keyboard.press("down")
        XCTAssertEqual(keyboard.moveY, 1)
        keyboard.release("down")
    }

    func testMoveXIsPositiveRightwards() {
        let keyboard = Keyboard()

        keyboard.press("d")
        XCTAssertEqual(keyboard.moveX, 1)
        keyboard.release("d")

        keyboard.press("a")
        XCTAssertEqual(keyboard.moveX, -1)
        keyboard.release("a")
    }

    func testOpposingKeysCancel() {
        let keyboard = Keyboard()
        keyboard.press("w")
        keyboard.press("s")
        XCTAssertEqual(keyboard.moveY, 0)
    }

    func testAnEdgeFiresOncePerPress() {
        let keyboard = Keyboard()
        keyboard.press("i")
        XCTAssertTrue(keyboard.takeEdge("i"))
        XCTAssertFalse(keyboard.takeEdge("i"), "a held key should not fire every frame")

        keyboard.release("i")
        keyboard.press("i")
        XCTAssertTrue(keyboard.takeEdge("i"))
    }
}
