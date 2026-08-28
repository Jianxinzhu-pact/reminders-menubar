import XCTest
@testable import Reminders_MenuBar

final class ReminderCompletionCoordinatorTests: XCTestCase {
    @MainActor
    func testCompletingRootPersistsEntireCyclicAliasedSubtreeExactlyOnce() {
        let root = CompletionTestReminder("root")
        let intermediate = CompletionTestReminder("intermediate")
        let sibling = CompletionTestReminder("sibling")
        let leaf = CompletionTestReminder("leaf")
        root.children = [intermediate, sibling]
        intermediate.children = [leaf]
        sibling.children = [leaf]
        leaf.children = [root]

        let harness = CompletionHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.handleTap(on: root)
        XCTAssertTrue(coordinator.isPending)
        XCTAssertTrue(coordinator.isFilled)
        XCTAssertTrue(harness.persistedIdentifiers.isEmpty)

        harness.scheduler.runPending()

        XCTAssertEqual(harness.persistedIdentifiers, ["root", "intermediate", "leaf", "sibling"])
        XCTAssertEqual(Set(harness.persistedIdentifiers).count, 4)
        XCTAssertTrue([root, intermediate, sibling, leaf].allSatisfy(\.isCompleted))
        XCTAssertFalse(coordinator.isPending)
        XCTAssertFalse(coordinator.isFilled)
    }

    @MainActor
    func testCompletingIntermediateExcludesAncestorAndSiblingBranches() {
        let root = CompletionTestReminder("root")
        let intermediate = CompletionTestReminder("intermediate")
        let leaf = CompletionTestReminder("leaf")
        let sibling = CompletionTestReminder("sibling")
        let siblingLeaf = CompletionTestReminder("sibling-leaf")
        root.children = [intermediate, sibling]
        intermediate.children = [leaf]
        sibling.children = [siblingLeaf]

        let harness = CompletionHarness()
        let coordinator = harness.makeCoordinator()
        coordinator.handleTap(on: intermediate)
        harness.scheduler.runPending()

        XCTAssertEqual(harness.persistedIdentifiers, ["intermediate", "leaf"])
        XCTAssertTrue(intermediate.isCompleted)
        XCTAssertTrue(leaf.isCompleted)
        XCTAssertFalse(root.isCompleted)
        XCTAssertFalse(sibling.isCompleted)
        XCTAssertFalse(siblingLeaf.isCompleted)
    }

    @MainActor
    func testCompletingLeafPersistsOnlyLeaf() {
        let leaf = CompletionTestReminder("leaf")
        let harness = CompletionHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.handleTap(on: leaf)
        harness.scheduler.runPending()

        XCTAssertEqual(harness.persistedIdentifiers, ["leaf"])
        XCTAssertTrue(leaf.isCompleted)
    }

    @MainActor
    func testCancellingDuringUndoWindowPerformsNoCompletionWrites() {
        let root = CompletionTestReminder("root")
        let child = CompletionTestReminder("child")
        root.children = [child]
        let harness = CompletionHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.handleTap(on: root)
        coordinator.handleTap(on: root)
        harness.scheduler.runPending()

        XCTAssertTrue(harness.persistedIdentifiers.isEmpty)
        XCTAssertFalse(root.isCompleted)
        XCTAssertFalse(child.isCompleted)
        XCTAssertFalse(coordinator.isPending)
        XCTAssertFalse(coordinator.isFilled)
        XCTAssertEqual(harness.scheduler.scheduledDelays, [1.5])
    }

    @MainActor
    func testUncompletionRemainsImmediateAndDoesNotChangeDescendants() {
        let root = CompletionTestReminder("root", isCompleted: true)
        let child = CompletionTestReminder("child", isCompleted: true)
        root.children = [child]
        let harness = CompletionHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.handleTap(on: root)

        XCTAssertEqual(harness.persistedIdentifiers, ["root"])
        XCTAssertFalse(root.isCompleted)
        XCTAssertTrue(child.isCompleted)
        XCTAssertTrue(harness.scheduler.scheduledDelays.isEmpty)
    }

    @MainActor
    func testDisappearingDuringUndoWindowCommitsSubtreeImmediately() {
        let root = CompletionTestReminder("root")
        let child = CompletionTestReminder("child")
        root.children = [child]
        let harness = CompletionHarness()
        let coordinator = harness.makeCoordinator()

        coordinator.handleTap(on: root)
        coordinator.completePendingImmediately()
        harness.scheduler.runPending()

        XCTAssertEqual(harness.persistedIdentifiers, ["root", "child"])
        XCTAssertTrue(root.isCompleted)
        XCTAssertTrue(child.isCompleted)
    }
}

private final class CompletionTestReminder {
    let identifier: String
    var isCompleted: Bool
    var children: [CompletionTestReminder] = []

    init(_ identifier: String, isCompleted: Bool = false) {
        self.identifier = identifier
        self.isCompleted = isCompleted
    }
}

@MainActor
private final class CompletionHarness {
    let scheduler = ManualReminderCompletionScheduler()
    private(set) var persistedIdentifiers: [String] = []

    func makeCoordinator() -> ReminderCompletionCoordinator<CompletionTestReminder, String> {
        return ReminderCompletionCoordinator(
            completionDelayInSeconds: 1.5,
            scheduler: scheduler,
            identifier: { $0.identifier },
            children: { $0.children },
            isCompleted: { $0.isCompleted },
            setCompleted: { $0.isCompleted = $1 },
            persist: { [weak self] in self?.persistedIdentifiers.append($0.identifier) }
        )
    }
}

@MainActor
private final class ManualReminderCompletionScheduler: ReminderCompletionScheduling {
    private var pendingAction: (@MainActor () -> Void)?
    private(set) var scheduledDelays: [Double] = []

    func schedule(after delayInSeconds: Double, action: @escaping @MainActor () -> Void) {
        scheduledDelays.append(delayInSeconds)
        pendingAction = action
    }

    func cancel() {
        pendingAction = nil
    }

    func runPending() {
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}
