import XCTest
@testable import Reminders_MenuBar

final class ReminderSearchEngineTests: XCTestCase {
    func testMultiTermQueryCanMatchAcrossEverySupportedField() {
        let records = [
            searchRecord(
                "all-fields",
                title: "Alpha title",
                notes: "Bravo notes",
                url: "https://example.com/charlie",
                calendarTitle: "Delta List",
                tags: ["Echo Tag"],
                isCompleted: true
            ),
            searchRecord(
                "missing-tag-term",
                title: "Alpha title",
                notes: "Bravo notes",
                url: "https://example.com/charlie",
                calendarTitle: "Delta List",
                isCompleted: true
            )
        ]

        let results = ReminderSearchEngine.search(
            matching: "alpha bravo charlie delta echo",
            in: records
        )

        XCTAssertEqual(results, ["all-fields"])
    }

    func testEachSupportedFieldIsIndividuallySearchableAndCompletedItemsRemainIncluded() {
        let records = [
            searchRecord("title", title: "titleterm", isCompleted: true),
            searchRecord("notes", notes: "notesterm", isCompleted: true),
            searchRecord("url", url: "https://urlterm.example", isCompleted: true),
            searchRecord("list", calendarTitle: "listterm", isCompleted: true),
            searchRecord("tag", tags: ["tagterm"], isCompleted: true)
        ]

        XCTAssertEqual(ReminderSearchEngine.search(matching: "titleterm", in: records), ["title"])
        XCTAssertEqual(ReminderSearchEngine.search(matching: "notesterm", in: records), ["notes"])
        XCTAssertEqual(ReminderSearchEngine.search(matching: "urlterm", in: records), ["url"])
        XCTAssertEqual(ReminderSearchEngine.search(matching: "listterm", in: records), ["list"])
        XCTAssertEqual(ReminderSearchEngine.search(matching: "tagterm", in: records), ["tag"])
    }

    func testMatchingFoldsCaseAndDiacritics() {
        let records = [
            searchRecord(
                "folded",
                title: "CAFÉ Planning",
                notes: "Send the RÉSUMÉ",
                calendarTitle: "Équipe"
            )
        ]

        XCTAssertEqual(
            ReminderSearchEngine.search(matching: "cafe resume equipe", in: records),
            ["folded"]
        )
    }

    func testTitleNotesAndURLWeightingMetadataWeightAndIncompleteBoostArePreserved() {
        let fieldWeightRecords = [
            searchRecord("title", title: "zzz target", isCompleted: true),
            searchRecord("notes", title: "aaa", notes: "target", isCompleted: true),
            searchRecord("url", title: "ccc", url: "https://target.example", isCompleted: true),
            searchRecord("list", title: "bbb", calendarTitle: "target", isCompleted: true),
            searchRecord("tag", title: "ddd", tags: ["target"], isCompleted: true)
        ]

        XCTAssertEqual(
            ReminderSearchEngine.search(matching: "target", in: fieldWeightRecords),
            ["title", "notes", "list", "url", "tag"]
        )

        let completionRecords = [
            searchRecord("completed", title: "aaa target", isCompleted: true),
            searchRecord("incomplete", title: "zzz target", isCompleted: false)
        ]
        XCTAssertEqual(
            ReminderSearchEngine.search(matching: "target", in: completionRecords),
            ["incomplete", "completed"]
        )
    }

    func testEqualScoresAreOrderedByNormalizedTitleThenIdentifierForShuffledInput() {
        let records = [
            searchRecord("b", title: "Alpha", notes: "target", isCompleted: true),
            searchRecord("a", title: "Álpha", notes: "target", isCompleted: true),
            searchRecord("z", title: "Zulu", notes: "target", isCompleted: true)
        ]
        let expected = ["a", "b", "z"]

        XCTAssertEqual(ReminderSearchEngine.search(matching: "target", in: records), expected)
        XCTAssertEqual(
            ReminderSearchEngine.search(matching: "target", in: Array(records.reversed())),
            expected
        )
        for _ in 0..<20 {
            XCTAssertEqual(
                ReminderSearchEngine.search(matching: "target", in: records.shuffled()),
                expected
            )
        }
    }

    func testWhitespaceOnlyQueryIsNotAQuery() {
        XCTAssertFalse(ReminderSearchEngine.hasQuery(" \t\n "))
        XCTAssertEqual(
            ReminderSearchEngine.search(
                matching: " \t\n ",
                in: [searchRecord("item", title: "anything")]
            ),
            []
        )
    }

    func testUnavailableTagPathOmitsTagsWithoutCallingProvider() {
        var providerWasCalled = false
        let tags = ReminderSearchTagReader(isAvailable: false).read {
            providerWasCalled = true
            return ["private-api-tag"]
        }

        XCTAssertEqual(tags, [])
        XCTAssertFalse(providerWasCalled)

        let availableTags = ReminderSearchTagReader(isAvailable: true).read {
            return ["available-tag"]
        }
        XCTAssertEqual(availableTags, ["available-tag"])
    }
}
