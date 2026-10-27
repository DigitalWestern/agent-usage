import XCTest
@testable import Usage4ClaudeCore

/// Tests for `MuseUsageResponse.parse(_:)` — the `muse usage --json`
/// payload → in-memory transform.
///
/// Specs the production code intends to honour:
/// - `schemaVersion` must be exactly 1. Anything else is an unsupported
///   contract, not "probably fine".
/// - `allowance == null` is a failure carrying `reason`/`hint`, because the
///   only way that happens is "no usable quota" (signed out, backend error).
/// - Epoch fields are milliseconds.
/// - Percentages are clamped to 0...100 so a bad number cannot corrupt the
///   ring, the pace graph or the notification thresholds.
/// - A reset time in the past is still returned; staleness is the view's job.
final class MuseUsageResponseTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ json: String) throws -> MuseUsageData {
        try MuseUsageResponse.parse(Data(json.utf8), now: now)
    }

    private func response(_ json: String) throws -> MuseUsageResponse {
        try JSONDecoder().decode(MuseUsageResponse.self, from: Data(json.utf8))
    }

    private func json(
        schema: Int = 1,
        tier: String? = "\"Muse Code Power Usage\"",
        windowPercent: String = "19",
        windowReset: String = "1793075029000",
        weeklyPercent: String = "20",
        weeklyReset: String = "1793577600000",
        asOf: String? = "1793072428666",
        reason: String? = nil,
        hint: String? = nil
    ) -> String {
        """
        {
          "schemaVersion": \(schema),
          "allowance": {
            "tier": \(tier ?? "null"),
            "window": {"usedPercent": \(windowPercent), "resetsAtMs": \(windowReset)},
            "weekly": {"usedPercent": \(weeklyPercent), "resetsAtMs": \(weeklyReset)},
            "asOfMs": \(asOf ?? "null"),
            "source": "mint"
          },
          "reason": \(reason.map { "\"\($0)\"" } ?? "null"),
          "hint": \(hint.map { "\"\($0)\"" } ?? "null")
        }
        """
    }

    // MARK: - Success

    func testParsesVerifiedPayload() throws {
        let data = try parse(json())

        XCTAssertEqual(data.tier, "Muse Code Power Usage")
        XCTAssertEqual(data.window.usedPercent, 19)
        XCTAssertEqual(data.weekly.usedPercent, 20)
    }

    func testConvertsMillisecondEpochsToDates() throws {
        let data = try parse(json())

        XCTAssertEqual(
            data.window.resetsAt.timeIntervalSince1970,
            1_793_075_029,
            accuracy: 0.001
        )
        XCTAssertEqual(
            data.weekly.resetsAt.timeIntervalSince1970,
            1_793_577_600,
            accuracy: 0.001
        )
        XCTAssertEqual(
            data.asOf.timeIntervalSince1970,
            1_793_072_428.666,
            accuracy: 0.001
        )
    }

    func testFractionalMillisecondsAreAccepted() throws {
        let data = try parse(json(windowReset: "1793075029123.5"))

        XCTAssertEqual(
            data.window.resetsAt.timeIntervalSince1970,
            1_793_075_029.1235,
            accuracy: 0.001
        )
    }

    func testMissingAsOfFallsBackToNow() throws {
        let data = try parse(json(asOf: nil))

        XCTAssertEqual(data.asOf, now)
    }

    func testMissingTierBecomesNil() throws {
        let data = try parse(json(tier: nil))

        XCTAssertNil(data.tier)
    }

    func testBlankTierBecomesNil() throws {
        let data = try parse(json(tier: "\"   \""))

        XCTAssertNil(data.tier)
    }

    func testTierIsTrimmed() throws {
        let data = try parse(json(tier: "\"  Muse Code Power Usage \\n\""))

        XCTAssertEqual(data.tier, "Muse Code Power Usage")
    }

    // MARK: - Clamping

    func testPercentAboveHundredIsClamped() throws {
        let data = try parse(json(windowPercent: "118", weeklyPercent: "240"))

        XCTAssertEqual(data.window.usedPercent, 100)
        XCTAssertEqual(data.weekly.usedPercent, 100)
    }

    func testNegativePercentIsClamped() throws {
        let data = try parse(json(windowPercent: "-5"))

        XCTAssertEqual(data.window.usedPercent, 0)
    }

    func testPartialPercentIsPreserved() throws {
        let data = try parse(json(windowPercent: "42.7"))

        XCTAssertEqual(data.window.usedPercent, 42.7, accuracy: 0.001)
    }

    // MARK: - Reset times

    func testPastResetTimeIsReturnedNotDropped() throws {
        // Window rolled over but the CLI served a stale snapshot. The view marks
        // it stale; the model must not throw the data away or show a negative
        // countdown by inventing a new date.
        let past = String(Int(now.timeIntervalSince1970 * 1000) - 60_000)
        let data = try parse(json(windowReset: past))

        XCTAssertLessThan(data.window.resetsAt, now)
    }

    func testZeroPercentIsRealData() throws {
        // Unlike Codex, a 0% window with a reset time is a valid "just reset"
        // state and must not be treated as absent.
        let data = try parse(json(windowPercent: "0"))

        XCTAssertEqual(data.window.usedPercent, 0)
    }

    // MARK: - Unsupported contract

    func testRejectsUnsupportedSchemaVersion() throws {
        let payload = try response(json(schema: 2))

        XCTAssertThrowsError(try payload.toMuseUsageData(now: now)) { error in
            XCTAssertEqual(error as? MuseUsageParseError, .unsupportedSchema(2))
        }
    }

    func testRejectsSchemaVersionZero() throws {
        let payload = try response(json(schema: 0))

        XCTAssertThrowsError(try payload.toMuseUsageData(now: now)) { error in
            XCTAssertEqual(error as? MuseUsageParseError, .unsupportedSchema(0))
        }
    }

    // MARK: - No allowance

    func testMissingAllowanceCarriesReasonAndHint() throws {
        let payload = try response("""
        {"schemaVersion": 1, "allowance": null, "reason": "quota unavailable", "hint": "try again later"}
        """)

        XCTAssertThrowsError(try payload.toMuseUsageData(now: now)) { error in
            XCTAssertEqual(
                error as? MuseUsageParseError,
                .missingAllowance(reason: "quota unavailable", hint: "try again later")
            )
        }
    }

    func testMissingAllowanceWithoutReasonIsStillAnError() throws {
        let payload = try response("""
        {"schemaVersion": 1, "allowance": null}
        """)

        XCTAssertThrowsError(try payload.toMuseUsageData(now: now)) { error in
            XCTAssertEqual(error as? MuseUsageParseError, .missingAllowance(reason: nil, hint: nil))
        }
    }

    // MARK: - Malformed output

    func testRejectsEmptyOutput() throws {
        XCTAssertThrowsError(try MuseUsageResponse.parse(Data(), now: now)) { error in
            XCTAssertEqual(error as? MuseUsageParseError, .malformedOutput)
        }
    }

    func testRejectsNonJSONOutput() throws {
        XCTAssertThrowsError(try parse("muse: something went wrong")) { error in
            XCTAssertEqual(error as? MuseUsageParseError, .malformedOutput)
        }
    }

    func testRejectsTruncatedJSON() throws {
        XCTAssertThrowsError(try parse(#"{"schemaVersion":1,"allowance":{"tier":"x""#)) { error in
            XCTAssertEqual(error as? MuseUsageParseError, .malformedOutput)
        }
    }

    func testRejectsPayloadMissingWindow() throws {
        XCTAssertThrowsError(try parse("""
        {"schemaVersion": 1, "allowance": {"tier": "x", "weekly": {"usedPercent": 1, "resetsAtMs": 1}}}
        """)) { error in
            XCTAssertEqual(error as? MuseUsageParseError, .malformedOutput)
        }
    }
}
