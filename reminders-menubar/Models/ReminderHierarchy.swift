import Foundation

/// The EventKit-independent description needed to reconstruct one reminder's position.
struct ReminderHierarchyRecord<Value> {
    let value: Value
    let identifier: String
    let parentIdentifier: String?
    let calendarIdentifier: String
}

/// A reminder in an acyclic display tree. Depth zero is a calendar-list root.
struct ReminderHierarchyNode<Value> {
    let record: ReminderHierarchyRecord<Value>
    let depth: Int
    let children: [ReminderHierarchyNode<Value>]

    var value: Value {
        return record.value
    }

    var identifier: String {
        return record.identifier
    }

    var hasChildren: Bool {
        return !children.isEmpty
    }
}

private struct ReminderHierarchyKey: Hashable, Comparable {
    let calendarIdentifier: String
    let reminderIdentifier: String

    static func < (lhs: ReminderHierarchyKey, rhs: ReminderHierarchyKey) -> Bool {
        if lhs.calendarIdentifier != rhs.calendarIdentifier {
            return lhs.calendarIdentifier < rhs.calendarIdentifier
        }
        return lhs.reminderIdentifier < rhs.reminderIdentifier
    }
}

/// Builds a forest from parent links while retaining malformed and partially fetched records.
enum ReminderHierarchyBuilder {
    typealias SiblingComparator<Value> = (
        ReminderHierarchyRecord<Value>,
        ReminderHierarchyRecord<Value>
    ) -> Bool

    static func build<Value>(
        from records: [ReminderHierarchyRecord<Value>],
        siblingAreInIncreasingOrder: SiblingComparator<Value>? = nil
    ) -> [ReminderHierarchyNode<Value>] {
        guard !records.isEmpty else { return [] }

        let indicesByKey = Dictionary(grouping: records.indices) { index in
            key(for: records[index])
        }

        // Parent identifiers are only resolved inside the child's calendar. Ambiguous duplicate
        // identifiers are treated like missing parents so every fetched record remains visible.
        var parentByChildIndex: [Int: Int] = [:]
        for childIndex in records.indices {
            guard let parentIdentifier = records[childIndex].parentIdentifier else { continue }
            let parentKey = ReminderHierarchyKey(
                calendarIdentifier: records[childIndex].calendarIdentifier,
                reminderIdentifier: parentIdentifier
            )
            guard let parentIndices = indicesByKey[parentKey], parentIndices.count == 1,
                  let parentIndex = parentIndices.first else {
                continue
            }
            parentByChildIndex[childIndex] = parentIndex
        }

        breakCycles(
            in: &parentByChildIndex,
            records: records
        )

        var childIndicesByParent: [Int: [Int]] = [:]
        var rootIndices: [Int] = []
        for index in records.indices {
            if let parentIndex = parentByChildIndex[index] {
                childIndicesByParent[parentIndex, default: []].append(index)
            } else {
                rootIndices.append(index)
            }
        }

        func sortedSiblingIndices(_ indices: [Int]) -> [Int] {
            guard let siblingAreInIncreasingOrder else { return indices }
            return indices.sorted { lhsIndex, rhsIndex in
                let lhs = records[lhsIndex]
                let rhs = records[rhsIndex]
                let lhsBeforeRhs = siblingAreInIncreasingOrder(lhs, rhs)
                let rhsBeforeLhs = siblingAreInIncreasingOrder(rhs, lhs)
                if lhsBeforeRhs != rhsBeforeLhs {
                    return lhsBeforeRhs
                }

                // Make comparator ties independent of EventKit fetch order.
                let lhsKey = key(for: lhs)
                let rhsKey = key(for: rhs)
                if lhsKey != rhsKey {
                    return lhsKey < rhsKey
                }
                return lhsIndex < rhsIndex
            }
        }

        func makeNode(at index: Int, depth: Int) -> ReminderHierarchyNode<Value> {
            let children = sortedSiblingIndices(childIndicesByParent[index, default: []]).map {
                makeNode(at: $0, depth: depth + 1)
            }
            return ReminderHierarchyNode(
                record: records[index],
                depth: depth,
                children: children
            )
        }

        return sortedSiblingIndices(rootIndices).map {
            makeNode(at: $0, depth: 0)
        }
    }

    private static func key<Value>(
        for record: ReminderHierarchyRecord<Value>
    ) -> ReminderHierarchyKey {
        return ReminderHierarchyKey(
            calendarIdentifier: record.calendarIdentifier,
            reminderIdentifier: record.identifier
        )
    }

    /// Every node has at most one parent, so each malformed component can contain at most one
    /// cycle. Removing the parent edge from the lexicographically smallest cycle member gives a
    /// deterministic root without discarding any records or descendants.
    private static func breakCycles<Value>(
        in parentByChildIndex: inout [Int: Int],
        records: [ReminderHierarchyRecord<Value>]
    ) {
        var processedIndices: Set<Int> = []

        for startIndex in records.indices where !processedIndices.contains(startIndex) {
            var path: [Int] = []
            var positionInPath: [Int: Int] = [:]
            var currentIndex: Int? = startIndex

            while let index = currentIndex, !processedIndices.contains(index) {
                if let cycleStart = positionInPath[index] {
                    let cycleIndices = Array(path[cycleStart...])
                    let rootIndex = cycleIndices.min { lhsIndex, rhsIndex in
                        let lhsKey = key(for: records[lhsIndex])
                        let rhsKey = key(for: records[rhsIndex])
                        if lhsKey != rhsKey {
                            return lhsKey < rhsKey
                        }
                        return lhsIndex < rhsIndex
                    }
                    if let rootIndex {
                        parentByChildIndex[rootIndex] = nil
                    }
                    break
                }

                positionInPath[index] = path.count
                path.append(index)
                currentIndex = parentByChildIndex[index]
            }

            processedIndices.formUnion(path)
        }
    }
}

enum ReminderHierarchyLayout {
    static let indentationPerLevel: CGFloat = 22

    static func leadingIndentation(forDepth depth: Int) -> CGFloat {
        return CGFloat(max(0, depth)) * indentationPerLevel
    }
}
