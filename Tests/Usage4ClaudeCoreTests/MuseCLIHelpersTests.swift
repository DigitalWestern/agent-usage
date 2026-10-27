import XCTest
@testable import Usage4ClaudeCore

/// Tests for the pure CLI helpers: output classification and executable lookup.
///
/// These encode the observed `muse` behaviour (see docs/MUSE_INTEGRATION.md §2)
/// so a CLI change fails a test instead of silently showing wrong numbers:
/// - exit 0 + JSON on stdout = success
/// - exit 1 + "not logged in" on stderr = needs login, not a transient error
/// - exit 0 + nothing on stdout = broken, never "0% used"
final class MuseCLIClassificationTests: XCTestCase {

    func testSuccessPassesStdoutThrough() {
        let payload = Data(#"{"schemaVersion":1}"#.utf8)

        let outcome = MuseCLIClassification.classify(exitCode: 0, stdout: payload, stderr: "")

        XCTAssertEqual(outcome, .success(payload))
    }

    func testNotSignedInIsDetectedFromStderr() {
        let outcome = MuseCLIClassification.classify(
            exitCode: 1,
            stdout: Data(),
            stderr: "muse usage: not logged in: run `muse login` first\n"
        )

        XCTAssertEqual(
            outcome,
            .notSignedIn(message: "muse usage: not logged in: run `muse login` first")
        )
    }

    func testNotSignedInMarkerIsCaseInsensitive() {
        let outcome = MuseCLIClassification.classify(
            exitCode: 1,
            stdout: Data(),
            stderr: "Muse: Not Logged In"
        )

        XCTAssertEqual(outcome, .notSignedIn(message: "Muse: Not Logged In"))
    }

    func testNotSignedInFallsBackToDefaultMessage() {
        let outcome = MuseCLIClassification.classify(exitCode: 1, stdout: Data(), stderr: "")

        XCTAssertEqual(outcome, .failed(exitCode: 1, message: "muse exited with code 1"))
    }

    func testGenericFailureKeepsExitCodeAndMessage() {
        let outcome = MuseCLIClassification.classify(
            exitCode: 2,
            stdout: Data(),
            stderr: "error: failed to reach mint\n"
        )

        XCTAssertEqual(outcome, .failed(exitCode: 2, message: "error: failed to reach mint"))
    }

    func testMultilineStderrIsCollapsedToOneLine() {
        let outcome = MuseCLIClassification.classify(
            exitCode: 3,
            stdout: Data(),
            stderr: "line one\n\n  line two  \n"
        )

        XCTAssertEqual(outcome, .failed(exitCode: 3, message: "line one line two"))
    }

    func testLongStderrIsTruncated() {
        let noisy = String(repeating: "a", count: 900)

        let outcome = MuseCLIClassification.classify(exitCode: 1, stdout: Data(), stderr: noisy)

        guard case .failed(_, let message) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(message.count, MuseCLIClassification.messageLimit + 1)
        XCTAssertTrue(message.hasSuffix("…"))
    }

    func testEmptyStdoutIsNotTreatedAsSuccess() {
        let outcome = MuseCLIClassification.classify(exitCode: 0, stdout: Data(), stderr: "")

        XCTAssertEqual(outcome, .emptyOutput)
    }

    func testWhitespaceOnlyStdoutIsNotTreatedAsSuccess() {
        let outcome = MuseCLIClassification.classify(
            exitCode: 0,
            stdout: Data("  \n\t ".utf8),
            stderr: ""
        )

        XCTAssertEqual(outcome, .emptyOutput)
    }

    func testStderrWarningsOnSuccessAreIgnored() {
        let payload = Data(#"{"schemaVersion":1}"#.utf8)

        let outcome = MuseCLIClassification.classify(
            exitCode: 0,
            stdout: payload,
            stderr: "warning: update available\n"
        )

        XCTAssertEqual(outcome, .success(payload))
    }
}

final class MuseCLILocatorTests: XCTestCase {

    private func locator(
        candidates: [String],
        existing: Set<String>
    ) -> MuseCLILocator {
        MuseCLILocator(candidatePaths: candidates) { existing.contains($0) }
    }

    func testUsesFirstExistingCandidate() {
        let subject = locator(
            candidates: ["/a/muse", "/b/muse", "/c/muse"],
            existing: ["/b/muse", "/c/muse"]
        )

        XCTAssertEqual(subject.locate()?.path, "/b/muse")
    }

    func testReturnsNilWhenNothingExists() {
        let subject = locator(candidates: ["/a/muse"], existing: [])

        XCTAssertNil(subject.locate())
    }

    func testOverrideWinsWhenExecutable() {
        let subject = locator(
            candidates: ["/a/muse"],
            existing: ["/a/muse", "/custom/muse"]
        )

        XCTAssertEqual(subject.locate(overridePath: "/custom/muse")?.path, "/custom/muse")
    }

    func testMissingOverrideFallsBackToCandidates() {
        let subject = locator(
            candidates: ["/a/muse"],
            existing: ["/a/muse"]
        )

        XCTAssertEqual(subject.locate(overridePath: "/nope/muse")?.path, "/a/muse")
    }

    func testBlankOverrideIsIgnored() {
        let subject = locator(candidates: ["/a/muse"], existing: ["/a/muse"])

        XCTAssertEqual(subject.locate(overridePath: "   ")?.path, "/a/muse")
    }

    func testOverrideIsTrimmed() {
        let subject = locator(candidates: [], existing: ["/custom/muse"])

        XCTAssertEqual(
            subject.locate(overridePath: "  /custom/muse \n")?.path,
            "/custom/muse"
        )
    }

    func testSearchedPathsKeepsOverrideFirstAndDeduplicates() {
        let subject = locator(
            candidates: ["/a/muse", "/a/muse", "/b/muse"],
            existing: []
        )

        XCTAssertEqual(
            subject.searchedPaths(overridePath: "/a/muse"),
            ["/a/muse", "/b/muse"]
        )
    }

    func testSearchedPathsExpandsTilde() {
        let subject = locator(candidates: [], existing: [])

        XCTAssertEqual(
            subject.searchedPaths(overridePath: "~/bin/muse"),
            [NSHomeDirectory() + "/bin/muse"]
        )
    }
}
