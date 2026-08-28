import XCTest
@testable import Reminders_MenuBar

final class RemindersAuthorizationCoordinatorTests: XCTestCase {
    @MainActor
    func testGrantResumesPendingOpenExactlyOnce() async {
        let authorization = AuthorizationProviderDouble(isAuthorized: false)
        let presentation = PopoverPresentationSpy()
        let didShow = expectation(description: "popover shown after authorization")
        presentation.onShow = { didShow.fulfill() }
        let coordinator = makeCoordinator(authorization: authorization, presentation: presentation)

        coordinator.togglePopover()

        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(presentation.contentInitializationCount, 0)
        XCTAssertEqual(presentation.showCount, 0)

        authorization.completeRequest(at: 0, granted: true)
        await fulfillment(of: [didShow], timeout: 1)

        XCTAssertEqual(presentation.contentInitializationCount, 1)
        XCTAssertEqual(presentation.showCount, 1)
        XCTAssertTrue(presentation.isVisible)

        // EventKit promises one callback, but an accidental duplicate still must not show again.
        authorization.completeRequest(at: 0, granted: true)
        await drainMainActor()

        XCTAssertEqual(presentation.showAttemptCount, 1)
        XCTAssertEqual(presentation.showCount, 1)
    }

    @MainActor
    func testRepeatedInvocationsWhilePendingCoalesceIntoOneRequestAndOpen() async {
        let authorization = AuthorizationProviderDouble(isAuthorized: false)
        let presentation = PopoverPresentationSpy()
        let didShow = expectation(description: "one coalesced open")
        presentation.onShow = { didShow.fulfill() }
        let coordinator = makeCoordinator(authorization: authorization, presentation: presentation)

        coordinator.togglePopover()
        authorization.isAuthorized = true
        coordinator.togglePopover()
        coordinator.togglePopover()

        XCTAssertEqual(authorization.requestCount, 1)
        XCTAssertEqual(presentation.toggleCount, 0)
        XCTAssertEqual(presentation.showCount, 0)

        authorization.completeRequest(at: 0, granted: true)
        await fulfillment(of: [didShow], timeout: 1)

        XCTAssertEqual(presentation.showAttemptCount, 1)
        XCTAssertEqual(presentation.showCount, 1)
    }

    @MainActor
    func testDenialReportsFailureWithoutOpening() async {
        let authorization = AuthorizationProviderDouble(isAuthorized: false)
        let presentation = PopoverPresentationSpy()
        let didReportFailure = expectation(description: "denial alert requested")
        presentation.onFailure = { didReportFailure.fulfill() }
        let coordinator = makeCoordinator(authorization: authorization, presentation: presentation)

        coordinator.togglePopover()
        authorization.completeRequest(at: 0, granted: false, errorMessage: nil)
        await fulfillment(of: [didReportFailure], timeout: 1)

        XCTAssertEqual(presentation.failureCount, 1)
        XCTAssertNil(presentation.lastErrorMessage)
        XCTAssertEqual(presentation.contentInitializationCount, 0)
        XCTAssertEqual(presentation.showCount, 0)
        XCTAssertFalse(presentation.isVisible)
    }

    @MainActor
    func testErrorIsReportedAndAFollowingInvocationCanRetry() async {
        let authorization = AuthorizationProviderDouble(isAuthorized: false)
        let presentation = PopoverPresentationSpy()
        let didReportFailure = expectation(description: "request error reported")
        presentation.onFailure = { didReportFailure.fulfill() }
        let coordinator = makeCoordinator(authorization: authorization, presentation: presentation)

        coordinator.togglePopover()
        authorization.completeRequest(at: 0, granted: false, errorMessage: "EventKit failed")
        await fulfillment(of: [didReportFailure], timeout: 1)

        XCTAssertEqual(presentation.lastErrorMessage, "EventKit failed")
        XCTAssertEqual(presentation.showCount, 0)

        let didShow = expectation(description: "retry opens after grant")
        presentation.onShow = { didShow.fulfill() }
        coordinator.togglePopover()

        XCTAssertEqual(authorization.requestCount, 2)

        // A stale callback from the failed request cannot consume the retry's pending open.
        authorization.completeRequest(at: 0, granted: true)
        await drainMainActor()
        XCTAssertEqual(presentation.showCount, 0)

        authorization.completeRequest(at: 1, granted: true)
        await fulfillment(of: [didShow], timeout: 1)

        XCTAssertEqual(presentation.showCount, 1)
        XCTAssertTrue(presentation.isVisible)
    }

    @MainActor
    func testAlreadyAuthorizedInvocationsRetainToggleBehavior() {
        let authorization = AuthorizationProviderDouble(isAuthorized: true)
        let presentation = PopoverPresentationSpy()
        let coordinator = makeCoordinator(authorization: authorization, presentation: presentation)

        coordinator.togglePopover()

        XCTAssertTrue(presentation.isVisible)
        XCTAssertEqual(presentation.toggleCount, 1)
        XCTAssertEqual(authorization.requestCount, 0)

        coordinator.togglePopover()

        XCTAssertFalse(presentation.isVisible)
        XCTAssertEqual(presentation.toggleCount, 2)
        XCTAssertEqual(presentation.showAttemptCount, 0)
        XCTAssertEqual(authorization.requestCount, 0)
    }

