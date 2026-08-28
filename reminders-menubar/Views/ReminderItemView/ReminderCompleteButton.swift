import SwiftUI
import EventKit

@MainActor
struct ReminderCompleteButton: View {
    var reminderItem: ReminderItem
    @Binding var isPendingCompletion: Bool

    @StateObject private var completionCoordinator: ReminderCompletionCoordinator<ReminderItem, String>

    private static let completionDelayInSeconds: Double = 1.5

    private var isShowingFilled: Bool {
        reminderItem.reminder.isCompleted || completionCoordinator.isFilled
    }

    init(reminderItem: ReminderItem, isPendingCompletion: Binding<Bool>) {
        self.reminderItem = reminderItem
        self._isPendingCompletion = isPendingCompletion
        self._completionCoordinator = StateObject(
            wrappedValue: ReminderCompletionCoordinator(
                completionDelayInSeconds: Self.completionDelayInSeconds,
                scheduler: TaskReminderCompletionScheduler(),
                identifier: { $0.id },
                children: { $0.childReminders },
                isCompleted: { $0.reminder.isCompleted },
                setCompleted: { $0.reminder.isCompleted = $1 },
                persist: { RemindersService.shared.save(reminder: $0.reminder) }
            )
        )
    }

    var body: some View {
        Button(action: {
            withAnimation(.easeOut(duration: 0.25)) {
                completionCoordinator.handleTap(on: reminderItem)
            }
        }) {
            Image(systemName: isShowingFilled ? "largecircle.fill.circle" : "circle")
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundColor(Color(reminderItem.reminder.calendar.color))
                .transition(.scale(scale: 0.1).combined(with: .opacity))
                .id(isShowingFilled)
                .padding(.top, 2)
        }
        .buttonStyle(.plain)
        .onAppear {
            isPendingCompletion = completionCoordinator.isPending
        }
        .onChange(of: completionCoordinator.isPending) { isPending in
            isPendingCompletion = isPending
        }
        .onDisappear {
            // The old behavior commits a pending completion when its row is removed externally.
            completionCoordinator.completePendingImmediately()
        }
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

        return reminder
    }
    let reminderItem = ReminderItem(for: reminder)

    VStack {
        ReminderCompleteButton(reminderItem: reminderItem, isPendingCompletion: .constant(false))

        ReminderCompleteButton(reminderItem: reminderItem, isPendingCompletion: .constant(true))
    }
    .frame(width: 100)
}
