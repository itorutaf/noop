import Foundation

// BreathSessionStats.swift - pure summaries over the on-device log of completed breathing sessions.
//
// A session is logged when the user finishes (or stops) a Breathe session. This file only does the
// arithmetic the history list, the weekly bars, the streak and the Today card need. Headless: no
// clock, no I/O. Day keys are ISO `yyyy-MM-dd` local days; civil-day arithmetic is TZ-free. No em-dashes.

/// One completed breathing session.
public struct BreathSession: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    /// Local day the session started on, `yyyy-MM-dd`.
    public var dayKey: String
    /// Start time, seconds since 1970.
    public var startedAt: Double
    /// Catalog id of the protocol (or a mode token such as "resonance" / "calm").
    public var protocolId: String
    /// Name shown in the history list, captured at log time.
    public var protocolName: String
    /// How long the session ran, in seconds.
    public var durationSeconds: Int
    /// Completed breath cycles, when the session was paced (nil for guided, timer-only sessions).
    public var breaths: Int?
    /// HRV (RMSSD, ms) at the start, and the session average, when a strap supplied R-R intervals.
    public var rmssdBefore: Double?
    public var rmssdAfter: Double?

    public init(id: String, dayKey: String, startedAt: Double, protocolId: String, protocolName: String,
                durationSeconds: Int, breaths: Int? = nil, rmssdBefore: Double? = nil, rmssdAfter: Double? = nil) {
        self.id = id
        self.dayKey = dayKey
        self.startedAt = startedAt
        self.protocolId = protocolId
        self.protocolName = protocolName
        self.durationSeconds = durationSeconds
        self.breaths = breaths
        self.rmssdBefore = rmssdBefore
        self.rmssdAfter = rmssdAfter
    }

    /// Change in RMSSD from the start to the session average, when both were measured.
    public var rmssdDelta: Double? {
        guard let before = rmssdBefore, let after = rmssdAfter else { return nil }
        return after - before
    }
}

public enum BreathSessionStats {

    /// Sessions shorter than this are not logged and do not count toward a streak.
    public static let minimumSessionSeconds = 60
    /// Default daily goal, in minutes.
    public static let defaultGoalMinutes = 5

    /// Total seconds breathed on one day.
    public static func seconds(on dayKey: String, sessions: [BreathSession]) -> Int {
        sessions.reduce(0) { $0 + ($1.dayKey == dayKey ? Swift.max(0, $1.durationSeconds) : 0) }
    }

    /// Whole minutes breathed on one day (rounded down).
    public static func minutes(on dayKey: String, sessions: [BreathSession]) -> Int {
        seconds(on: dayKey, sessions: sessions) / 60
    }

    /// Whole minutes for each of the `days` days ending at `today`, oldest first. Empty when `today`
    /// cannot be parsed or `days` is not positive.
    public static func dailyMinutes(endingAt today: String, days: Int = 7, sessions: [BreathSession]) -> [Int] {
        guard days > 0, let end = Baselines.isoEpochDay(today) else { return [] }
        var secondsByOffset = [Int](repeating: 0, count: days)
        let first = end - (days - 1)
        for s in sessions {
            guard let e = Baselines.isoEpochDay(s.dayKey), e >= first, e <= end else { continue }
            secondsByOffset[e - first] += Swift.max(0, s.durationSeconds)
        }
        return secondsByOffset.map { $0 / 60 }
    }

    /// Fraction of the daily goal reached today, clamped to 0...1. 0 when the goal is not positive.
    public static func goalProgress(today: String, goalMinutes: Int, sessions: [BreathSession]) -> Double {
        guard goalMinutes > 0 else { return 0 }
        let done = Double(seconds(on: today, sessions: sessions)) / 60.0
        return Swift.min(1, Swift.max(0, done / Double(goalMinutes)))
    }

    /// Total whole minutes across every logged session.
    public static func totalMinutes(_ sessions: [BreathSession]) -> Int {
        sessions.reduce(0) { $0 + Swift.max(0, $1.durationSeconds) } / 60
    }

    /// Percent change in RMSSD from the start to the session average, rounded. Nil without both readings
    /// or when the starting value is not positive.
    public static func rmssdPercentChange(_ session: BreathSession) -> Int? {
        guard let before = session.rmssdBefore, before > 0, let after = session.rmssdAfter else { return nil }
        return Int(((after - before) / before * 100).rounded())
    }

    /// Current and longest runs of days that carry at least one session of `minimumSessionSeconds` or more.
    /// The current run is anchored at today, or at yesterday when today has no session yet.
    public static func streaks(today: String, sessions: [BreathSession]) -> StreakCalculator.Streaks {
        let keys = sessions.map(\.dayKey)
        let qualified = sessions.map { $0.durationSeconds >= minimumSessionSeconds }
        return StreakCalculator.streaks(dayKeys: keys, qualified: qualified, today: today)
    }
}
