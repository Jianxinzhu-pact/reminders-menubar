import Combine
import XCTest
@testable import Reminders_MenuBar

final class LaunchAtLoginCoordinatorTests: XCTestCase {
    @MainActor
    func testMacOS11And12KeepLegacyItemAndLeaveModernMigrationPending() {
        for majorVersion in [11, 12] {
            let harness = LaunchAtLoginHarness(majorVersion: majorVersion)
            harness.defaults.set(true, forKey: LaunchAtLoginCoordinator.obsoleteMigrationMarkerKey)
            harness.service.legacyState = .enabled

            let coordinator = harness.makeCoordinator()
            coordinator.start()

            XCTAssertEqual(coordinator.status, .enabled, "macOS \(majorVersion)")
            XCTAssertFalse(coordinator.migrationIsComplete, "macOS \(majorVersion)")
            XCTAssertEqual(harness.service.operations, [], "macOS \(majorVersion)")
        }
    }

    @MainActor
    func testObsoleteMarkerDoesNotSuppressMigrationAfterUpgradeToMacOS13() {
        let defaults = LaunchAtLoginDefaultsFake()
        defaults.set(true, forKey: LaunchAtLoginCoordinator.obsoleteMigrationMarkerKey)

        let oldHarness = LaunchAtLoginHarness(majorVersion: 12, defaults: defaults)
        oldHarness.service.legacyState = .enabled
        oldHarness.makeCoordinator().start()
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLoginCoordinator.migrationMarkerKey))

        let upgradedHarness = LaunchAtLoginHarness(majorVersion: 13, defaults: defaults)
        upgradedHarness.service.legacyState = .enabled
        upgradedHarness.service.mainState = .disabled
        upgradedHarness.service.registeredMainState = .enabled

        let coordinator = upgradedHarness.makeCoordinator()
        coordinator.start()

        XCTAssertEqual(upgradedHarness.service.operations, [.registerMain, .unregisterLegacy])
        XCTAssertTrue(coordinator.migrationIsComplete)
        XCTAssertEqual(coordinator.status, .enabled)
    }

    @MainActor
    func testAbsentOrDisabledLegacyItemCompletesMigrationWithoutRegisteringMainApp() {
        for legacyState in [LaunchAtLoginSystemStatus.notFound, .disabled] {
            let harness = LaunchAtLoginHarness(majorVersion: 13)
            harness.service.legacyState = legacyState
            harness.service.mainState = .disabled

            let coordinator = harness.makeCoordinator()
            coordinator.start()

            XCTAssertTrue(coordinator.migrationIsComplete)
            XCTAssertEqual(harness.service.operations, [])
            XCTAssertEqual(coordinator.status, .disabled)
        }
    }

    @MainActor
    func testMigrationRegistersMainAppBeforeUnregisteringLegacyItem() {
        let harness = LaunchAtLoginHarness(majorVersion: 13)
        harness.service.legacyState = .enabled
        harness.service.mainState = .disabled
        harness.service.registeredMainState = .enabled

        let coordinator = harness.makeCoordinator()
        coordinator.start()

        XCTAssertEqual(harness.service.operations, [.registerMain, .unregisterLegacy])
        XCTAssertEqual(harness.service.legacyState, .disabled)
        XCTAssertEqual(harness.service.mainState, .enabled)
        XCTAssertTrue(coordinator.migrationIsComplete)
        XCTAssertNil(coordinator.lastError)
    }

    @MainActor
    func testRegistrationFailurePreservesLegacyItemAndCanRetry() {
        let harness = LaunchAtLoginHarness(majorVersion: 13)
        harness.service.legacyState = .enabled
        harness.service.mainState = .disabled
        harness.service.registerMainFailuresRemaining = 1

        let coordinator = harness.makeCoordinator()
        coordinator.start()

        XCTAssertEqual(harness.service.operations, [.registerMain])
        XCTAssertEqual(harness.service.legacyState, .enabled)
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(coordinator.migrationIsComplete)
        XCTAssertEqual(coordinator.lastError?.operation, .migration)
        XCTAssertEqual(coordinator.lastError?.actualStatus, .disabled)

        coordinator.retryLastOperation()

        XCTAssertEqual(harness.service.operations, [.registerMain, .registerMain, .unregisterLegacy])
        XCTAssertEqual(harness.service.legacyState, .disabled)
        XCTAssertEqual(coordinator.status, .enabled)
        XCTAssertTrue(coordinator.migrationIsComplete)
        XCTAssertNil(coordinator.lastError)
    }

    @MainActor
    func testLegacyUnregistrationFailureRetriesCleanupWithoutRegisteringAgain() {
        let harness = LaunchAtLoginHarness(majorVersion: 13)
        harness.service.legacyState = .enabled
        harness.service.mainState = .disabled
        harness.service.unregisterLegacyFailuresRemaining = 1

        let coordinator = harness.makeCoordinator()
        coordinator.start()

        XCTAssertEqual(harness.service.operations, [.registerMain, .unregisterLegacy])
        XCTAssertEqual(harness.service.mainState, .enabled)
        XCTAssertEqual(harness.service.legacyState, .enabled)
        XCTAssertFalse(coordinator.migrationIsComplete)
        XCTAssertEqual(coordinator.lastError?.operation, .migration)

        coordinator.retryMigration()

        XCTAssertEqual(
            harness.service.operations,
            [.registerMain, .unregisterLegacy, .unregisterLegacy]
        )
        XCTAssertEqual(harness.service.mainState, .enabled)
        XCTAssertEqual(harness.service.legacyState, .disabled)
        XCTAssertTrue(coordinator.migrationIsComplete)
    }

    @MainActor
    func testAlreadyEnabledMainAppIsNotRegisteredAgain() {
        let harness = LaunchAtLoginHarness(majorVersion: 13)
        harness.service.legacyState = .enabled
        harness.service.mainState = .enabled

        let coordinator = harness.makeCoordinator()
        coordinator.start()

        XCTAssertEqual(harness.service.operations, [.unregisterLegacy])
        XCTAssertTrue(coordinator.migrationIsComplete)
        XCTAssertEqual(coordinator.status, .enabled)
    }

    @MainActor
    func testApprovalRequiredPreservesFallbackAndOpensLoginItemsSettings() {
        let harness = LaunchAtLoginHarness(majorVersion: 13)
        harness.service.legacyState = .enabled
        harness.service.mainState = .disabled
        harness.service.registeredMainState = .requiresApproval

        let coordinator = harness.makeCoordinator()
        coordinator.start()

        XCTAssertEqual(harness.service.operations, [.registerMain])
        XCTAssertEqual(coordinator.status, .requiresApproval)
        XCTAssertEqual(coordinator.displayState, .requiresApproval)
        XCTAssertEqual(harness.service.legacyState, .enabled)
        XCTAssertFalse(coordinator.migrationIsComplete)
        XCTAssertNil(coordinator.lastError)

        coordinator.applicationDidBecomeActive()
        XCTAssertEqual(harness.service.operations, [.registerMain])
        XCTAssertEqual(harness.service.legacyState, .enabled)

        coordinator.openLoginItemsSettings()
        XCTAssertEqual(harness.settingsOpener.openCount, 1)
    }

    @MainActor
    func testEnableFailureRetainsActualDisabledStateAndRetrySucceeds() {
        let harness = LaunchAtLoginHarness(majorVersion: 13, migrationComplete: true)
        harness.service.mainState = .disabled
        harness.service.registerMainFailuresRemaining = 1

        let coordinator = harness.makeCoordinator()
        coordinator.start()
        coordinator.setEnabled(true)

        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(coordinator.lastError?.operation, .enable)
        XCTAssertEqual(coordinator.lastError?.actualStatus, .disabled)
        if case .failed(let error) = coordinator.displayState {
            XCTAssertEqual(error.operation, .enable)
            XCTAssertEqual(error.actualStatus, .disabled)
        } else {
            XCTFail("Expected failed display state")
        }

        coordinator.retryLastOperation()

        XCTAssertEqual(harness.service.operations, [.registerMain, .registerMain])
        XCTAssertEqual(coordinator.status, .enabled)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertNil(coordinator.lastError)
    }

    @MainActor
    func testDisableFailureRetainsActualEnabledStateAndRetrySucceeds() {
        let harness = LaunchAtLoginHarness(majorVersion: 13, migrationComplete: true)
        harness.service.mainState = .enabled
        harness.service.unregisterMainFailuresRemaining = 1

        let coordinator = harness.makeCoordinator()
        coordinator.start()
        coordinator.setEnabled(false)

        XCTAssertEqual(coordinator.status, .enabled)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(coordinator.lastError?.operation, .disable)
        XCTAssertEqual(coordinator.lastError?.actualStatus, .enabled)

        coordinator.retryLastOperation()

        XCTAssertEqual(harness.service.operations, [.unregisterMain, .unregisterMain])
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertNil(coordinator.lastError)
    }

    @MainActor
    func testUnavailableMainServiceIsExposedWithoutAnOptimisticValue() {
        let harness = LaunchAtLoginHarness(majorVersion: 13, migrationComplete: true)
        harness.service.mainState = .notFound

        let coordinator = harness.makeCoordinator()
        coordinator.start()

        XCTAssertEqual(coordinator.status, .unavailable)
        XCTAssertEqual(coordinator.displayState, .unavailable)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertEqual(harness.service.operations, [])
    }

    @MainActor
    func testLegacyEnableAndDisableUseLegacyServiceWithoutCompletingMigration() {
        let harness = LaunchAtLoginHarness(majorVersion: 12)
        harness.service.legacyState = .notFound
        let coordinator = harness.makeCoordinator()
        coordinator.start()

        coordinator.setEnabled(true)
        XCTAssertEqual(coordinator.status, .enabled)
        coordinator.setEnabled(false)

        XCTAssertEqual(harness.service.operations, [.setLegacyEnabled(true), .setLegacyEnabled(false)])
        XCTAssertEqual(coordinator.status, .disabled)
        XCTAssertFalse(coordinator.migrationIsComplete)
    }

    @MainActor
    func testReturningFromSystemSettingsRefreshesExternalStatusAndCompletesCleanup() {
        let harness = LaunchAtLoginHarness(majorVersion: 13)
        harness.service.legacyState = .enabled
        harness.service.mainState = .requiresApproval
        let coordinator = harness.makeCoordinator()
        coordinator.start()
        XCTAssertEqual(coordinator.status, .requiresApproval)

        coordinator.openLoginItemsSettings()
        harness.service.mainState = .enabled
        coordinator.applicationDidBecomeActive()

        XCTAssertEqual(harness.settingsOpener.openCount, 1)
        XCTAssertEqual(coordinator.status, .enabled)
        XCTAssertEqual(harness.service.operations, [.unregisterLegacy])
        XCTAssertTrue(coordinator.migrationIsComplete)
    }

    @MainActor
    func testSettingsAndStatusMenuObserveTheSameCoordinatorState() {
        let harness = LaunchAtLoginHarness(majorVersion: 13, migrationComplete: true)
        harness.service.mainState = .disabled
        let coordinator = harness.makeCoordinator()
        coordinator.start()

        var settingsStatuses: [LaunchAtLoginStatus] = []
        let settingsObservation = coordinator.$status.sink { settingsStatuses.append($0) }
        let menuHelper = RightClickMenuHelper(launchAtLoginCoordinator: coordinator)

        var menu = menuHelper.buildRightClickMenu()
        XCTAssertEqual(menu.items.first?.state, .off)
        XCTAssertTrue(menu.items.first?.title.contains(localizedLaunchAtLoginStatus(.disabled)) == true)

        harness.service.mainState = .enabled
        coordinator.applicationDidBecomeActive()
        menu = menuHelper.buildRightClickMenu()

        XCTAssertEqual(settingsStatuses.last, .enabled)
        XCTAssertEqual(menu.items.first?.state, .on)
        XCTAssertTrue(menu.items.first?.title.contains(localizedLaunchAtLoginStatus(.enabled)) == true)
        withExtendedLifetime(settingsObservation) {}
    }
}

