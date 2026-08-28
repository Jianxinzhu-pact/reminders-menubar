import Cocoa

@MainActor
final class RightClickMenuHelper: NSObject {
    static let shared = RightClickMenuHelper(
        launchAtLoginCoordinator: LaunchAtLoginCoordinator.shared
    )

    private let launchAtLoginCoordinator: LaunchAtLoginCoordinator

    init(launchAtLoginCoordinator: LaunchAtLoginCoordinator) {
        self.launchAtLoginCoordinator = launchAtLoginCoordinator
        super.init()
    }

    // MARK: - Build Menu

    func buildRightClickMenu() -> NSMenu {
        launchAtLoginCoordinator.start()
        launchAtLoginCoordinator.refreshStatus()

        let menu = NSMenu()
        let status = launchAtLoginCoordinator.status
        let launchItem = makeMenuItem(
            title: "\(rmbLocalized(.launchAtLoginOption)) — \(localizedLaunchAtLoginStatus(status))",
            action: #selector(handleLaunchAtLoginAction),
            state: menuState(for: status)
        )
        launchItem.isEnabled = status != .unavailable
        menu.addItem(launchItem)

        if status == .requiresApproval {
            let explanation = NSMenuItem(
                title: rmbLocalized(.launchAtLoginApprovalDescription),
                action: nil,
                keyEquivalent: ""
            )
            explanation.isEnabled = false
            menu.addItem(explanation)
            menu.addItem(makeMenuItem(
                title: rmbLocalized(.launchAtLoginOpenLoginItemsButton),
                action: #selector(openLoginItemsSettings),
                systemSymbolName: "gearshape"
            ))
        }

        if let error = launchAtLoginCoordinator.lastError {
            let errorItem = NSMenuItem(
                title: localizedLaunchAtLoginError(error),
                action: nil,
                keyEquivalent: ""
            )
            errorItem.isEnabled = false
            menu.addItem(errorItem)
            menu.addItem(makeMenuItem(
                title: rmbLocalized(.launchAtLoginRetryButton),
                action: #selector(retryLaunchAtLogin),
                systemSymbolName: "arrow.clockwise"
            ))
        } else if status == .unavailable {
            menu.addItem(makeMenuItem(
                title: rmbLocalized(.launchAtLoginRetryButton),
                action: #selector(refreshLaunchAtLogin),
                systemSymbolName: "arrow.clockwise"
            ))
        }

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.reloadRemindersDataButton),
            action: #selector(reloadData),
            systemSymbolName: "arrow.clockwise"
        ))

        menu.addItem(.separator())

        if UpdateController.shared.isOutdated {
            menu.addItem(makeMenuItem(
                title: rmbLocalized(.updateAvailableNoticeButton),
                action: #selector(showUpdate),
                systemSymbolName: "arrow.down.circle"
            ))
        } else {
            menu.addItem(makeMenuItem(
                title: rmbLocalized(.checkForUpdatesButton),
                action: #selector(checkForUpdates),
                systemSymbolName: "arrow.down.circle"
            ))
        }

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.appSettingsButton),
            action: #selector(openSettingsAction),
            systemSymbolName: "gearshape"
        ))

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.appAboutButton),
            action: #selector(openAbout),
            systemSymbolName: "info.circle"
        ))

        menu.addItem(makeMenuItem(
            title: rmbLocalized(.appQuitButton),
            action: #selector(quitApp),
            systemSymbolName: "xmark.rectangle"
        ))

        return menu
    }

    // MARK: - Helpers

    private func makeMenuItem(
        title: String,
        action: Selector,
        systemSymbolName: String? = nil,
        state: NSControl.StateValue? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let systemSymbolName {
            item.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
        }
        if let state {
            item.state = state
        }
        return item
    }

    private func menuState(for status: LaunchAtLoginStatus) -> NSControl.StateValue {
        switch status {
        case .enabled:
            return .on
        case .requiresApproval:
            return .mixed
        case .disabled, .unavailable:
            return .off
        }
    }

    // MARK: - Actions

    @objc private func handleLaunchAtLoginAction() {
        if launchAtLoginCoordinator.status == .requiresApproval {
            launchAtLoginCoordinator.openLoginItemsSettings()
        } else {
            launchAtLoginCoordinator.setEnabled(!launchAtLoginCoordinator.isEnabled)
        }
    }

    @objc private func openLoginItemsSettings() {
        launchAtLoginCoordinator.openLoginItemsSettings()
    }

    @objc private func retryLaunchAtLogin() {
        launchAtLoginCoordinator.retryLastOperation()
    }

    @objc private func refreshLaunchAtLogin() {
        launchAtLoginCoordinator.refreshStatus()
    }

    @objc private func reloadData() {
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
    }

    @objc private func openSettingsAction() {
        NSApp.openAppSettings()
    }

    @objc private func checkForUpdates() {
        UpdateController.shared.checkForUpdates()
    }

    @objc private func showUpdate() {
        UpdateController.shared.showUpdate()
    }

    @objc private func openAbout() {
        NSApp.openAppSettings(tab: .about)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
