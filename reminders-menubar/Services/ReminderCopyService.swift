import AppKit
import EventKit

protocol ReminderClipboardWriting {
    func writeString(_ string: String) -> Bool
}

struct SystemReminderClipboard: ReminderClipboardWriting {
    static let shared = SystemReminderClipboard()

    func writeString(_ string: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let item = NSPasteboardItem()
        guard item.setString(string, forType: .string) else { return false }

        // Preserve a best-effort snapshot so an unexpected pasteboard rejection does
        // not destroy the user's previous clipboard contents.
        let previousItems = snapshot(items: pasteboard.pasteboardItems)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                _ = pasteboard.writeObjects(previousItems)
            }
            return false
        }
        return true
    }

    private func snapshot(items: [NSPasteboardItem]?) -> [NSPasteboardItem] {
        return (items ?? []).compactMap { source in
            let copy = NSPasteboardItem()
            var copiedAtLeastOneType = false
            for type in source.types {
                guard let data = source.data(forType: type),
                      copy.setData(data, forType: type) else {
                    continue
                }
                copiedAtLeastOneType = true
            }
            return copiedAtLeastOneType ? copy : nil
        }
    }
}

enum ReminderCopyService {
    @discardableResult
    static func copyReminder(
        _ reminder: EKReminder,
        clipboard: ReminderClipboardWriting = SystemReminderClipboard.shared
    ) -> Bool {
        return copy(
            options: UserPreferences.shared.copyPropertyOptions,
            variables: buildVariables(from: reminder),
            includePropertyNames: UserPreferences.shared.copyIncludePropertyNames,
            clipboard: clipboard
        )
    }

    @discardableResult
    static func copy(
        options: [CopyPropertyOption],
        variables: [CopyProperty: String],
        includePropertyNames: Bool,
        clipboard: ReminderClipboardWriting
    ) -> Bool {
        let text = buildFormattedText(
            options: options,
            variables: variables,
            includePropertyNames: includePropertyNames
        )

        guard !text.isEmpty else { return false }
        return clipboard.writeString(text)
    }

    static func previewText(options: [CopyPropertyOption], includePropertyNames: Bool) -> String {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let sampleDate = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow) ?? tomorrow

        let sampleVariables: [CopyProperty: String] = [
            .title: rmbLocalized(.copySampleTitle),
            .notes: rmbLocalized(.copySampleNotes),
            .date: sampleDate.absoluteDateDescription(withTime: true),
            .priority: priorityLabel(for: .high),
            .list: rmbLocalized(.copySampleList),
            .url: "https://example.com/recipe"
        ]

        return buildFormattedText(
            options: options,
            variables: sampleVariables,
            includePropertyNames: includePropertyNames
        )
    }

    static func buildFormattedText(
        options: [CopyPropertyOption],
        variables: [CopyProperty: String],
        includePropertyNames: Bool
    ) -> String {
        return options
            .filter(\.isEnabled)
            .compactMap { option -> String? in
                guard let value = variables[option.property], !value.isEmpty else {
                    return nil
                }
                if includePropertyNames {
                    return "\(option.property.displayName): \(value)"
                }
                return value
            }
            .joined(separator: "\n")
    }

    private static func buildVariables(from reminder: EKReminder) -> [CopyProperty: String] {
        return [
            .title: reminder.title ?? "",
            .notes: reminder.notes ?? "",
            .date: reminder.dueDateComponents?.date?.absoluteDateDescription(withTime: reminder.hasTime) ?? "",
            .priority: priorityLabel(for: reminder.ekPriority),
            .list: reminder.calendar?.title ?? "",
            .url: reminder.attachedUrl?.absoluteString ?? ""
        ]
    }

    private static func priorityLabel(for priority: EKReminderPriority) -> String {
        if priority == .none {
            return ""
        }
        return priority.title
    }
}
