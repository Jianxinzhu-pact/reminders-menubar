import EventKit

struct ReminderItem: Identifiable, Equatable {
    let id: String
    let reminder: EKReminder
    let lastModifiedDate: Date?
    let childReminders: [ReminderItem]
    let depth: Int

    var isChild: Bool {
        return depth > 0
    }

    var hasChildren: Bool {
        return !childReminders.isEmpty
    }
    
    init(for reminder: EKReminder, depth: Int = 0, withChildren childReminders: [ReminderItem] = []) {
        self.id = reminder.calendarItemIdentifier
        self.reminder = reminder
        self.lastModifiedDate = reminder.lastModifiedDate
        self.childReminders = childReminders.sortedReminders
        self.depth = depth
    }
    
    static func == (lhs: ReminderItem, rhs: ReminderItem) -> Bool {
        return (
            lhs.id == rhs.id
            && lhs.lastModifiedDate == rhs.lastModifiedDate
            && lhs.depth == rhs.depth
            && lhs.childReminders == rhs.childReminders
        )
    }
}