    @MainActor
    func testBackgroundCompletionPerformsPresentationOnMainActor() async {
        let authorization = AuthorizationProviderDouble(isAuthorized: false)
        let presentation = PopoverPresentationSpy()
        let didShow = expectation(description: "background completion reaches main actor")
        presentation.onShow = { didShow.fulfill() }
        let coordinator = makeCoordinator(authorization: authorization, presentation: presentation)

        coordinator.togglePopover()
        authorization.completeRequest(at: 0, granted: true, onBackgroundQueue: true)
        await fulfillment(of: [didShow], timeout: 1)

        XCTAssertEqual(presentation.presentationWasOnMainThread, [true])
    }

    @MainActor
    func testLateGrantUsesIdempotentShowAndDoesNotCloseVisiblePopover() async {
        let authorization = AuthorizationProviderDouble(isAuthorized: false)
        let presentation = PopoverPresentationSpy(isVisible: true, hasInitializedContent: true)
        let didAttemptShow = expectation(description: "late grant handled")
        presentation.onShowAttempt = { didAttemptShow.fulfill() }
        let coordinator = makeCoordinator(authorization: authorization, presentation: presentation)

        coordinator.togglePopover()
        authorization.completeRequest(at: 0, granted: true)
        await fulfillment(of: [didAttemptShow], timeout: 1)

        XCTAssertTrue(presentation.isVisible)
        XCTAssertEqual(presentation.toggleCount, 0)
        XCTAssertEqual(presentation.showAttemptCount, 1)
        XCTAssertEqual(presentation.showCount, 0)
        XCTAssertEqual(presentation.contentInitializationCount, 1)
    }

    @MainActor
    func testCompletionAfterCoordinatorDeallocationIsIgnoredSafely() async {
        let authorization = AuthorizationProviderDouble(isAuthorized: false)
        let presentation = PopoverPresentationSpy()
        var coordinator: RemindersAuthorizationCoordinator? = makeCoordinator(
            authorization: authorization,
            presentation: presentation
        )

        coordinator?.togglePopover()
        coordinator = nil
        authorization.completeRequest(at: 0, granted: true)
        await drainMainActor()

        XCTAssertEqual(presentation.showAttemptCount, 0)
        XCTAssertEqual(presentation.failureCount, 0)
    }

    @MainActor
    private func makeCoordinator(
        authorization: AuthorizationProviderDouble,
        presentation: PopoverPresentationSpy
    ) -> RemindersAuthorizationCoordinator {
        RemindersAuthorizationCoordinator(
            authorizationProvider: authorization,
            toggleAuthorizedPopover: { presentation.toggle() },
            showAuthorizedPopover: { presentation.showIfHidden() },
            reportAuthorizationFailure: { presentation.reportFailure($0) }
        )
    }

    @MainActor
    private func drainMainActor() async {
        await Task.yield()
        await Task.yield()
    }
}

@MainActor
private final class AuthorizationProviderDouble: RemindersAuthorizationProviding {
    var isAuthorized: Bool
    private(set) var requestCount = 0
    private var completions: [RemindersAuthorizationCompletion] = []

    init(isAuthorized: Bool) {
        self.isAuthorized = isAuthorized
    }

    func requestAccess(completion: @escaping RemindersAuthorizationCompletion) {
        requestCount += 1
        completions.append(completion)
    }

    func completeRequest(
        at index: Int,
        granted: Bool,
        errorMessage: String? = nil,
        onBackgroundQueue: Bool = false
    ) {
        let completion = completions[index]
        if granted {
            isAuthorized = true
        }

        if onBackgroundQueue {
            DispatchQueue.global(qos: .userInitiated).async {
                completion(granted, errorMessage)
            }
        } else {
            completion(granted, errorMessage)
        }
    }
}

@MainActor
private final class PopoverPresentationSpy {
    private(set) var isVisible: Bool
    private(set) var toggleCount = 0
    private(set) var showAttemptCount = 0
    private(set) var showCount = 0
    private(set) var failureCount = 0
    private(set) var lastErrorMessage: String?
    private(set) var contentInitializationCount: Int
    private(set) var presentationWasOnMainThread: [Bool] = []

    var onShow: (() -> Void)?
    var onShowAttempt: (() -> Void)?
    var onFailure: (() -> Void)?

    init(isVisible: Bool = false, hasInitializedContent: Bool = false) {
        self.isVisible = isVisible
        contentInitializationCount = hasInitializedContent ? 1 : 0
    }

    func toggle() {
        toggleCount += 1
        initializeContentIfNeeded()
        isVisible.toggle()
    }

    func showIfHidden() {
        showAttemptCount += 1
        presentationWasOnMainThread.append(Thread.isMainThread)
        initializeContentIfNeeded()
        onShowAttempt?()

        guard !isVisible else { return }
        isVisible = true
        showCount += 1
        onShow?()
    }

    func reportFailure(_ errorMessage: String?) {
        failureCount += 1
        lastErrorMessage = errorMessage
        presentationWasOnMainThread.append(Thread.isMainThread)
        onFailure?()
    }

    private func initializeContentIfNeeded() {
        if contentInitializationCount == 0 {
            contentInitializationCount = 1
        }
    }
}
