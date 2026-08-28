import Combine
import Foundation

/// Returns a stable, pre-order subtree and protects persistence from malformed cycles or aliases.
enum ReminderSubtreeTraversal {
    @MainActor
    static func nodes<Node, Identifier: Hashable>(
        startingAt root: Node,
        identifiedBy identifier: @MainActor (Node) -> Identifier,
        children: @MainActor (Node) -> [Node]
    ) -> [Node] {
        var result: [Node] = []
        var visitedIdentifiers: Set<Identifier> = []
        var pendingNodes = [root]

        while let node = pendingNodes.popLast() {
            guard visitedIdentifiers.insert(identifier(node)).inserted else { continue }
            result.append(node)
            pendingNodes.append(contentsOf: children(node).reversed())
        }

        return result
    }
}

@MainActor
protocol ReminderCompletionScheduling: AnyObject {
    func schedule(after delayInSeconds: Double, action: @escaping @MainActor () -> Void)
    func cancel()
}

@MainActor
final class TaskReminderCompletionScheduler: ReminderCompletionScheduling {
    private var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    func schedule(after delayInSeconds: Double, action: @escaping @MainActor () -> Void) {
        cancel()
        let delayInNanoseconds = UInt64(max(0, delayInSeconds) * 1_000_000_000)
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayInNanoseconds)
            } catch {
                return
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

/// Owns the undo window and applies completion to exactly one reminder subtree.
@MainActor
final class ReminderCompletionCoordinator<Node, Identifier: Hashable>: ObservableObject {
    @Published private(set) var isPending = false
    @Published private(set) var isFilled = false

    private let completionDelayInSeconds: Double
    private let scheduler: ReminderCompletionScheduling
    private let identifier: @MainActor (Node) -> Identifier
    private let children: @MainActor (Node) -> [Node]
    private let isCompleted: @MainActor (Node) -> Bool
    private let setCompleted: @MainActor (Node, Bool) -> Void
    private let persist: @MainActor (Node) -> Void

    private var pendingRoot: Node?

    init(
        completionDelayInSeconds: Double,
        scheduler: ReminderCompletionScheduling,
        identifier: @escaping @MainActor (Node) -> Identifier,
        children: @escaping @MainActor (Node) -> [Node],
        isCompleted: @escaping @MainActor (Node) -> Bool,
        setCompleted: @escaping @MainActor (Node, Bool) -> Void,
        persist: @escaping @MainActor (Node) -> Void
    ) {
        self.completionDelayInSeconds = completionDelayInSeconds
        self.scheduler = scheduler
        self.identifier = identifier
        self.children = children
        self.isCompleted = isCompleted
        self.setCompleted = setCompleted
        self.persist = persist
    }

    func handleTap(on root: Node) {
        if isPending {
            cancelPendingCompletion()
        } else if isCompleted(root) {
            // Preserve existing uncompletion semantics: only the selected reminder is changed.
            setCompleted(root, false)
            persist(root)
        } else {
            startPendingCompletion(of: root)
        }
    }

    func cancelPendingCompletion() {
        guard isPending else { return }
        scheduler.cancel()
        pendingRoot = nil
        isFilled = false
        isPending = false
    }

    func completePendingImmediately() {
        guard isPending else { return }
        scheduler.cancel()
        completePendingSubtree()
    }

    private func startPendingCompletion(of root: Node) {
        pendingRoot = root
        isPending = true
        isFilled = true
        scheduler.schedule(after: completionDelayInSeconds) { [weak self] in
            self?.completePendingSubtree()
        }
    }

    private func completePendingSubtree() {
        guard let root = pendingRoot else { return }
        pendingRoot = nil

        let subtree = ReminderSubtreeTraversal.nodes(
            startingAt: root,
            identifiedBy: identifier,
            children: children
        )
        for node in subtree {
            setCompleted(node, true)
            persist(node)
        }

        isFilled = false
        isPending = false
    }
}
