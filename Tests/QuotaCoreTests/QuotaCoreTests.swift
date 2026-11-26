import XCTest
@testable import QuotaCore

final class QuotaCoreTests: XCTestCase {
    func testDetectsTerminalCodexCLI() {
        let records = [
            ProcessRecord(pid: 10, parentPID: 1, executablePath: "/Applications/Terminal.app/Contents/MacOS/Terminal"),
            ProcessRecord(pid: 11, parentPID: 10, executablePath: "/bin/zsh"),
            ProcessRecord(pid: 12, parentPID: 11, executablePath: "/opt/homebrew/bin/node"),
            ProcessRecord(pid: 13, parentPID: 12, executablePath: "/opt/homebrew/lib/node_modules/@openai/codex/vendor/bin/codex"),
        ]

        XCTAssertTrue(CodexProcessClassifier.containsInteractiveCLI(in: records, monitorPID: 99))
    }

    func testIgnoresQuotaClientsOwnCodexProcess() {
        let records = [
            ProcessRecord(pid: 20, parentPID: 1, executablePath: "/Applications/PetQuotaDisplay"),
            ProcessRecord(pid: 21, parentPID: 20, executablePath: "/opt/homebrew/bin/node"),
            ProcessRecord(pid: 22, parentPID: 21, executablePath: "/opt/homebrew/lib/node_modules/@openai/codex/vendor/bin/codex"),
        ]

        XCTAssertFalse(CodexProcessClassifier.containsInteractiveCLI(in: records, monitorPID: 20))
    }

    func testIgnoresCodexDesktopInternalProcess() {
        let records = [
            ProcessRecord(pid: 30, parentPID: 1, executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
            ProcessRecord(pid: 31, parentPID: 30, executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
        ]

        XCTAssertFalse(CodexProcessClassifier.containsInteractiveCLI(in: records, monitorPID: 99))
    }

    func testIgnoresAnExternalCodexExecutableLaunchedByTheDesktopApp() {
        let records = [
            ProcessRecord(pid: 35, parentPID: 1, executablePath: "/Applications/Codex.app/Contents/MacOS/Codex"),
            ProcessRecord(pid: 36, parentPID: 35, executablePath: "/opt/homebrew/bin/codex"),
        ]
        XCTAssertFalse(CodexProcessClassifier.containsInteractiveCLI(in: records, monitorPID: 99))
    }

    func testParsesFiveHourAndWeeklyWindows() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "planType": "plus",
                "primary": [
                    "usedPercent": 20,
                    "windowDurationMins": 300,
                    "resetsAt": 2_000_000_000,
                ],
                "secondary": [
                    "usedPercent": 65,
                    "windowDurationMins": 10_080,
                    "resetsAt": 2_000_100_000,
                ],
            ],
        ]

        let snapshot = try QuotaParser.parse(result: result, now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 80)
        XCTAssertEqual(snapshot.fiveHour?.resetsAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 35)
        XCTAssertEqual(snapshot.weekly?.resetsAt, Date(timeIntervalSince1970: 2_000_100_000))
    }

    func testParsesChatGPTAccount() {
        let result: [String: Any] = [
            "account": [
                "type": "chatgpt",
                "email": "first@example.com",
                "planType": "plus",
            ],
            "requiresOpenaiAuth": true,
        ]

        XCTAssertEqual(
            CodexAccountParser.parse(result: result),
            CodexAccountSummary(email: "first@example.com", planType: "plus")
        )
    }

    func testParsesSignedOutAccount() {
        let result: [String: Any] = ["account": NSNull(), "requiresOpenaiAuth": true]

        XCTAssertNil(CodexAccountParser.parse(result: result))
    }

    func testParsesWindowsWhenOrderIsSwapped() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": [
                    "usedPercent": 16,
                    "windowDurationMins": 10_080,
                    "resetsAt": 1_788_138_750,
                ],
                "secondary": [
                    "usedPercent": 44,
                    "windowDurationMins": 300,
                    "resetsAt": 1_788_000_000,
                ],
            ],
        ]

        let snapshot = try QuotaParser.parse(result: result)

        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 56)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 84)
    }

    func testClampsPercentages() {
        XCTAssertEqual(WeeklyQuota(usedPercent: -10, resetsAt: nil).remainingPercent, 100)
        XCTAssertEqual(WeeklyQuota(usedPercent: 140, resetsAt: nil).remainingPercent, 0)
    }

    /// ChatGPT Pro only publishes the weekly window.
    func testParsesPlanWithoutFiveHourWindow() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "planType": "prolite",
                "primary": ["usedPercent": 9, "windowDurationMins": 10_080, "resetsAt": 1_792_551_039],
                "secondary": NSNull(),
            ],
        ]

        let snapshot = try QuotaParser.parse(result: result)

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 91)
    }

    func testParsesPlanWithoutWeeklyWindow() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 10, "windowDurationMins": 300],
            ],
        ]

        let snapshot = try QuotaParser.parse(result: result)

        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
    }

    func testMissingAnyKnownWindowIsAnError() {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 10, "windowDurationMins": 60],
            ],
        ]

        XCTAssertThrowsError(try QuotaParser.parse(result: result)) { error in
            XCTAssertEqual(error as? QuotaParseError, .missingQuotaWindow)
        }
    }

    func testMalformedCodexWindowDoesNotMaskValidWindowOfSameDuration() throws {
        for invalidPercent in [true, 1.5] as [Any] {
            let payload: [String: Any] = ["rateLimits": [
                "primary": ["usedPercent": invalidPercent, "windowDurationMins": 300],
                "secondary": ["usedPercent": 10, "windowDurationMins": 300, "resetsAt": false],
            ]]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let snapshot = try QuotaParser.parse(result: decoded)
            XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 90)
            XCTAssertNil(snapshot.fiveHour?.resetsAt)
        }
    }

    func testFallsBackToNamedCodexBucketWithoutUsingOtherModelQuotas() throws {
        let payload: [String: Any] = [
            "rateLimits": ["primary": NSNull()],
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 20, "windowDurationMins": 10_080]],
                "separate-model": ["primary": ["usedPercent": 99, "windowDurationMins": 300]],
            ],
        ]
        let snapshot = try QuotaParser.parse(result: payload)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 80)
        XCTAssertNil(snapshot.fiveHour)
    }

    func testReportExposesAdditionalBucketsWithoutRepeatingThePrimary() throws {
        let window = ["usedPercent": 25, "windowDurationMins": 300]
        let payload: [String: Any] = [
            "rateLimits": ["limitId": "default-model", "primary": window],
            "rateLimitsByLimitId": [
                "codex": ["primary": window],
                "default-model": ["primary": window],
                "other-model": ["limitName": "  Other Model  ", "primary": window],
                "broken": "unsupported",
            ],
        ]
        let now = Date(timeIntervalSince1970: 42)
        let report = try QuotaParser.parseReport(result: payload, now: now)
        XCTAssertEqual(report.primary.fiveHour?.remainingPercent, 75)
        XCTAssertEqual(report.additional.map(\.id), ["other-model"])
        XCTAssertEqual(report.additional.first?.name, "Other Model")
        XCTAssertEqual(report.additional.first?.snapshot.fetchedAt, now)
    }
}
