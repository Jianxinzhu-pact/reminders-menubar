import Foundation

struct ReminderSearchMetadata: Equatable {
    let calendarItemIdentifier: String
    let title: String
    let notes: String
    let url: String
    let calendarTitle: String
    let tags: [String]
    let isCompleted: Bool
}

struct ReminderSearchRecord<Item> {
    let item: Item
    let metadata: ReminderSearchMetadata
}

enum ReminderSearchEngine {
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    static func hasQuery(_ query: String) -> Bool {
        return !normalizedTerms(in: query).isEmpty
    }

    static func search<Item>(
        matching query: String,
        in records: [ReminderSearchRecord<Item>]
    ) -> [Item] {
        let queryTerms = normalizedTerms(in: query)
        guard !queryTerms.isEmpty else { return [] }

        let scoredRecords = records.compactMap { record -> (
            record: ReminderSearchRecord<Item>,
            score: Int,
            normalizedTitle: String,
            identifier: String
        )? in
            let metadata = record.metadata
            let title = normalize(metadata.title)
            let notes = normalize(metadata.notes)
            let url = normalize(metadata.url)
            let calendarTitle = normalize(metadata.calendarTitle)
            let tags = metadata.tags.map(normalize)
            let allFields = [title, notes, url, calendarTitle] + tags

            guard queryTerms.allSatisfy({ term in
                allFields.contains(where: { $0.contains(term) })
            }) else {
                return nil
            }

            var score = 0
            for term in queryTerms {
                if title.contains(term) { score += 3 }
                if notes.contains(term) { score += 2 }
                if url.contains(term) { score += 1 }
                if calendarTitle.contains(term) { score += 1 }
                if tags.contains(where: { $0.contains(term) }) { score += 1 }
            }
            if !metadata.isCompleted { score += 1 }

            return (
                record: record,
                score: score,
                normalizedTitle: title,
                identifier: metadata.calendarItemIdentifier
            )
        }

        return scoredRecords
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.normalizedTitle != rhs.normalizedTitle {
                    return lhs.normalizedTitle < rhs.normalizedTitle
                }
                return lhs.identifier < rhs.identifier
            }
            .map { $0.record.item }
    }

    private static func normalizedTerms(in query: String) -> [String] {
        return query
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        return value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: normalizationLocale
            )
            .lowercased(with: normalizationLocale)
    }
}