@MainActor
private final class LaunchAtLoginHarness {
    let service = LaunchAtLoginServiceFake()
    let defaults: LaunchAtLoginDefaultsFake
    let operatingSystem: LaunchAtLoginOperatingSystemFake
    let settingsOpener = LaunchAtLoginSettingsOpenerFake()

    init(
        majorVersion: Int,
        migrationComplete: Bool = false,
        defaults: LaunchAtLoginDefaultsFake? = nil
    ) {
        self.defaults = defaults ?? LaunchAtLoginDefaultsFake()
        operatingSystem = LaunchAtLoginOperatingSystemFake(majorVersion: majorVersion)
        if migrationComplete {
            self.defaults.set(true, forKey: LaunchAtLoginCoordinator.migrationMarkerKey)
        }
    }

    func makeCoordinator() -> LaunchAtLoginCoordinator {
        return LaunchAtLoginCoordinator(
            serviceManager: service,
            defaults: defaults,
            operatingSystem: operatingSystem,
            systemSettingsOpener: settingsOpener
        )
    }
}

private enum LaunchAtLoginServiceOperation: Equatable {
    case registerMain
    case unregisterMain
    case unregisterLegacy
    case setLegacyEnabled(Bool)
}

private struct LaunchAtLoginFakeError: LocalizedError {
    let message: String

