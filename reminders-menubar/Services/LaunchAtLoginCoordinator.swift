import Cocoa
import Combine
import ServiceManagement

/// The states reported by ServiceManagement before they are adapted for presentation.
enum LaunchAtLoginSystemStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case notFound
    case unavailable
}

/// The actual state shown by every Launch at Login control.
enum LaunchAtLoginStatus: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
}

enum LaunchAtLoginOperation: Equatable {
    case enable
    case disable
    case migration
}

enum LaunchAtLoginFailureReason: Equatable {
    case system(String)
    case serviceUnavailable
    case statusDidNotChange
}

struct LaunchAtLoginOperationError: Equatable {
    let operation: LaunchAtLoginOperation
    let reason: LaunchAtLoginFailureReason
    let actualStatus: LaunchAtLoginStatus
}

enum LaunchAtLoginDisplayState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unavailable
    case failed(LaunchAtLoginOperationError)
}

@MainActor
protocol LaunchAtLoginServiceManaging: AnyObject {
    func mainAppStatus() -> LaunchAtLoginSystemStatus
    func legacyItemStatus() -> LaunchAtLoginSystemStatus
    func registerMainApp() throws
    func unregisterMainApp() throws
    func unregisterLegacyItem() throws
    func setLegacyItemEnabled(_ enabled: Bool) throws
}

@MainActor
protocol LaunchAtLoginDefaultsProviding: AnyObject {
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Bool, forKey defaultName: String)
}

extension UserDefaults: LaunchAtLoginDefaultsProviding {}

@MainActor
protocol LaunchAtLoginOperatingSystemProviding: AnyObject {
    var supportsModernLoginItems: Bool { get }
}

@MainActor
protocol LaunchAtLoginSystemSettingsOpening: AnyObject {
    func openLoginItemsSettings()
}

@MainActor
final class CurrentLaunchAtLoginOperatingSystem: LaunchAtLoginOperatingSystemProviding {
    var supportsModernLoginItems: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }
}

@MainActor
final class ServiceManagementLoginItemsSettingsOpener: LaunchAtLoginSystemSettingsOpening {
    func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

@MainActor
final class ServiceManagementLaunchAtLoginService: LaunchAtLoginServiceManaging {
    func mainAppStatus() -> LaunchAtLoginSystemStatus {
        guard #available(macOS 13.0, *) else {
            return .unavailable
        }
        return status(for: SMAppService.mainApp)
    }

    func legacyItemStatus() -> LaunchAtLoginSystemStatus {
        if #available(macOS 13.0, *) {
            return status(for: SMAppService.loginItem(identifier: AppConstants.launcherBundleId))
        }

        guard let unmanagedJobs = SMCopyAllJobDictionaries(kSMDomainUserLaunchd),
              let jobs = unmanagedJobs.takeRetainedValue() as? [[String: Any]] else {
            return .unavailable
        }
        guard let launcherJob = jobs.first(where: {
            $0["Label"] as? String == AppConstants.launcherBundleId
        }) else {
            return .notFound
        }
        return launcherJob["OnDemand"] as? Bool == true ? .enabled : .disabled
    }

    func registerMainApp() throws {
        guard #available(macOS 13.0, *) else {
            throw serviceUnavailableError()
        }
        try SMAppService.mainApp.register()
    }

    func unregisterMainApp() throws {
        guard #available(macOS 13.0, *) else {
            throw serviceUnavailableError()
        }
        try SMAppService.mainApp.unregister()
    }

    func unregisterLegacyItem() throws {
        guard #available(macOS 13.0, *) else {
            throw serviceUnavailableError()
        }
        try SMAppService.loginItem(identifier: AppConstants.launcherBundleId).unregister()
    }

    func setLegacyItemEnabled(_ enabled: Bool) throws {
        guard SMLoginItemSetEnabled(AppConstants.launcherBundleId as CFString, enabled) else {
            throw NSError(
                domain: "RemindersMenuBar.LaunchAtLogin",
                code: 1,
                userInfo: nil
            )
        }
    }

    @available(macOS 13.0, *)
    private func status(for service: SMAppService) -> LaunchAtLoginSystemStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable
        }
    }

    private func serviceUnavailableError() -> Error {
        return NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.featureUnsupported.rawValue,
            userInfo: nil
        )
    }
}

