import XCTest
@testable import Reminders_MenuBar

final class ReminderHierarchyTests: XCTestCase {
    func testShuffledFiveLevelHierarchyRetainsEveryRecordAtCorrectDepth() {
        let records = [
            hierarchyRecord("level-3", parent: "level-2"),
            hierarchyRecord("level-1", parent: "root"),
            hierarchyRecord("level-4", parent: "level-3"),
            hierarchyRecord("root"),
            hierarchyRecord("level-2", parent: "level-1")
        ]

        let roots = build(records)
        let nodes = flatten(roots)

        XCTAssertEqual(roots.map(\.identifier), ["root"])
        XCTAssertEqual(nodes.map(\.identifier), ["root", "level-1", "level-2", "level-3", "level-4"])
        XCTAssertEqual(nodes.map(\.depth), [0, 1, 2, 3, 4])
        XCTAssertEqual(Set(nodes.map(\.identifier)).count, records.count)
    }

    func testMissingParentBecomesRootAndRetainsAllDescendants() {
        let roots = build([
            hierarchyRecord("grandchild", parent: "child"),
            hierarchyRecord("unrelated-root"),
            hierarchyRecord("orphan", parent: "not-fetched"),
            hierarchyRecord("child", parent: "orphan")
        ])

        XCTAssertEqual(roots.map(\.identifier), ["orphan", "unrelated-root"])
        let orphan = tryUnwrap(roots.first { $0.identifier == "orphan" })
        XCTAssertEqual(flatten([orphan]).map(\.identifier), ["orphan", "child", "grandchild"])
        XCTAssertEqual(flatten(roots).count, 4)
    }

    func testSelfParentCyclesMultiRecordCyclesAndCrossCalendarLinksAreLossless() {
        let records = [
            hierarchyRecord("self", parent: "self"),
            hierarchyRecord("cycle-c", parent: "cycle-b"),
            hierarchyRecord("cycle-a", parent: "cycle-c"),
            hierarchyRecord("cycle-child", parent: "cycle-c"),
            hierarchyRecord("cycle-b", parent: "cycle-a"),
            hierarchyRecord("shared-parent", calendar: "calendar-a"),
            hierarchyRecord("cross-child", parent: "shared-parent", calendar: "calendar-b"),
            hierarchyRecord("cross-grandchild", parent: "cross-child", calendar: "calendar-b")
        ]

        let roots = build(records)
        let allNodes = flatten(roots)

        XCTAssertEqual(allNodes.count, records.count)
        XCTAssertEqual(Set(allNodes.map(\.identifier)), Set(records.map(\.identifier)))

        let selfParent = tryUnwrap(roots.first { $0.identifier == "self" })
        XCTAssertTrue(selfParent.children.isEmpty)

        // The smallest identifier in the malformed cycle is always selected as its root.
        let cycleRoot = tryUnwrap(roots.first { $0.identifier == "cycle-a" })
        XCTAssertEqual(cycleRoot.children.map(\.identifier), ["cycle-b"])
        XCTAssertEqual(cycleRoot.children.first?.children.map(\.identifier), ["cycle-c"])
        XCTAssertEqual(cycleRoot.children.first?.children.first?.children.map(\.identifier), ["cycle-child"])

        let crossChild = tryUnwrap(roots.first {
            $0.identifier == "cross-child" && $0.record.calendarIdentifier == "calendar-b"
        })
        XCTAssertEqual(crossChild.depth, 0, "A parent in another calendar must be considered missing")
        XCTAssertEqual(crossChild.children.map(\.identifier), ["cross-grandchild"])

        let reversedRoots = build(Array(records.reversed()))
        XCTAssertEqual(structure(of: roots), structure(of: reversedRoots))
    }

    func testRootAndNestedSiblingGroupsAreSortedIndependently() {
        let roots = build([
            hierarchyRecord("root-later", order: 20),
            hierarchyRecord("later-child-2", parent: "root-later", order: 2),
            hierarchyRecord("root-first", order: 10),
            hierarchyRecord("later-child-1", parent: "root-later", order: 1),
            hierarchyRecord("first-child-3", parent: "root-first", order: 3),
            hierarchyRecord("nested-2", parent: "later-child-1", order: 2),
            hierarchyRecord("first-child-1", parent: "root-first", order: 1),
            hierarchyRecord("nested-1", parent: "later-child-1", order: 1)
        ])

        XCTAssertEqual(roots.map(\.identifier), ["root-first", "root-later"])
        XCTAssertEqual(roots[0].children.map(\.identifier), ["first-child-1", "first-child-3"])
        XCTAssertEqual(roots[1].children.map(\.identifier), ["later-child-1", "later-child-2"])
        XCTAssertEqual(roots[1].children[0].children.map(\.identifier), ["nested-1", "nested-2"])
    }

    func testIntermediateChildrenAndProgressiveIndentationAreReported() {
        let nodes = flatten(build([
            hierarchyRecord("leaf", parent: "intermediate"),
            hierarchyRecord("root"),
            hierarchyRecord("intermediate", parent: "root")
        ]))

        XCTAssertEqual(nodes.map(\.hasChildren), [true, true, false])
        XCTAssertEqual(
            nodes.map { ReminderHierarchyLayout.leadingIndentation(forDepth: $0.depth) },
            [0, 22, 44]
        )
    }

    private func build(
        _ records: [ReminderHierarchyRecord<HierarchyTestValue>]
    ) -> [ReminderHierarchyNode<HierarchyTestValue>] {
        return ReminderHierarchyBuilder.build(
            from: records,
            siblingAreInIncreasingOrder: { lhs, rhs in
                lhs.value.order < rhs.value.order
            }
        )
    }

    private func flatten(
        _ roots: [ReminderHierarchyNode<HierarchyTestValue>]
    ) -> [ReminderHierarchyNode<HierarchyTestValue>] {
        return roots.flatMap { root in
            [root] + flatten(root.children)
        }
    }

    private func structure(
        of roots: [ReminderHierarchyNode<HierarchyTestValue>]
    ) -> [String] {
        return flatten(roots).map { node in
            let parent = node.record.parentIdentifier ?? "none"
            return "\(node.record.calendarIdentifier):\(node.identifier):\(parent):\(node.depth)"
        }
    }

    private func tryUnwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T {
        guard let value else {
            XCTFail("Expected a value", file: file, line: line)
            fatalError("Expected a value")
        }
        return value
    }
}

private struct HierarchyTestValue {
    let order: Int
}

private func hierarchyRecord(
    _ identifier: String,
    parent: String? = nil,
    calendar: String = "calendar-a",
    order: Int = 0
) -> ReminderHierarchyRecord<HierarchyTestValue> {
    return ReminderHierarchyRecord(
        value: HierarchyTestValue(order: order),
        identifier: identifier,
        parentIdentifier: parent,
        calendarIdentifier: calendar
    )
}