    var errorDescription: String? {
        return message
    }
}

@MainActor
private final class LaunchAtLoginServiceFake: LaunchAtLoginServiceManaging {
    var mainState: LaunchAtLoginSystemStatus = .disabled
    var legacyState: LaunchAtLoginSystemStatus = .notFound
    var registeredMainState: LaunchAtLoginSystemStatus = .enabled
    var registerMainFailuresRemaining = 0
    var unregisterMainFailuresRemaining = 0
    var unregisterLegacyFailuresRemaining = 0
    var setLegacyFailuresRemaining = 0
    private(set) var operations: [LaunchAtLoginServiceOperation] = []

    func mainAppStatus() -> LaunchAtLoginSystemStatus {
        return mainState
    }

    func legacyItemStatus() -> LaunchAtLoginSystemStatus {
        return legacyState
    }

    func registerMainApp() throws {
        operations.append(.registerMain)
        if registerMainFailuresRemaining > 0 {
            registerMainFailuresRemaining -= 1
            throw LaunchAtLoginFakeError(message: "register failed")
        }
        mainState = registeredMainState
    }

    func unregisterMainApp() throws {
        operations.append(.unregisterMain)
        if unregisterMainFailuresRemaining > 0 {
            unregisterMainFailuresRemaining -= 1
            throw LaunchAtLoginFakeError(message: "unregister main failed")
        }
        mainState = .disabled
    }

