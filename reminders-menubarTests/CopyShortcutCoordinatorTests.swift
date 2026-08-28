import XCTest
@testable import Reminders_MenuBar

final class CopyShortcutCoordinatorTests: XCTestCase {
    @MainActor
    func testSuccessfulHoveredCopyConsumesOnceAndPreservesConfiguredOrdering() {
        let clipboard = FakeReminderClipboard(initialContents: "previous")
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var actionCount = 0
        var feedbackCount = 0
        let registration = coordinator.registerCopyAction(reminderId: "reminder") {
            actionCount += 1
            let copied = ReminderCopyService.copy(
                options: [copyOption(.notes), copyOption(.title), copyOption(.url)],
                variables: [
                    .title: "Book flights",
                    .notes: "Use reward points",
                    .url: "https://example.com"
                ],
                includePropertyNames: false,
                clipboard: clipboard
            )
            if copied { feedbackCount += 1 }
            return copied
        }
        coordinator.setHovered(registration)

        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .consume)
        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(feedbackCount, 1)
        XCTAssertEqual(clipboard.writeAttempts, 1)
        XCTAssertEqual(
            clipboard.contents,
            "Use reward points\nBook flights\nhttps://example.com"
        )
    }

    @MainActor
    func testEditableOrSelectableTextResponderTakesPrecedence() {
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var actionCount = 0
        let registration = coordinator.registerCopyAction(reminderId: "reminder") {
            actionCount += 1
            return true
        }
        coordinator.setHovered(registration)

        XCTAssertEqual(
            coordinator.route(commandC, responderState: .editableOrSelectableText),
            .passThrough
        )
        XCTAssertEqual(actionCount, 0)
    }

    @MainActor
    func testOpenCreateAndEditSurfacesSuspendHoveredCopying() {
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var actionCount = 0
        let registration = coordinator.registerCopyAction(reminderId: "reminder") {
            actionCount += 1
            return true
        }
        coordinator.setHovered(registration)
        let createSurfaceId = UUID()
        let editSurfaceId = UUID()

        coordinator.setSurfacePresented(true, id: createSurfaceId)
        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)

        coordinator.setSurfacePresented(true, id: editSurfaceId)
        coordinator.setSurfacePresented(false, id: createSurfaceId)
        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)

        coordinator.setSurfacePresented(false, id: editSurfaceId)
        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .consume)
        XCTAssertEqual(actionCount, 1)
    }

    @MainActor
    func testPendingCompletionOrDeclinedActionPassesThrough() {
        let clipboard = FakeReminderClipboard(initialContents: "previous")
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var actionCount = 0
        let registration = coordinator.registerCopyAction(reminderId: "pending-reminder") {
            // This is the result returned by a row while completion or editing is pending.
            actionCount += 1
            return false
        }
        coordinator.setHovered(registration)

        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)
        XCTAssertEqual(actionCount, 1)
        XCTAssertEqual(clipboard.contents, "previous")
        XCTAssertEqual(clipboard.writeAttempts, 0)
    }

    @MainActor
    func testEmptyCopyPassesThroughWithoutFeedbackOrChangingClipboard() {
        let clipboard = FakeReminderClipboard(initialContents: "previous")
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var feedbackCount = 0
        let registration = coordinator.registerCopyAction(reminderId: "empty") {
            let copied = ReminderCopyService.copy(
                options: [copyOption(.title, isEnabled: false), copyOption(.notes, isEnabled: false)],
                variables: [.title: "Not copied"],
                includePropertyNames: false,
                clipboard: clipboard
            )
            if copied { feedbackCount += 1 }
            return copied
        }
        coordinator.setHovered(registration)

        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)
        XCTAssertEqual(feedbackCount, 0)
        XCTAssertEqual(clipboard.contents, "previous")
        XCTAssertEqual(clipboard.writeAttempts, 0)
    }

    @MainActor
    func testFailedClipboardWritePassesThroughWithoutFeedbackOrChangingClipboard() {
        let clipboard = FakeReminderClipboard(initialContents: "previous", shouldSucceed: false)
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var feedbackCount = 0
        let registration = coordinator.registerCopyAction(reminderId: "failed") {
            let copied = ReminderCopyService.copy(
                options: [copyOption(.title)],
                variables: [.title: "Not copied"],
                includePropertyNames: false,
                clipboard: clipboard
            )
            if copied { feedbackCount += 1 }
            return copied
        }
        coordinator.setHovered(registration)

        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)
        XCTAssertEqual(feedbackCount, 0)
        XCTAssertEqual(clipboard.contents, "previous")
        XCTAssertEqual(clipboard.writeAttempts, 1)
    }

    @MainActor
    func testCapsLockAndBenignFlagsAreIgnoredButConflictingModifiersPassThrough() {
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var actionCount = 0
        let registration = coordinator.registerCopyAction(reminderId: "reminder") {
            actionCount += 1
            return true
        }
        coordinator.setHovered(registration)

        let benignCommandC = CopyShortcutEventDescription(
            charactersIgnoringModifiers: "C",
            modifiers: [.command, .capsLock, .numericPad, .function, .deviceSpecific]
        )
        XCTAssertEqual(coordinator.route(benignCommandC, responderState: .none), .consume)

        for modifier in [
            CopyShortcutModifiers.shift,
            CopyShortcutModifiers.option,
            CopyShortcutModifiers.control
        ] {
            let event = CopyShortcutEventDescription(
                charactersIgnoringModifiers: "c",
                modifiers: [.command, modifier]
            )
            XCTAssertEqual(coordinator.route(event, responderState: .none), .passThrough)
        }
        XCTAssertEqual(actionCount, 1)
    }

    @MainActor
    func testMissingClearedAndStaleHoverStatesPassThrough() {
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var actionCount = 0
        let registration = coordinator.registerCopyAction(reminderId: "reminder") {
            actionCount += 1
            return true
        }

        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)

        coordinator.setHovered(registration)
        coordinator.clearIfCurrent(registration)
        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)

        coordinator.setHovered(registration)
        coordinator.unregisterCopyAction(registration)
        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)
        XCTAssertEqual(actionCount, 0)
    }

    @MainActor
    func testOnlyMostRecentlyHoveredReminderIsEligible() {
        let coordinator = CopyShortcutCoordinator(installMonitor: false)
        var copiedReminderIds: [String] = []
        let first = coordinator.registerCopyAction(reminderId: "first") {
            copiedReminderIds.append("first")
            return true
        }
        let second = coordinator.registerCopyAction(reminderId: "second") {
            copiedReminderIds.append("second")
            return true
        }

        coordinator.setHovered(first)
        coordinator.setHovered(second)
        coordinator.clearIfCurrent(first)
        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .consume)
        XCTAssertEqual(copiedReminderIds, ["second"])

        coordinator.unregisterCopyAction(second)
        XCTAssertEqual(coordinator.route(commandC, responderState: .none), .passThrough)
        XCTAssertEqual(copiedReminderIds, ["second"], "A stale latest hover must not fall back")
    }

    private var commandC: CopyShortcutEventDescription {
        return CopyShortcutEventDescription(
            charactersIgnoringModifiers: "c",
            modifiers: .command
        )
    }

}

private final class FakeReminderClipboard: ReminderClipboardWriting {
    private(set) var contents: String
    private(set) var writeAttempts = 0
    var shouldSucceed: Bool

    init(initialContents: String, shouldSucceed: Bool = true) {
        contents = initialContents
        self.shouldSucceed = shouldSucceed
    }

    func writeString(_ string: String) -> Bool {
        writeAttempts += 1
        guard shouldSucceed else { return false }
        contents = string
        return true
    }
}

private func copyOption(
    _ property: CopyProperty,
    isEnabled: Bool = true
) -> CopyPropertyOption {
    return CopyPropertyOption(property: property, isEnabled: isEnabled)
}
