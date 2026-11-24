import XCTest
@testable import StrandAnalytics

final class SeventyFiveHardTests: XCTestCase {

    private func full(_ day: String) -> SeventyFiveHard.DayLog {
        SeventyFiveHard.DayLog(dayKey: day, workoutMinutes: [45, 60], outdoorWorkout: true, waterML: 3785,
                               pagesRead: 10, dietFollowed: true, noAlcohol: true, progressPhoto: true)
    }

    /// `count` consecutive complete days starting at `start`.
    private func run(from start: String, count: Int) -> [SeventyFiveHard.DayLog] {
        let s = Baselines.isoEpochDay(start)!
        return (0..<count).map { full(SeventyFiveHard.isoDay(s + $0)) }
    }

    // MARK: Per-day rules

    func testFullDayIsComplete() {
        XCTAssertTrue(SeventyFiveHard.isComplete(full("2026-11-24")))
        XCTAssertEqual(SeventyFiveHard.remaining(full("2026-11-24")), [])
    }

    func testEmptyDayHasEveryTaskOpen() {
        let log = SeventyFiveHard.DayLog(dayKey: "2026-11-24")
        XCTAssertEqual(SeventyFiveHard.remaining(log), SeventyFiveHard.Task.allCases)
    }

    func testShortWorkoutDoesNotCount() {
        var log = full("2026-11-24")
        log.workoutMinutes = [44, 90]
        XCTAssertEqual(SeventyFiveHard.qualifyingWorkouts(log), 1)
        XCTAssertEqual(SeventyFiveHard.remaining(log), [.workouts])
    }

    func testOutdoorNeedsAQualifyingWorkout() {
        var log = full("2026-11-24")
        log.workoutMinutes = [20]
        XCTAssertFalse(SeventyFiveHard.isDone(.outdoorWorkout, in: log))
    }

    func testWaterAndPagesBoundaries() {
        var log = full("2026-11-24")
        log.waterML = 3784
        log.pagesRead = 9
        XCTAssertEqual(SeventyFiveHard.remaining(log), [.water, .reading])
    }

    // MARK: Run status

    func testNotStartedBeforeStartDay() {
        let s = SeventyFiveHard.status(startDay: "2026-11-24", today: "2026-11-23", logs: [])
        XCTAssertEqual(s.state, .notStarted)
        XCTAssertEqual(s.dayNumber, 0)
    }

    func testDayOneInProgressIsActive() {
        let s = SeventyFiveHard.status(startDay: "2026-11-24", today: "2026-11-24", logs: [])
        XCTAssertEqual(s, SeventyFiveHard.Status(state: .active, dayNumber: 1, completedDays: 0, failedDayKey: nil))
    }

    func testTodayCountsOnceComplete() {
        let s = SeventyFiveHard.status(startDay: "2026-11-24", today: "2026-11-24", logs: [full("2026-11-24")])
        XCTAssertEqual(s.completedDays, 1)
        XCTAssertEqual(s.state, .active)
    }

    func testMissedYesterdayFails() {
        let logs = run(from: "2026-11-24", count: 3)   // 24, 25, 26 complete; 27 missing
        let s = SeventyFiveHard.status(startDay: "2026-11-24", today: "2026-11-28", logs: logs)
        XCTAssertEqual(s.state, .failed)
        XCTAssertEqual(s.failedDayKey, "2026-11-27")
        XCTAssertEqual(s.completedDays, 3)
        XCTAssertEqual(s.dayNumber, 5)
    }

    func testIncompleteLoggedDayFails() {
        var logs = run(from: "2026-11-24", count: 2)
        logs[1].noAlcohol = false
        let s = SeventyFiveHard.status(startDay: "2026-11-24", today: "2026-11-26", logs: logs)
        XCTAssertEqual(s.state, .failed)
        XCTAssertEqual(s.failedDayKey, "2026-11-25")
    }

    func testSeventyFourDaysIsStillActive() {
        let logs = run(from: "2026-11-24", count: 74)
        let s = SeventyFiveHard.status(startDay: "2026-11-24", today: "2027-02-06", logs: logs)
        XCTAssertEqual(s.state, .active)
        XCTAssertEqual(s.dayNumber, 75)
        XCTAssertEqual(s.completedDays, 74)
    }

    func testSeventyFiveDaysCompletes() {
        let logs = run(from: "2026-11-24", count: 75)
        let onLastDay = SeventyFiveHard.status(startDay: "2026-11-24", today: "2027-02-06", logs: logs)
        XCTAssertEqual(onLastDay.state, .completed)
        let later = SeventyFiveHard.status(startDay: "2026-11-24", today: "2027-03-01", logs: logs)
        XCTAssertEqual(later.state, .completed)
        XCTAssertEqual(later.dayNumber, 75)
        XCTAssertEqual(later.completedDays, 75)
    }

    func testLogsBeforeStartAreIgnored() {
        let logs = run(from: "2026-11-01", count: 30)
        let s = SeventyFiveHard.status(startDay: "2026-11-24", today: "2026-11-26", logs: logs)
        XCTAssertEqual(s.completedDays, 3)
        XCTAssertEqual(s.dayNumber, 3)
    }

    func testIsoDayRoundTrips() {
        for key in ["2026-11-24", "2027-02-06", "2024-02-29", "2026-12-31", "2027-01-01"] {
            XCTAssertEqual(SeventyFiveHard.isoDay(Baselines.isoEpochDay(key)!), key)
        }
    }
}
