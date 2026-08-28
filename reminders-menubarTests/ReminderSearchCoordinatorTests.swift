import XCTest
@testable import Reminders_MenuBar

final class ReminderSearchCoordinatorTests: XCTestCase {
    @MainActor
    func testActiveStoreChangesReplaceAddedEditedDeletedListAndTagMatches() async {
        let repository = ControllableSearchRepository()
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("active-search-store-change")
        let debouncer = ManualSearchDebouncer()
        let coordinator = makeCoordinator(
            repository: repository,
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            debouncer: debouncer
        )

        coordinator.open(with: "target")
        await assertFetchCount(1, repository: repository)
        repository.completeRequest(
            at: 0,
            with: [
                searchRecord("deleted", title: "target deleted"),
                searchRecord("became-nonmatching", title: "target before edit"),
                searchRecord("edited", title: "unrelated"),
                searchRecord("list-changed", title: "list entry", calendarTitle: "Personal"),
                searchRecord("tag-changed", title: "tag entry", tags: ["later"])
            ]
        )
        await assertResults(
            ["became-nonmatching", "deleted"],
            from: coordinator,
            ignoringOrder: true
        )

        notificationCenter.post(name: notificationName, object: nil)
        notificationCenter.post(name: notificationName, object: nil)
        notificationCenter.post(name: notificationName, object: nil)
        await assertDebounceScheduleCount(3, debouncer: debouncer)
        debouncer.runPending()
        await assertFetchCount(2, repository: repository)

        repository.completeRequest(
            at: 1,
            with: [
                searchRecord("added", title: "new target"),
                searchRecord("edited", title: "edited into target"),
                searchRecord("became-nonmatching", title: "no longer relevant"),
                searchRecord("list-changed", title: "list entry", calendarTitle: "Target Projects"),
                searchRecord("tag-changed", title: "tag entry", tags: ["TARGET"])
            ]
        )
        await assertResults(
            ["added", "edited", "list-changed", "tag-changed"],
            from: coordinator,
            ignoringOrder: true
        )
        XCTAssertEqual(repository.fetchCount, 2, "The notification burst must be debounced")
    }

    @MainActor
    func testNotificationsDoNotFetchWhileSearchIsClosed() async {
        let repository = ControllableSearchRepository()
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("closed-search-store-change")
        let debouncer = ManualSearchDebouncer()
        let coordinator = makeCoordinator(
            repository: repository,
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            debouncer: debouncer
        )

        notificationCenter.post(name: notificationName, object: nil)
        await drainMainActor()
        XCTAssertEqual(repository.fetchCount, 0)
        XCTAssertFalse(debouncer.hasPendingAction)

        coordinator.open()
        await assertFetchCount(1, repository: repository)
        repository.completeRequest(at: 0, with: [])
        await drainMainActor()
        coordinator.close()

        notificationCenter.post(name: notificationName, object: nil)
        await drainMainActor()
        XCTAssertEqual(repository.fetchCount, 1)
        XCTAssertFalse(debouncer.hasPendingAction)
    }

    @MainActor
    func testClosingBeforeInitialFetchCompletesClearsAndRejectsLateResults() async {
        let repository = ControllableSearchRepository()
        let coordinator = makeCoordinator(repository: repository)

        coordinator.open(with: "target")
        await assertFetchCount(1, repository: repository)
        XCTAssertTrue(coordinator.isInitialLoading)

        coordinator.close()

        XCTAssertFalse(coordinator.isOpen)
        XCTAssertEqual(coordinator.query, "")
        XCTAssertNil(coordinator.results)
        XCTAssertFalse(coordinator.isInitialLoading)

        repository.completeRequest(at: 0, with: [searchRecord("late", title: "target")])
        await drainMainActor()

        XCTAssertNil(coordinator.results)
        XCTAssertFalse(coordinator.isInitialLoading)
    }

