import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var userPreferences = UserPreferences.shared
    @ObservedObject var launchAtLoginCoordinator = LaunchAtLoginCoordinator.shared

    var body: some View {
        Form {
            SettingsSection {
                Toggle(
                    rmbLocalized(.launchAtLoginOption),
                    isOn: Binding(
                        get: { launchAtLoginCoordinator.isEnabled },
                        set: { launchAtLoginCoordinator.setEnabled($0) }
                    )
                )
                .disabled(
                    launchAtLoginCoordinator.status == .requiresApproval ||
                    launchAtLoginCoordinator.status == .unavailable
                )

                Text(rmbLocalized(
                    .launchAtLoginStatusFormat,
                    localizedLaunchAtLoginStatus(launchAtLoginCoordinator.status)
                ))
                .modifier(SettingsNoteStyle())

                if launchAtLoginCoordinator.status == .requiresApproval {
                    Text(rmbLocalized(.launchAtLoginApprovalDescription))
                        .modifier(SettingsNoteStyle())
                    Button(rmbLocalized(.launchAtLoginOpenLoginItemsButton)) {
                        launchAtLoginCoordinator.openLoginItemsSettings()
                    }
                }

                if let error = launchAtLoginCoordinator.lastError {
                    Text(localizedLaunchAtLoginError(error))
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(rmbLocalized(.launchAtLoginRetryButton)) {
                        launchAtLoginCoordinator.retryLastOperation()
                    }
                } else if launchAtLoginCoordinator.status == .unavailable {
                    Button(rmbLocalized(.launchAtLoginRetryButton)) {
                        launchAtLoginCoordinator.refreshStatus()
                    }
                }
            }

            SettingsDivider()

            SettingsSection(rmbLocalized(.appColorSchemeSettingsLabel)) {
                Picker(String(""), selection: $userPreferences.rmbColorScheme) {
                    Text(RmbColorScheme.system.title).tag(RmbColorScheme.system)
                    Divider()
                    Text(RmbColorScheme.light.title).tag(RmbColorScheme.light)
                    Text(RmbColorScheme.dark.title).tag(RmbColorScheme.dark)
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Toggle(
                    rmbLocalized(.appAppearanceReduceTransparencyOption),
                    isOn: Binding(
                        get: { !userPreferences.preferTransparentBackground || userPreferences.reduceTransparency },
                        set: { userPreferences.preferTransparentBackground = !$0 }
                    )
                )
                .disabled(userPreferences.reduceTransparency)
            }

            SettingsDivider()

            SettingsSection(rmbLocalized(.popoverSizeSettingsLabel)) {
                Button(action: {
                    let defaultSize = MainPopoverSizing.defaultSize
                    AppDelegate.shared.setMainPopoverSize(size: defaultSize, persist: true)
                }) {
                    Text(rmbLocalized(.popoverSizeResetToDefaultButton))
                }
            }

            SettingsDivider()

            SettingsSection(rmbLocalized(.preferredLanguageSettingsLabel)) {
                Picker(String(""), selection: Binding(
                    get: { userPreferences.preferredLanguage ?? "" },
                    set: { newValue in
                        userPreferences.preferredLanguage = newValue.isEmpty ? nil : newValue
                    }
                )) {
                    Text(rmbLocalized(.preferredLanguageSystemSettingsOption))
                        .tag("")
                    Divider()
                    ForEach(rmbAvailableLocales(), id: \.identifier) { locale in
                        Text(locale.name)
                            .tag(locale.identifier)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            SettingsSection(rmbLocalized(.timeFormatSettingsLabel)) {
                Picker(String(""), selection: $userPreferences.timeFormatIs24Hour) {
                    Text(rmbLocalized(.timeFormat12HourOption)).tag(false)
                    Text(rmbLocalized(.timeFormat24HourOption)).tag(true)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
        .padding(20)
        .onAppear {
            launchAtLoginCoordinator.start()
            launchAtLoginCoordinator.refreshStatus()
        }
    }
}

#Preview {
    GeneralSettingsTab()
}