    func unregisterLegacyItem() throws {
        operations.append(.unregisterLegacy)
        if unregisterLegacyFailuresRemaining > 0 {
            unregisterLegacyFailuresRemaining -= 1
            throw LaunchAtLoginFakeError(message: "unregister legacy failed")
        }
        legacyState = .disabled
    }

    func setLegacyItemEnabled(_ enabled: Bool) throws {
        operations.append(.setLegacyEnabled(enabled))
        if setLegacyFailuresRemaining > 0 {
            setLegacyFailuresRemaining -= 1
            throw LaunchAtLoginFakeError(message: "set legacy failed")
        }
        legacyState = enabled ? .enabled : .disabled
    }
}

@MainActor
private final class LaunchAtLoginDefaultsFake: LaunchAtLoginDefaultsProviding {
    private var values: [String: Bool] = [:]

    func bool(forKey defaultName: String) -> Bool {
        return values[defaultName] ?? false
    }

    func set(_ value: Bool, forKey defaultName: String) {
        values[defaultName] = value
    }
}

@MainActor
private final class LaunchAtLoginOperatingSystemFake: LaunchAtLoginOperatingSystemProviding {
    let majorVersion: Int

    var supportsModernLoginItems: Bool {
        return majorVersion >= 13
    }

    init(majorVersion: Int) {
        self.majorVersion = majorVersion
    }
}

@MainActor
private final class LaunchAtLoginSettingsOpenerFake: LaunchAtLoginSystemSettingsOpening {
    private(set) var openCount = 0

    func openLoginItemsSettings() {
        openCount += 1
    }
}