    @MainActor
    func testReopeningRejectsOutOfOrderResponseFromPreviousSession() async {
        let repository = ControllableSearchRepository()
        let coordinator = makeCoordinator(repository: repository)

        coordinator.open(with: "target")
        await assertFetchCount(1, repository: repository)
        coordinator.close()
        coordinator.open(with: "target")
        await assertFetchCount(2, repository: repository)

        repository.completeRequest(at: 1, with: [searchRecord("new-session", title: "target")])
        await assertResults(["new-session"], from: coordinator)

        repository.completeRequest(at: 0, with: [searchRecord("old-session", title: "target")])
        await drainMainActor()
        XCTAssertEqual(coordinator.results, ["new-session"])
    }

    @MainActor
    func testOverlappingRefreshesOnlyAcceptNewestResponse() async {
        let repository = ControllableSearchRepository()
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("overlapping-refresh-store-change")
        let debouncer = ManualSearchDebouncer()
        let coordinator = makeCoordinator(
            repository: repository,
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            debouncer: debouncer
        )

        coordinator.open(with: "target")
        await assertFetchCount(1, repository: repository)
        repository.completeRequest(at: 0, with: [searchRecord("initial", title: "target")])
        await assertResults(["initial"], from: coordinator)

        await postAndRunRefresh(
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            debouncer: debouncer,
            expectedScheduleCount: 1
        )
        await assertFetchCount(2, repository: repository)

        await postAndRunRefresh(
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            debouncer: debouncer,
            expectedScheduleCount: 2
        )
        await assertFetchCount(3, repository: repository)

        repository.completeRequest(at: 2, with: [searchRecord("newest", title: "target")])
        await assertResults(["newest"], from: coordinator)

        repository.completeRequest(at: 1, with: [searchRecord("older", title: "target")])
        await drainMainActor()
        XCTAssertEqual(coordinator.results, ["newest"])
    }

    @MainActor
    func testAcceptedFetchUsesQueryThatChangedWhileFetchWasPending() async {
        let repository = ControllableSearchRepository()
        let coordinator = makeCoordinator(repository: repository)

        coordinator.open(with: "old")
        await assertFetchCount(1, repository: repository)
        coordinator.updateQuery("new")

        repository.completeRequest(
            at: 0,
            with: [
                searchRecord("old-result", title: "old"),
                searchRecord("new-result", notes: "new")
            ]
        )
        await assertResults(["new-result"], from: coordinator)
    }

    @MainActor
    func testExistingResultsStayVisibleWithoutLoadingDuringRefresh() async {
        let repository = ControllableSearchRepository()
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("visible-results-store-change")
        let debouncer = ManualSearchDebouncer()
        let coordinator = makeCoordinator(
            repository: repository,
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            debouncer: debouncer
        )

        coordinator.open(with: "target")
        await assertFetchCount(1, repository: repository)
        repository.completeRequest(at: 0, with: [searchRecord("visible", title: "target")])
        await assertResults(["visible"], from: coordinator)

        await postAndRunRefresh(
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            debouncer: debouncer,
            expectedScheduleCount: 1
        )
        await assertFetchCount(2, repository: repository)

        XCTAssertEqual(coordinator.results, ["visible"])
        XCTAssertFalse(coordinator.isInitialLoading)

        repository.completeRequest(at: 1, with: [searchRecord("replacement", title: "target")])
        await assertResults(["replacement"], from: coordinator)
    }

    @MainActor
    func testWhitespaceOnlyQueryHasNoResultsOrLoadingState() async {
        let repository = ControllableSearchRepository()
        let coordinator = makeCoordinator(repository: repository)

        coordinator.open(with: " \n\t  ")
        await assertFetchCount(1, repository: repository)
        XCTAssertNil(coordinator.results)
        XCTAssertFalse(coordinator.isInitialLoading)

        repository.completeRequest(at: 0, with: [searchRecord("item", title: "target")])
        await drainMainActor()
        XCTAssertNil(coordinator.results)
        XCTAssertFalse(coordinator.isInitialLoading)

        coordinator.updateQuery("target")
        XCTAssertEqual(coordinator.results, ["item"])
        coordinator.updateQuery("   \n")
        XCTAssertNil(coordinator.results)
        XCTAssertFalse(coordinator.isInitialLoading)
    }