@MainActor
protocol ReminderSearchDebouncing: AnyObject {
    func schedule(_ action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class TaskReminderSearchDebouncer: ReminderSearchDebouncing {
    private let delayNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    deinit {
        task?.cancel()
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        cancel()
        let delayNanoseconds = delayNanoseconds
        task = Task { @MainActor in
            if delayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: delayNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

struct ReminderSearchState<Item> {
    let results: [Item]?
    let isInitialLoading: Bool
}

/// Owns one search session at a time and rejects responses from older sessions or refreshes.
@MainActor
final class ReminderSearchCoordinator<Item> {
    private let fetchSnapshot: @MainActor () async -> [ReminderSearchRecord<Item>]
    private let notificationCenter: NotificationCenter
    private let notificationName: Notification.Name
    private let storeChangeDebouncer: ReminderSearchDebouncing

    private var storeChangeObserver: NSObjectProtocol?
    private var snapshot: [ReminderSearchRecord<Item>]?
    private var fetchTasks: [UInt: Task<Void, Never>] = [:]
    private var sessionIdentifier: UInt = 0
    private var nextRequestIdentifier: UInt = 0
    private var latestRequestIdentifier: UInt?

    private(set) var isOpen = false
    private(set) var query = ""
    private(set) var results: [Item]?
    private(set) var isInitialLoading = false

    var stateDidChange: (@MainActor (ReminderSearchState<Item>) -> Void)? {
        didSet {
            publishState()
        }
    }

    init(
        fetchSnapshot: @escaping @MainActor () async -> [ReminderSearchRecord<Item>],
        notificationCenter: NotificationCenter,
        notificationName: Notification.Name,
        storeChangeDebouncer: ReminderSearchDebouncing
    ) {
        self.fetchSnapshot = fetchSnapshot
        self.notificationCenter = notificationCenter
        self.notificationName = notificationName
        self.storeChangeDebouncer = storeChangeDebouncer
    }

    deinit {
        if let storeChangeObserver {
            notificationCenter.removeObserver(storeChangeObserver)
        }
        for task in fetchTasks.values {
            task.cancel()
        }
    }

    func open(with query: String = "") {
        guard !isOpen else {
            updateQuery(query)
            return
        }

        isOpen = true
        sessionIdentifier &+= 1
        snapshot = nil
        self.query = query
        results = nil
        isInitialLoading = ReminderSearchEngine.hasQuery(query)
        publishState()

        observeStoreChanges(for: sessionIdentifier)
        startFetch(for: sessionIdentifier)
    }

    func close() {
        guard isOpen else { return }

        isOpen = false
        sessionIdentifier &+= 1
        latestRequestIdentifier = nil
        query = ""
        snapshot = nil
        results = nil
        isInitialLoading = false

        stopObservingStoreChanges()
        storeChangeDebouncer.cancel()
        for task in fetchTasks.values {
            task.cancel()
        }
        fetchTasks.removeAll()
        publishState()
    }

    func updateQuery(_ query: String) {
        guard isOpen else { return }
        self.query = query
        applyCurrentQuery()
    }

    private func observeStoreChanges(for sessionIdentifier: UInt) {
        stopObservingStoreChanges()
        storeChangeObserver = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.storeDidChange(in: sessionIdentifier)
            }
        }
    }

    private func stopObservingStoreChanges() {
        if let storeChangeObserver {
            notificationCenter.removeObserver(storeChangeObserver)
            self.storeChangeObserver = nil
        }
    }

    private func storeDidChange(in sessionIdentifier: UInt) {
        guard isOpen, self.sessionIdentifier == sessionIdentifier else { return }

        storeChangeDebouncer.schedule { [weak self] in
            guard let self,
                  self.isOpen,
                  self.sessionIdentifier == sessionIdentifier else {
                return
            }
            self.startFetch(for: sessionIdentifier)
        }
    }

    private func startFetch(for sessionIdentifier: UInt) {
        guard isOpen, self.sessionIdentifier == sessionIdentifier else { return }

        nextRequestIdentifier &+= 1
        let requestIdentifier = nextRequestIdentifier
        latestRequestIdentifier = requestIdentifier
        let fetchSnapshot = fetchSnapshot

        fetchTasks[requestIdentifier] = Task { @MainActor [weak self] in
            let fetchedSnapshot = await fetchSnapshot()
            self?.finishFetch(
                fetchedSnapshot,
                sessionIdentifier: sessionIdentifier,
                requestIdentifier: requestIdentifier
            )
        }
    }

    private func finishFetch(
        _ fetchedSnapshot: [ReminderSearchRecord<Item>],
        sessionIdentifier: UInt,
        requestIdentifier: UInt
    ) {
        fetchTasks[requestIdentifier] = nil
        guard isOpen,
              self.sessionIdentifier == sessionIdentifier,
              latestRequestIdentifier == requestIdentifier else {
            return
        }

        snapshot = fetchedSnapshot
        applyCurrentQuery()
    }

    private func applyCurrentQuery() {
        guard ReminderSearchEngine.hasQuery(query) else {
            results = nil
            isInitialLoading = false
            publishState()
            return
        }

        guard let snapshot else {
            results = nil
            isInitialLoading = true
            publishState()
            return
        }

        results = ReminderSearchEngine.search(matching: query, in: snapshot)
        isInitialLoading = false
        publishState()
    }

    private func publishState() {
        stateDidChange?(
            ReminderSearchState(
                results: results,
                isInitialLoading: isInitialLoading
            )
        )
    }
}
