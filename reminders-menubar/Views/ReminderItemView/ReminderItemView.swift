import SwiftUI
import EventKit
import Combine

@MainActor
struct ReminderItemView: View {
    @EnvironmentObject private var copyCoordinator: CopyShortcutCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appHasPopoverOpen) private var appHasPopoverOpen
    @ObservedObject private var userPreferences = UserPreferences.shared

    var reminderItem: ReminderItem
    var showCalendarTitle = false

    @State private var reminderItemIsHovered = false
    @State private var showingEditPopover = false
    @State private var showingRemoveAlert = false
    @State private var showingCopiedToast = false
    @State private var isPendingCompletion = false
    @State private var dateInvalidation = Date()
    @State private var dueDateExpirationCancellable: AnyCancellable?
    @State private var copiedToastDismissWork: DispatchWorkItem?
    @State private var copyRegistration: CopyShortcutCoordinator.HoverRegistration?
    @State private var copySuspensionId = UUID()

    var body: some View {
        if reminderItem.reminder.calendar == nil {
            // On macOS 12 the calendar may be nil during delete operation.
            // Returning Empty to avoid issues since calendar is a force unwrap.
            EmptyView()
        } else {
            mainReminderItemView()
        }
    }

    @ViewBuilder
    private func mainReminderItemView() -> some View {
        HStack(alignment: .top) {
            ReminderCompleteButton(reminderItem: reminderItem, isPendingCompletion: $isPendingCompletion)

            VStack(spacing: 4) {
                reminderTitleRow()

                if #available(macOS 12, *), !reminderItem.reminder.ekTags.isEmpty {
                    ReminderTagsView(tags: reminderItem.reminder.ekTags)
                }

                let hasDueDate = reminderItem.reminder.relativeDateDescription != nil
                let shouldShowExternalLinks = userPreferences.showExternalLinksInReminderItem
                    && (reminderItem.reminder.attachedUrl != nil || reminderItem.reminder.mailUrl != nil)

                if let dateDescription = reminderItem.reminder.relativeDateDescription {
                    HStack(alignment: .bottom) {
                        ReminderDateDescriptionView(
                            dateDescription: dateDescription,
                            isExpired: reminderItem.reminder.isExpired,
                            hasRecurrenceRules: reminderItem.reminder.hasRecurrenceRules,
                            recurrenceRules: reminderItem.reminder.recurrenceRules
                        )
                        .id(dateInvalidation)

                        if showCalendarTitle {
                            calendarTitleText()
                        }
                    }
                    .padding(.trailing, 8)
                }

                if shouldShowExternalLinks {
                    HStack(alignment: .bottom) {
                        ReminderExternalLinksView(
                            attachedUrl: reminderItem.reminder.attachedUrl,
                            mailUrl: reminderItem.reminder.mailUrl,
                            isCompact: true
                        )

                        if showCalendarTitle && !hasDueDate {
                            calendarTitleText()
                        }
                    }
                    .padding(.trailing, 8)
                }

                if showCalendarTitle && !hasDueDate && !shouldShowExternalLinks {
                    HStack {
                        Spacer()

                        calendarTitleText()
                    }
                    .padding(.trailing, 8)
                }

                Divider()
                    .padding(.top, 2)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isPendingCompletion || reminderItem.reminder.isCompleted ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: isPendingCompletion)
            .allowsHitTesting(!isPendingCompletion && !appHasPopoverOpen.wrappedValue)
            .onTapGesture {
                showingEditPopover = true
            }
            .overlay(
                copiedToastOverlay()
                    .opacity(showingCopiedToast ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: showingCopiedToast)
            )
        }
        .onHover { isHovered in
            reminderItemIsHovered = isHovered
            if isHovered {
                copyCoordinator.setHovered(registerCopyAction())
            } else if let copyRegistration {
                copyCoordinator.clearIfCurrent(copyRegistration)
            }
        }
        .onDisappear {
            copiedToastDismissWork?.cancel()
            showingCopiedToast = false
            copyCoordinator.setSurfacePresented(false, id: copySuspensionId)
            if let copyRegistration {
                copyCoordinator.unregisterCopyAction(copyRegistration)
                self.copyRegistration = nil
            }
        }
        .padding(.bottom, 2)
        .padding(
            .leading,
            ReminderHierarchyLayout.leadingIndentation(forDepth: reminderItem.depth)
        )
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            dateInvalidation = Date()
        }
        .onAppear {
            subscribeToDueDateExpiration()
            _ = registerCopyAction()
        }
        .onChange(of: reminderItem) { _ in
            subscribeToDueDateExpiration()
            updateRegisteredCopyAction()
        }
        .onChange(of: showingEditPopover) { isOpen in
            appHasPopoverOpen.wrappedValue = isOpen
            copyCoordinator.setSurfacePresented(isOpen, id: copySuspensionId)
        }

        ForEach(reminderItem.childReminders) { reminderItem in
            ReminderItemView(reminderItem: reminderItem)
        }
    }

    private func reminderTitleText() -> Text {
        let titleText = Text(LocalizedStringKey(reminderItem.reminder.title.toDetectedLinkAttributedString()))

        guard let prioritySystemImage = reminderItem.reminder.ekPriority.systemImage else {
            return titleText
        }

        return Text(Image(systemName: prioritySystemImage))
            .foregroundColor(Color(reminderItem.reminder.calendar.color))
        + Text(verbatim: " ")
        + titleText
    }

    @ViewBuilder
    private func reminderTitleRow() -> some View {
        HStack(spacing: 4) {
            reminderTitleText()
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            ReminderEllipsisMenuView(
                showingEditPopover: $showingEditPopover,
                showingRemoveAlert: $showingRemoveAlert,
                onCopyReminder: { copyReminderToClipboard() },
                reminder: reminderItem.reminder,
                reminderHasChildren: reminderItem.hasChildren
            )
            .opacity(shouldShowEllipsisButton() ? 1 : 0)
            .popover(isPresented: $showingEditPopover, arrowEdge: .trailing) {
                ReminderEditView(
                    isPresented: $showingEditPopover,
                    reminder: reminderItem.reminder,
                    reminderHasChildren: reminderItem.hasChildren
                )
            }
        }
        .alert(isPresented: $showingRemoveAlert) {
            removeReminderAlert(for: reminderItem.reminder)
        }
    }

    @ViewBuilder
    private func calendarTitleText() -> some View {
        Text(reminderItem.reminder.calendar.title)
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize()
    }

    private func subscribeToDueDateExpiration() {
        dueDateExpirationCancellable?.cancel()
        guard reminderItem.reminder.hasTime,
              let dueDate = reminderItem.reminder.dueDateComponents?.date,
              dueDate.timeIntervalSinceNow > 0 else {
            return
        }

        dueDateExpirationCancellable = Just(())
            .delay(for: .seconds(dueDate.timeIntervalSinceNow), scheduler: RunLoop.main)
            .sink { _ in
                dateInvalidation = Date()
            }
    }

    private func shouldShowEllipsisButton() -> Bool {
        let hoverWithNoPopoverOpen = reminderItemIsHovered && !appHasPopoverOpen.wrappedValue
        return !isPendingCompletion && (hoverWithNoPopoverOpen || showingEditPopover)
    }

    private func registerCopyAction() -> CopyShortcutCoordinator.HoverRegistration {
        if let copyRegistration {
            return copyRegistration
        }
        let registration = copyCoordinator.registerCopyAction(reminderId: reminderItem.id) {
            copyReminderToClipboard()
        }
        copyRegistration = registration
        return registration
    }

    private func updateRegisteredCopyAction() {
        guard let copyRegistration else { return }
        copyCoordinator.updateCopyAction(copyRegistration) {
            copyReminderToClipboard()
        }
    }

    @discardableResult
    private func copyReminderToClipboard() -> Bool {
        guard !isPendingCompletion,
              !showingEditPopover,
              !appHasPopoverOpen.wrappedValue,
              ReminderCopyService.copyReminder(reminderItem.reminder) else {
            return false
        }
        showingCopiedToast = true

        copiedToastDismissWork?.cancel()
        let work = DispatchWorkItem { showingCopiedToast = false }
        copiedToastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        return true
    }

    @ViewBuilder
    private func copiedToastOverlay() -> some View {
        GeometryReader { geometry in
            Text(rmbLocalized(.copiedToastMessage))
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, 32)
                .frame(maxHeight: min(32, geometry.size.height - 4))
                .background(
                    Capsule()
                        .fill(colorScheme == .light ? Color.white : Color.black)
                        .overlay(Capsule().stroke(Color.gray.opacity(0.2)))
                        .opacity(0.9)
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

#Preview {
    var reminder: EKReminder {
        let calendar = EKCalendar(for: .reminder, eventStore: .init())
        calendar.color = .systemTeal

        let reminder = EKReminder(eventStore: .init())
        reminder.title = "Look for awesome projects on GitHub"
        reminder.isCompleted = false
        reminder.calendar = calendar
        reminder.addDueDateAndAlarm(for: Date().addingTimeInterval(86_400), withTime: false)

        return reminder
    }
    let reminderItem = ReminderItem(for: reminder)

    ReminderItemView(reminderItem: reminderItem)
        .environmentObject(CopyShortcutCoordinator())
}
