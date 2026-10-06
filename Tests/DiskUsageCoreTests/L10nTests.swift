import XCTest
@testable import DiskUsageCore

final class L10nTests: XCTestCase {
    override func tearDown() {
        L10n.language = .japanese
        super.tearDown()
    }

    func testPreferredLanguageFollowsFirstPreference() {
        XCTAssertEqual(AppLanguage.preferred(["ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.preferred(["ja"]), .japanese)
        XCTAssertEqual(AppLanguage.preferred(["en-US", "ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.preferred(["fr-FR"]), .english, "対応言語がなければ英語にする")
        XCTAssertEqual(AppLanguage.preferred(["fr-FR", "ja-JP", "en-US"]), .japanese, "macOS と同じく、最初に現れる対応言語を選ぶ")
        XCTAssertEqual(AppLanguage.preferred([]), .english)
    }

    func testEnglishPluralsAndJoinedTexts() {
        L10n.language = .english
        XCTAssertEqual(ByteFormatting.string(1), "1 byte")
        XCTAssertEqual(ByteFormatting.string(2), "2 bytes")
        XCTAssertEqual(L10n.filesCount(1), "1 file")
        XCTAssertEqual(L10n.foldersCount(1), "1 folder")
        XCTAssertEqual(L10n.treemapOthersTile(count: 1), "1 other")
        XCTAssertEqual(L10n.volumeUsage(used: nil, total: "500 GB"), "Volume: 500 GB total, usage unknown")
        XCTAssertEqual(
            L10n.volumeRow(used: L10n.usedUnknown, total: "500 GB", available: L10n.available("20 GB"), time: "10:00"),
            "500 GB total — usage unknown, 20 GB available (as of 10:00)"
        )
        XCTAssertEqual(L10n.timeRange("9:00", "9:05"), "9:00–9:05")
        XCTAssertFalse(TrashBlockReason.multipleHardLinks.message.contains("'"), "英語のアポストロフィは ’ を使う")
    }

    func testEnglishTexts() {
        L10n.language = .english
        XCTAssertEqual(ByteFormatting.string(0), "0 bytes")
        XCTAssertEqual(ByteFormatting.string(nil), "Unknown")
        XCTAssertEqual(ByteFormatting.summaryString(SizeSummary(knownAllocatedBytes: 10_000_000_000, unreadableLocations: 1)), "10.0 GB (incomplete)")
        XCTAssertEqual(DisplayText.state(.completedWithErrors, isStale: true), "Completed (some information missing) — results are out of date")
        XCTAssertEqual(DisplayText.elapsed(125), "2 min 5 s")
        XCTAssertEqual(TrashBlockReason.protectedLocation("/System").message, "Items in a protected location (/System) can’t be moved.")
        XCTAssertEqual(TrashFailure.unsupported.message, "Moving to the Trash isn’t supported here.")
        XCTAssertEqual(L10n.filesCount(1234), "\(1234.formatted()) files")
    }

    func testJapaneseTexts() {
        L10n.language = .japanese
        XCTAssertEqual(ByteFormatting.string(0), "0 バイト")
        XCTAssertEqual(DisplayText.elapsed(125), "2分5秒")
        XCTAssertEqual(TrashBlockReason.protectedLocation("/System").message, "保護された場所（/System）の項目は移動できません。")
    }

    /// すべての理由と失敗に、両方の言語で空でない文言がある。
    func testEveryMessageExistsInBothLanguages() {
        let reasons: [TrashBlockReason] = [
            .scanNotFinished, .operationInProgress, .notRegularFile, .unreadable, .scanRoot,
            .protectedLocation("/x"), .insidePackage, .outsideScope, .unsafePath, .identityUnavailable,
            .multipleHardLinks, .alreadyMoved, .notInCurrentResult,
        ]
        let failures: [TrashFailure] = [
            .blocked(.scanRoot), .changedSinceScan("d"), .systemRefused("d"), .cannotVerify("d"),
            .unexpectedItemMoved(nil), .unexpectedItemMoved("/t"), .unsupported,
        ]
        for language in AppLanguage.allCases {
            L10n.language = language
            for reason in reasons {
                XCTAssertFalse(reason.message.isEmpty, "\(language) \(reason)")
            }
            for failure in failures {
                XCTAssertFalse(failure.message.isEmpty, "\(language) \(failure)")
            }
        }
        L10n.language = .english
        let english = reasons.map(\.message) + failures.map(\.message)
        XCTAssertTrue(english.allSatisfy { !$0.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } }, "英語に仮名が混ざらない")
    }
}
