import Foundation
import StrandAnalytics

// SeventyFiveHardStore.swift - on-device state for the opt-in 75-day challenge.
//
// LOCAL-ONLY: the run's start day, the per-day logs and the attempt count live in UserDefaults; progress
// photos are JPEG files under Application Support. Nothing is synced or uploaded. The rules themselves
// (what counts as a complete day, when a run fails) live in `SeventyFiveHard` (Packages/StrandAnalytics).
//
// A stored day log holds what the user entered by hand. Workouts and water that NOOP already knows about
// are merged in by the screen at read time. Once a day is complete it is FROZEN: the merged values are
// written back here, so a later edit to a workout or a water entry cannot fail a day that was already won.

@MainActor
final class SeventyFiveHardStore: ObservableObject {
    static let shared = SeventyFiveHardStore()

    private enum K {
        static let startDay = "seventyFive.startDay"
        static let logs = "seventyFive.logs.v1"
        static let frozen = "seventyFive.frozenDays"
        static let attempts = "seventyFive.attempts"
        static let reminderEnabled = "seventyFive.reminder.enabled"
        static let reminderMinutes = "seventyFive.reminder.minutes"
    }

    private let d = UserDefaults.standard

    /// First day of the current run (`yyyy-MM-dd`), or nil when no run is active.
    @Published private(set) var startDay: String?
    /// Per-day logs keyed by day.
    @Published private(set) var logs: [String: SeventyFiveHard.DayLog]
    /// Days whose log already includes the merged workouts and water (see the file header).
    @Published private(set) var frozenDays: Set<String>
    /// How many runs have been started, including the current one.
    @Published private(set) var attempts: Int
    /// Evening reminder on/off and its time, in minutes since midnight.
    @Published var reminderEnabled: Bool { didSet { d.set(reminderEnabled, forKey: K.reminderEnabled) } }
    @Published var reminderMinutes: Int { didSet { d.set(reminderMinutes, forKey: K.reminderMinutes) } }

    private init() {
        let defaults = UserDefaults.standard
        startDay = defaults.string(forKey: K.startDay)
        if let data = defaults.data(forKey: K.logs),
           let decoded = try? JSONDecoder().decode([String: SeventyFiveHard.DayLog].self, from: data) {
            logs = decoded
        } else {
            logs = [:]
        }
        frozenDays = Set(defaults.stringArray(forKey: K.frozen) ?? [])
        attempts = defaults.integer(forKey: K.attempts)
        reminderEnabled = defaults.bool(forKey: K.reminderEnabled)
        reminderMinutes = defaults.object(forKey: K.reminderMinutes) as? Int ?? 20 * 60
    }

    var isActive: Bool { startDay != nil }

    // MARK: - Run lifecycle

    /// Begin a run with `today` as Day 1, discarding any earlier run's logs and photos.
    func start(today: String) {
        clearRunData()
        startDay = today
        d.set(today, forKey: K.startDay)
        attempts += 1
        d.set(attempts, forKey: K.attempts)
    }

    /// Stop the challenge entirely. Logs and photos of the run are removed.
    func end() {
        clearRunData()
        startDay = nil
        d.removeObject(forKey: K.startDay)
    }

    private func clearRunData() {
        logs = [:]
        frozenDays = []
        persistLogs()
        try? FileManager.default.removeItem(at: Self.photoDirectory)
    }

    // MARK: - Day logs

    /// The stored log for a day (an empty one when nothing has been entered).
    func log(for day: String) -> SeventyFiveHard.DayLog {
        logs[day] ?? SeventyFiveHard.DayLog(dayKey: day)
    }

    func isFrozen(_ day: String) -> Bool { frozenDays.contains(day) }

    /// Change one day's stored log.
    func update(_ day: String, _ change: (inout SeventyFiveHard.DayLog) -> Void) {
        var log = self.log(for: day)
        change(&log)
        log.dayKey = day
        logs[day] = log
        persistLogs()
    }

    /// Write the merged values for a completed day back to the store so they can no longer change.
    func freeze(_ merged: SeventyFiveHard.DayLog) {
        guard !frozenDays.contains(merged.dayKey) else { return }
        logs[merged.dayKey] = merged
        frozenDays.insert(merged.dayKey)
        persistLogs()
    }

    private func persistLogs() {
        if let data = try? JSONEncoder().encode(logs) {
            d.set(data, forKey: K.logs)
        }
        d.set(Array(frozenDays).sorted(), forKey: K.frozen)
    }

    // MARK: - Progress photos

    private static var photoDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SeventyFiveHard", isDirectory: true)
    }

    private static func photoURL(_ day: String) -> URL {
        photoDirectory.appendingPathComponent("\(day).jpg")
    }

    /// Save the day's progress photo (JPEG bytes) and tick the photo task. Returns false if the write fails.
    @discardableResult
    func savePhoto(_ jpeg: Data, day: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: Self.photoDirectory, withIntermediateDirectories: true)
            try jpeg.write(to: Self.photoURL(day), options: .atomic)
        } catch {
            return false
        }
        update(day) { $0.progressPhoto = true }
        return true
    }

    /// The stored photo bytes for a day, if any.
    func photoData(day: String) -> Data? {
        try? Data(contentsOf: Self.photoURL(day))
    }

    /// Remove a day's photo and untick the photo task.
    func removePhoto(day: String) {
        try? FileManager.default.removeItem(at: Self.photoURL(day))
        update(day) { $0.progressPhoto = false }
    }
}
