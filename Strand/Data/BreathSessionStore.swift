import Foundation
import StrandAnalytics

// BreathSessionStore.swift - the on-device log of completed Breathe sessions.
//
// LOCAL-ONLY: one JSON array in UserDefaults, newest first when read. Nothing is synced or uploaded.
// The arithmetic over the log (minutes, streak, goal progress) lives in `BreathSessionStats`
// (Packages/StrandAnalytics) so it stays headless and unit-tested; this file only reads and writes.

enum BreathSessionStore {
    /// UserDefaults key for the JSON-encoded session list.
    static let sessionsKey = "breathe.sessions.v1"
    /// AppStorage key for the daily goal, in minutes.
    static let goalKey = "breathe.dailyGoalMinutes"
    /// Oldest sessions are dropped beyond this many, so the blob stays small.
    static let maxSessions = 1000
    /// Daily goal choices offered in the goal menu, in minutes.
    static let goalChoices = [3, 5, 10, 15, 20]

    /// Every logged session, newest first.
    static func load(_ defaults: UserDefaults = .standard) -> [BreathSession] {
        guard let data = defaults.data(forKey: sessionsKey),
              let list = try? JSONDecoder().decode([BreathSession].self, from: data) else { return [] }
        return list.sorted { $0.startedAt > $1.startedAt }
    }

    static func save(_ sessions: [BreathSession], _ defaults: UserDefaults = .standard) {
        let trimmed = Array(sessions.sorted { $0.startedAt > $1.startedAt }.prefix(maxSessions))
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: sessionsKey)
        }
    }

    /// Log one session and return the updated list, newest first.
    @discardableResult
    static func append(_ session: BreathSession, _ defaults: UserDefaults = .standard) -> [BreathSession] {
        var all = load(defaults)
        all.append(session)
        save(all, defaults)
        return load(defaults)
    }

    /// Remove one session by id and return the updated list, newest first.
    @discardableResult
    static func delete(id: String, _ defaults: UserDefaults = .standard) -> [BreathSession] {
        let remaining = load(defaults).filter { $0.id != id }
        save(remaining, defaults)
        return remaining
    }
}
