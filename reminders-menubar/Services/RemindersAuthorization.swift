import Foundation

typealias RemindersAuthorizationCompletion = @Sendable (Bool, String?) -> Void

@MainActor
protocol RemindersAuthorizationProviding: AnyObject {
    var isAuthorized: Bool { get }

    func requestAccess(completion: @escaping RemindersAuthorizationCompletion)
}

/// Coordinates an invocation that may first need Reminders authorization.
///
/// The request callback is allowed to arrive on any queue. All state transitions and presentation
/// callbacks are moved back to the main actor before they run.
@MainActor
final class RemindersAuthorizationCoordinator {
    private let authorizationProvider: RemindersAuthorizationProviding
    private let toggleAuthorizedPopover: @MainActor () -> Void
    private let showAuthorizedPopover: @MainActor () -> Void
    private let reportAuthorizationFailure: @MainActor (String?) -> Void

    private var activeRequestIdentifier: UInt?
    private var nextRequestIdentifier: UInt = 0
    private var hasPendingOpen = false

    init(
        authorizationProvider: RemindersAuthorizationProviding,
        toggleAuthorizedPopover: @escaping @MainActor () -> Void,
        showAuthorizedPopover: @escaping @MainActor () -> Void,
        reportAuthorizationFailure: @escaping @MainActor (String?) -> Void
    ) {
        self.authorizationProvider = authorizationProvider
        self.toggleAuthorizedPopover = toggleAuthorizedPopover
        self.showAuthorizedPopover = showAuthorizedPopover
        self.reportAuthorizationFailure = reportAuthorizationFailure
    }

    func togglePopover() {
        // Once a request has started, every invocation belongs to the same pending open intent.
        // In particular, do not toggle if the system status changes before EventKit calls back.
        if activeRequestIdentifier != nil {
            hasPendingOpen = true
            return
        }

        if authorizationProvider.isAuthorized {
            toggleAuthorizedPopover()
            return
        }

        hasPendingOpen = true
        nextRequestIdentifier &+= 1
        let requestIdentifier = nextRequestIdentifier
        activeRequestIdentifier = requestIdentifier

        authorizationProvider.requestAccess { [weak self] granted, errorMessage in
            Task { @MainActor [weak self] in
                self?.authorizationDidComplete(
                    requestIdentifier: requestIdentifier,
                    granted: granted,
                    errorMessage: errorMessage
                )
            }
        }
    }

    private func authorizationDidComplete(
        requestIdentifier: UInt,
        granted: Bool,
        errorMessage: String?
    ) {
        // Ignore duplicate or stale callbacks. A callback from an earlier failed request must not
        // consume the pending action of a later retry.
        guard activeRequestIdentifier == requestIdentifier else { return }

        activeRequestIdentifier = nil
        let shouldOpen = hasPendingOpen
        hasPendingOpen = false

        if granted {
            if shouldOpen {
                showAuthorizedPopover()
            }
        } else {
            reportAuthorizationFailure(errorMessage)
        }
    }
}
