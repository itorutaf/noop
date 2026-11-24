import XCTest
@testable import StrandAnalytics

final class BreathSessionStatsTests: XCTestCase {

    private func session(_ day: String, _ seconds: Int, before: Double? = nil, after: Double? = nil) -> BreathSession {
        BreathSession(id: "\(day)-\(seconds)", dayKey: day, startedAt: 0, protocolId: "box", protocolName: "Box",
                      durationSeconds: seconds, rmssdBefore: before, rmssdAfter: after)
    }

    func testMinutesSumAcrossSessionsAndRoundDown() {
        let s = [session("2026-11-24", 150), session("2026-11-24", 200), session("2026-11-23", 600)]
        XCTAssertEqual(BreathSessionStats.seconds(on: "2026-11-24", sessions: s), 350)
        XCTAssertEqual(BreathSessionStats.minutes(on: "2026-11-24", sessions: s), 5)
    }

    func testDailyMinutesOldestFirstWithEmptyDays() {
        let s = [session("2026-11-18", 300), session("2026-11-22", 120), session("2026-11-24", 600),
                 session("2026-11-17", 900)]   // outside the 7-day window
        XCTAssertEqual(BreathSessionStats.dailyMinutes(endingAt: "2026-11-24", sessions: s), [5, 0, 0, 0, 2, 0, 10])
    }

    func testDailyMinutesRejectsBadInput() {
        XCTAssertEqual(BreathSessionStats.dailyMinutes(endingAt: "nope", sessions: []), [])
        XCTAssertEqual(BreathSessionStats.dailyMinutes(endingAt: "2026-11-24", days: 0, sessions: []), [])
    }

    func testGoalProgressClamps() {
        let s = [session("2026-11-24", 150)]
        XCTAssertEqual(BreathSessionStats.goalProgress(today: "2026-11-24", goalMinutes: 5, sessions: s), 0.5, accuracy: 1e-9)
        XCTAssertEqual(BreathSessionStats.goalProgress(today: "2026-11-24", goalMinutes: 1, sessions: s), 1)
        XCTAssertEqual(BreathSessionStats.goalProgress(today: "2026-11-24", goalMinutes: 0, sessions: s), 0)
    }

    func testStreakIgnoresTooShortSessions() {
        let s = [session("2026-11-22", 300), session("2026-11-23", 30), session("2026-11-24", 300)]
        let got = BreathSessionStats.streaks(today: "2026-11-24", sessions: s)
        XCTAssertEqual(got, StreakCalculator.Streaks(current: 1, longest: 1))
    }

    func testStreakHoldsUntilTodayIsLogged() {
        let s = [session("2026-11-22", 300), session("2026-11-23", 300)]
        let got = BreathSessionStats.streaks(today: "2026-11-24", sessions: s)
        XCTAssertEqual(got, StreakCalculator.Streaks(current: 2, longest: 2))
    }

    func testRmssdDelta() {
        XCTAssertEqual(session("2026-11-24", 300, before: 40, after: 52).rmssdDelta, 12)
        XCTAssertNil(session("2026-11-24", 300, before: 40).rmssdDelta)
    }
}