    @MainActor
    private func makeCoordinator(
        repository: ControllableSearchRepository,
        notificationCenter: NotificationCenter = NotificationCenter(),
        notificationName: Notification.Name = Notification.Name("search-store-change"),
        debouncer: ManualSearchDebouncer? = nil
    ) -> ReminderSearchCoordinator<String> {
        return ReminderSearchCoordinator(
            fetchSnapshot: { await repository.fetchSnapshot() },
            notificationCenter: notificationCenter,
            notificationName: notificationName,
            storeChangeDebouncer: debouncer ?? ManualSearchDebouncer()
        )
    }

    @MainActor
    private func postAndRunRefresh(
        notificationCenter: NotificationCenter,
        notificationName: Notification.Name,
        debouncer: ManualSearchDebouncer,
        expectedScheduleCount: Int
    ) async {
        notificationCenter.post(name: notificationName, object: nil)
        await assertDebounceScheduleCount(expectedScheduleCount, debouncer: debouncer)
        debouncer.runPending()
    }

    @MainActor
    private func assertFetchCount(
        _ expectedCount: Int,
        repository: ControllableSearchRepository,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let reachedCount = await waitUntil {
            repository.fetchCount == expectedCount
        }
        XCTAssertTrue(reachedCount, "Expected \(expectedCount) fetches", file: file, line: line)
    }

    @MainActor
    private func assertDebounceScheduleCount(
        _ expectedCount: Int,
        debouncer: ManualSearchDebouncer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let reachedCount = await waitUntil {
            debouncer.scheduleCount == expectedCount
        }
        XCTAssertTrue(
            reachedCount,
            "Expected \(expectedCount) debounce schedules",
            file: file,
            line: line
        )
    }

    @MainActor
    private func assertResults(
        _ expectedResults: [String],
        from coordinator: ReminderSearchCoordinator<String>,
        ignoringOrder: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let foundResults = await waitUntil {
            if ignoringOrder {
                return Set(coordinator.results ?? []) == Set(expectedResults)
            }
            return coordinator.results == expectedResults
        }
        XCTAssertTrue(foundResults, file: file, line: line)
    }

    @MainActor
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            await Task.yield()
        }
        return condition()
    }

    @MainActor
    private func drainMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

@MainActor
private final class ControllableSearchRepository {
    private(set) var fetchCount = 0
    private var continuations: [CheckedContinuation<[ReminderSearchRecord<String>], Never>?] = []

    func fetchSnapshot() async -> [ReminderSearchRecord<String>] {
        fetchCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func completeRequest(at index: Int, with records: [ReminderSearchRecord<String>]) {
        guard continuations.indices.contains(index),
              let continuation = continuations[index] else {
            XCTFail("No pending search request at index \(index)")
            return
        }
        continuations[index] = nil
        continuation.resume(returning: records)
    }
}

@MainActor
private final class ManualSearchDebouncer: ReminderSearchDebouncing {
    private var pendingAction: (@MainActor () -> Void)?
    private(set) var scheduleCount = 0

    var hasPendingAction: Bool {
        return pendingAction != nil
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        scheduleCount += 1
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

func searchRecord(
    _ identifier: String,
    title: String = "",
    notes: String = "",
    url: String = "",
    calendarTitle: String = "",
    tags: [String] = [],
    isCompleted: Bool = false
) -> ReminderSearchRecord<String> {
    return ReminderSearchRecord(
        item: identifier,
        metadata: ReminderSearchMetadata(
            calendarItemIdentifier: identifier,
            title: title,
            notes: notes,
            url: url,
            calendarTitle: calendarTitle,
            tags: tags,
            isCompleted: isCompleted
        )
    )
}
