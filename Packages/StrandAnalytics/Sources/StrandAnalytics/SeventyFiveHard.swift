import Foundation

// SeventyFiveHard.swift - pure rules for the opt-in, local-only 75-day challenge mode.
//
// STRICT RULES: every task must be done on every day. The first fully elapsed day with any task left
// open fails the run, and the challenge starts again from Day 1. Today never fails the run while it is
// still in progress. Everything here is headless: no clock, no I/O, no storage. The caller passes ISO
// `yyyy-MM-dd` local day keys and the per-day logs it has; civil-day arithmetic is TZ-free
// (`Baselines.isoEpochDay`). No em-dashes.

public enum SeventyFiveHard {

    // MARK: - Constants

    /// Length of the challenge in days.
    public static let totalDays = 75
    /// Workouts required per day.
    public static let requiredWorkouts = 2
    /// Minimum length (minutes) for a workout to count.
    public static let workoutMinMinutes = 45
    /// Daily water target: one US gallon, in millilitres.
    public static let waterGoalML = 3785
    /// Daily reading target, in pages.
    public static let pagesGoal = 10

    // MARK: - Model

    /// The daily tasks, in display order.
    public enum Task: String, CaseIterable, Sendable, Codable {
        case workouts, outdoorWorkout, water, reading, diet, noAlcohol, progressPhoto
    }

    /// Everything recorded for one local day.
    public struct DayLog: Equatable, Sendable, Codable {
        /// Local day, `yyyy-MM-dd`.
        public var dayKey: String
        /// Length in minutes of each workout counted for the day (detected or entered by hand).
        public var workoutMinutes: [Int]
        /// One of the day's workouts was outdoors. A plain tick: the workouts task separately requires
        /// the two qualifying sessions, so this one never disagrees with what the user ticked.
        public var outdoorWorkout: Bool
        /// Water logged for the day, in millilitres.
        public var waterML: Int
        /// Pages read.
        public var pagesRead: Int
        /// The chosen diet was followed, with no cheat meals.
        public var dietFollowed: Bool
        /// No alcohol was consumed.
        public var noAlcohol: Bool
        /// A progress photo was taken.
        public var progressPhoto: Bool

        public init(dayKey: String, workoutMinutes: [Int] = [], outdoorWorkout: Bool = false,
                    waterML: Int = 0, pagesRead: Int = 0, dietFollowed: Bool = false,
                    noAlcohol: Bool = false, progressPhoto: Bool = false) {
            self.dayKey = dayKey
            self.workoutMinutes = workoutMinutes
            self.outdoorWorkout = outdoorWorkout
            self.waterML = waterML
            self.pagesRead = pagesRead
            self.dietFollowed = dietFollowed
            self.noAlcohol = noAlcohol
            self.progressPhoto = progressPhoto
        }
    }

    /// Where a run stands.
    public enum State: String, Equatable, Sendable {
        /// `today` is before the start day (or a day key could not be parsed).
        case notStarted
        /// The run is in progress and no elapsed day has been missed.
        case active
        /// An elapsed day was left incomplete; the run must restart from Day 1.
        case failed
        /// All 75 days are complete.
        case completed
    }

    public struct Status: Equatable, Sendable {
        public let state: State
        /// 1-based day of the challenge `today` falls on, clamped to 1...75. 0 when not started.
        public let dayNumber: Int
        /// Fully completed days so far in this run (includes today once every task is done).
        public let completedDays: Int
        /// The first elapsed day that was left incomplete, when `state == .failed`.
        public let failedDayKey: String?

        public init(state: State, dayNumber: Int, completedDays: Int, failedDayKey: String?) {
            self.state = state
            self.dayNumber = dayNumber
            self.completedDays = completedDays
            self.failedDayKey = failedDayKey
        }
    }

    // MARK: - Per-day rules

    /// Number of workouts in the log that meet the minimum length.
    public static func qualifyingWorkouts(_ log: DayLog) -> Int {
        log.workoutMinutes.filter { $0 >= workoutMinMinutes }.count
    }

