import EventKit

@MainActor
protocol ReminderSearchRepository {
    func fetchSnapshot() async -> [ReminderSearchRecord<ReminderItem>]
}

struct ReminderSearchTagReader {
    let isAvailable: Bool

    func read(_ provider: () -> [String]) -> [String] {
        guard isAvailable else { return [] }
        return provider()
    }
}

@MainActor
final class EventKitReminderSearchRepository: ReminderSearchRepository {
    private let remindersService: RemindersService

    init(remindersService: RemindersService = .shared) {
        self.remindersService = remindersService
    }

    func fetchSnapshot() async -> [ReminderSearchRecord<ReminderItem>] {
        let reminders = await remindersService.fetchAllReminders()
        return reminders.map { reminder in
            ReminderSearchRecord(
                item: ReminderItem(for: reminder),
                metadata: ReminderSearchMetadata(
                    calendarItemIdentifier: reminder.calendarItemIdentifier,
                    title: reminder.title ?? "",
                    notes: reminder.notes ?? "",
                    url: reminder.attachedUrl?.absoluteString ?? "",
                    calendarTitle: reminder.calendar?.title ?? "",
                    tags: tags(for: reminder),
                    isCompleted: reminder.isCompleted
                )
            )
        }
    }

    private func tags(for reminder: EKReminder) -> [String] {
        if #available(macOS 12, *) {
            return ReminderSearchTagReader(isAvailable: true).read {
                reminder.ekTags
            }
        }
        return ReminderSearchTagReader(isAvailable: false).read { [] }
    }
}