/// Owns launch-at-login state, explicit operations, and the one-way legacy migration.
///
/// No requested value is published optimistically. Every operation reads ServiceManagement again,
/// and failures are exposed as non-modal state so startup can continue and the user can retry.
@MainActor
final class LaunchAtLoginCoordinator: ObservableObject {
    static let migrationMarkerKey = "launchAtLoginMigrated.v2"
    static let obsoleteMigrationMarkerKey = "launchAtLoginMigrated"

    static let shared = LaunchAtLoginCoordinator(
        serviceManager: ServiceManagementLaunchAtLoginService(),
        defaults: UserDefaults.standard,
        operatingSystem: CurrentLaunchAtLoginOperatingSystem(),
        systemSettingsOpener: ServiceManagementLoginItemsSettingsOpener()
    )

    @Published private(set) var status: LaunchAtLoginStatus = .unavailable
    @Published private(set) var lastError: LaunchAtLoginOperationError?

    var displayState: LaunchAtLoginDisplayState {
        if let lastError {
            return .failed(lastError)
        }
        switch status {
        case .enabled:
            return .enabled
        case .disabled:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .unavailable:
            return .unavailable
        }
    }

    var isEnabled: Bool {
        return status == .enabled
    }

    var migrationIsComplete: Bool {
        return defaults.bool(forKey: Self.migrationMarkerKey)
    }

    private let serviceManager: LaunchAtLoginServiceManaging
    private let defaults: LaunchAtLoginDefaultsProviding
    private let operatingSystem: LaunchAtLoginOperatingSystemProviding
    private let systemSettingsOpener: LaunchAtLoginSystemSettingsOpening
    private var hasStarted = false

    init(
        serviceManager: LaunchAtLoginServiceManaging,
        defaults: LaunchAtLoginDefaultsProviding,
        operatingSystem: LaunchAtLoginOperatingSystemProviding,
        systemSettingsOpener: LaunchAtLoginSystemSettingsOpening
    ) {
        self.serviceManager = serviceManager
        self.defaults = defaults
        self.operatingSystem = operatingSystem
        self.systemSettingsOpener = systemSettingsOpener
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshStatus()
        migrateIfNeeded()
    }

    func applicationDidBecomeActive() {
        migrateIfNeeded()
        refreshStatus()
    }

    func refreshStatus() {
        let systemStatus = operatingSystem.supportsModernLoginItems
            ? serviceManager.mainAppStatus()
            : serviceManager.legacyItemStatus()
        publish(systemStatus: systemStatus, legacyStatus: !operatingSystem.supportsModernLoginItems)
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        if operatingSystem.supportsModernLoginItems {
            setModernLoginItemEnabled(enabled)
        } else {
            setLegacyLoginItemEnabled(enabled)
        }
    }

    func retryLastOperation() {
        guard let operation = lastError?.operation else {
            refreshStatus()
            return
        }

        switch operation {
        case .enable:
            setEnabled(true)
        case .disable:
            setEnabled(false)
        case .migration:
            migrateIfNeeded()
        }
    }

    func retryMigration() {
        migrateIfNeeded()
    }

    func openLoginItemsSettings() {
        systemSettingsOpener.openLoginItemsSettings()
    }

    private func setModernLoginItemEnabled(_ enabled: Bool) {
        let currentStatus = serviceManager.mainAppStatus()
        publish(systemStatus: currentStatus)

        do {
            if enabled {
                if currentStatus == .requiresApproval {
                    return
                }
                if currentStatus != .enabled {
                    try serviceManager.registerMainApp()
                }

                let updatedStatus = serviceManager.mainAppStatus()
                publish(systemStatus: updatedStatus)
                switch updatedStatus {
                case .enabled:
                    // An explicit retry can also finish a migration that previously failed cleanup.
                    migrateIfNeeded()
                case .requiresApproval:
                    // Registration succeeded, but launch is not enabled until macOS approval.
                    break
                default:
                    recordError(operation: .enable, reason: .statusDidNotChange)
                }
            } else {
                if currentStatus != .disabled && currentStatus != .notFound {
                    try serviceManager.unregisterMainApp()
                }

                let updatedStatus = serviceManager.mainAppStatus()
                publish(systemStatus: updatedStatus)
                guard updatedStatus == .disabled || updatedStatus == .notFound else {
                    recordError(operation: .disable, reason: .statusDidNotChange)
                    return
                }
                finishLegacyCleanupAfterExplicitDisable()
            }
        } catch {
            refreshStatus()
            if enabled && status == .requiresApproval {
                // Some ServiceManagement versions report approval as both a status and an error.
                // The actionable approval state is more useful than treating it as a failed request.
                lastError = nil
            } else {
                recordError(operation: enabled ? .enable : .disable, reason: .system(error.localizedDescription))
            }
        }
    }