    /// Whether one task is done for the day.
    public static func isDone(_ task: Task, in log: DayLog) -> Bool {
        switch task {
        case .workouts:       return qualifyingWorkouts(log) >= requiredWorkouts
        case .outdoorWorkout: return log.outdoorWorkout
        case .water:          return log.waterML >= waterGoalML
        case .reading:        return log.pagesRead >= pagesGoal
        case .diet:           return log.dietFollowed
        case .noAlcohol:      return log.noAlcohol
        case .progressPhoto:  return log.progressPhoto
        }
    }

    /// Tasks still open for the day, in display order.
    public static func remaining(_ log: DayLog) -> [Task] {
        Task.allCases.filter { !isDone($0, in: log) }
    }

    /// Every task is done.
    public static func isComplete(_ log: DayLog) -> Bool {
        remaining(log).isEmpty
    }

    // MARK: - Run status

    /// Status of a run that began on `startDay`, as of `today`, given the logs on hand. Logs outside the
    /// run window are ignored; when a day has more than one log the last one wins; a day with no log is
    /// incomplete.
    public static func status(startDay: String, today: String, logs: [DayLog]) -> Status {
        guard let start = Baselines.isoEpochDay(startDay), let now = Baselines.isoEpochDay(today),
              now >= start else {
            return Status(state: .notStarted, dayNumber: 0, completedDays: 0, failedDayKey: nil)
        }

        var completeByDay: [Int: Bool] = [:]
        var keyByDay: [Int: String] = [:]
        for log in logs {
            guard let e = Baselines.isoEpochDay(log.dayKey) else { continue }
            completeByDay[e] = isComplete(log)
            keyByDay[e] = log.dayKey
        }

        let lastDay = start + totalDays - 1
        let dayNumber = Swift.min(now - start + 1, totalDays)

        // Every day that has fully elapsed (before today, within the 75-day window) must be complete.
        var completed = 0
        let lastElapsed = Swift.min(now - 1, lastDay)
        if lastElapsed >= start {
            for d in start...lastElapsed {
                if completeByDay[d] == true {
                    completed += 1
                } else {
                    // A missed day may have no log at all, so derive its key from the day number.
                    return Status(state: .failed, dayNumber: dayNumber, completedDays: completed,
                                  failedDayKey: keyByDay[d] ?? isoDay(d))
                }
            }
        }

        // Today counts once it is complete (only while it is still inside the window).
        if now <= lastDay, completeByDay[now] == true { completed += 1 }

        let state: State = completed >= totalDays ? .completed : .active
        return Status(state: state, dayNumber: dayNumber, completedDays: completed, failedDayKey: nil)
    }

    // MARK: - Day helpers

    /// Whole civil days from `startDay` to `day` (0 when they are the same day, negative when `day` is
    /// earlier). Nil when either key cannot be parsed.
    public static func daysBetween(_ startDay: String, _ day: String) -> Int? {
        guard let a = Baselines.isoEpochDay(startDay), let b = Baselines.isoEpochDay(day) else { return nil }
        return b - a
    }

    /// The day key `offset` days after `startDay` (offset 0 is the start day itself).
    public static func dayKey(startDay: String, offset: Int) -> String? {
        guard let a = Baselines.isoEpochDay(startDay) else { return nil }
        return isoDay(a + offset)
    }

    /// Every day key of the run from `startDay` through `today`, oldest first, capped at the 75-day
    /// window. Empty when `today` is before the start or a key cannot be parsed.
    public static func dayKeys(startDay: String, through today: String) -> [String] {
        guard let a = Baselines.isoEpochDay(startDay), let b = Baselines.isoEpochDay(today), b >= a else { return [] }
        let last = Swift.min(b, a + totalDays - 1)
        return (a...last).map { isoDay($0) }
    }

    /// ISO `yyyy-MM-dd` for a civil epoch day (inverse of `Baselines.isoEpochDay`; Howard Hinnant's
    /// `civil_from_days`).
    public static func isoDay(_ epochDay: Int) -> String {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let year = m <= 2 ? y + 1 : y
        func pad(_ v: Int, _ width: Int) -> String {
            let s = String(v)
            return String(repeating: "0", count: Swift.max(0, width - s.count)) + s
        }
        return "\(pad(year, 4))-\(pad(m, 2))-\(pad(d, 2))"
    }
}