    private func setLegacyLoginItemEnabled(_ enabled: Bool) {
        do {
            let currentStatus = serviceManager.legacyItemStatus()
            let alreadyInRequestedState = enabled
                ? currentStatus == .enabled
                : currentStatus == .disabled || currentStatus == .notFound
            if !alreadyInRequestedState {
                try serviceManager.setLegacyItemEnabled(enabled)
            }

            let updatedStatus = serviceManager.legacyItemStatus()
            publish(systemStatus: updatedStatus, legacyStatus: true)
            let reachedRequestedState = enabled
                ? updatedStatus == .enabled
                : updatedStatus == .disabled || updatedStatus == .notFound
            if !reachedRequestedState {
                recordError(operation: enabled ? .enable : .disable, reason: .statusDidNotChange)
            }
        } catch {
            refreshStatus()
            recordError(operation: enabled ? .enable : .disable, reason: .system(error.localizedDescription))
        }
    }

    private func migrateIfNeeded() {
        // The obsolete unversioned marker is intentionally never read. It was written on macOS
        // 11/12 even though those versions could not perform the migration.
        guard operatingSystem.supportsModernLoginItems else {
            refreshStatus()
            return
        }
        guard !migrationIsComplete else {
            refreshStatus()
            return
        }

        if lastError?.operation == .migration {
            lastError = nil
        }

        let legacyStatus = serviceManager.legacyItemStatus()
        switch legacyStatus {
        case .disabled, .notFound, .requiresApproval:
            markMigrationComplete()
            refreshStatus()
        case .unavailable:
            refreshStatus()
            recordError(operation: .migration, reason: .serviceUnavailable)
        case .enabled:
            migrateEnabledLegacyItem()
        }
    }

    private func migrateEnabledLegacyItem() {
        var mainStatus = serviceManager.mainAppStatus()
        publish(systemStatus: mainStatus)

        if mainStatus == .requiresApproval {
            // Keep the enabled launcher as a fallback until the user approves the main app.
            return
        }

        do {
            if mainStatus != .enabled {
                try serviceManager.registerMainApp()
                mainStatus = serviceManager.mainAppStatus()
                publish(systemStatus: mainStatus)
            }

            if mainStatus == .requiresApproval {
                // register() can complete by creating a request that still needs user approval.
                return
            }
            guard mainStatus == .enabled else {
                recordError(operation: .migration, reason: .statusDidNotChange)
                return
            }

            // The old item is removed only after the main app is confirmed enabled.
            try serviceManager.unregisterLegacyItem()
            markMigrationComplete()
            refreshStatus()
        } catch {
            refreshStatus()
            if status == .requiresApproval {
                // Keep the legacy fallback and expose the System Settings approval action.
                lastError = nil
            } else {
                recordError(operation: .migration, reason: .system(error.localizedDescription))
            }
        }
    }

    private func finishLegacyCleanupAfterExplicitDisable() {
        guard !migrationIsComplete else { return }

        let legacyStatus = serviceManager.legacyItemStatus()
        do {
            if legacyStatus == .enabled {
                try serviceManager.unregisterLegacyItem()
            } else if legacyStatus == .unavailable {
                recordError(operation: .disable, reason: .serviceUnavailable)
                return
            }
            markMigrationComplete()
        } catch {
            refreshStatus()
            recordError(operation: .disable, reason: .system(error.localizedDescription))
        }
    }

    private func markMigrationComplete() {
        defaults.set(true, forKey: Self.migrationMarkerKey)
        if lastError?.operation == .migration {
            lastError = nil
        }
    }

    private func publish(systemStatus: LaunchAtLoginSystemStatus, legacyStatus: Bool = false) {
        let actualStatus = presentationStatus(for: systemStatus, legacyStatus: legacyStatus)
        if let lastError, lastError.actualStatus != actualStatus {
            self.lastError = nil
        }
        status = actualStatus
    }

    private func presentationStatus(
        for systemStatus: LaunchAtLoginSystemStatus,
        legacyStatus: Bool
    ) -> LaunchAtLoginStatus {
        switch systemStatus {
        case .enabled:
            return .enabled
        case .disabled:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return legacyStatus ? .disabled : .unavailable
        case .unavailable:
            return .unavailable
        }
    }

    private func recordError(operation: LaunchAtLoginOperation, reason: LaunchAtLoginFailureReason) {
        lastError = LaunchAtLoginOperationError(
            operation: operation,
            reason: reason,
            actualStatus: status
        )
    }
}
