import SwiftUI
import Foundation
import PhotosUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// SeventyFiveHardView.swift - the opt-in 75-day challenge screen.
//
// Strict mode: every task, every day; a fully elapsed day with anything left open ends the run and the
// challenge restarts from Day 1. Workouts and water are filled in from what NOOP already has (detected or
// imported workouts, the hydration log); the remaining tasks are ticked by hand. Everything stays on the
// device. The rules live in `SeventyFiveHard` (Packages/StrandAnalytics), the state in
// `SeventyFiveHardStore`.

struct SeventyFiveHardView: View {

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store = SeventyFiveHardStore.shared
    @Environment(\.scenePhase) private var scenePhase

    /// Today's local day key. Refreshed when the app returns to the foreground so the screen rolls over.
    @State private var today = Repository.localDayKey(Date())
    /// Minutes of each workout NOOP knows about, by day.
    @State private var autoWorkouts: [String: [Int]] = [:]
    /// Water NOOP has for each day of the run (ml), by day.
    @State private var autoWater: [String: Double] = [:]
    @State private var loaded = false

    /// A past day opened for review after a miss.
    @State private var reviewDay: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var photoThumbs: [String: PlatformImage] = [:]
    /// The day the in-app camera is capturing for (iPhone only); nil while the camera is closed.
    @State private var cameraDay: String?

    @State private var confirmStart = false
    @State private var confirmRestart = false
    @State private var confirmEnd = false
    @State private var reminderDenied = false

    var body: some View {
        ScreenScaffold(title: "75 Hard",
                       subtitle: "Every task, every day · miss one and it's back to Day 1",
                       onRefresh: { await repo.refresh(); await reload() },
                       topBackground: liquidScaffoldSky()) {
            if !store.isActive {
                introCard
                rulesCard
            } else if !loaded {
                StrandCard(padding: 16) {
                    Text("Loading your challenge…")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                switch status.state {
                case .failed:
                    heroCard
                    failedCard
                case .completed:
                    completedCard
                    photoStrip
                case .active, .notStarted:
                    heroCard
                    dayStrip
                    checklistCard(for: today, title: "Today's tasks")
                    photoStrip
                    reminderCard
                    rulesCard
                    endCard
                }
            }
        }
        .task(id: repo.refreshSeq) { await reload() }
        .task(id: repo.hydrationSeq) { await reload() }
        .onChangeCompat(of: scenePhase) { phase in
            guard phase == .active else { return }
            today = Repository.localDayKey(Date())
            Task { await reload() }
        }
        .onChangeCompat(of: photoItem) { item in
            guard let item else { return }
            let day = reviewDay ?? today
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    if let data { storePhoto(data, day: day) }
                    photoItem = nil
                }
            }
        }
        .sheet(isPresented: reviewSheetBinding) {
            reviewSheet
        }
        .confirmationDialog("Start 75 Hard today?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start Day 1") { store.start(today: today); Task { await reload() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Today becomes Day 1. Every task has to be finished every day for 75 days.")
        }
        .confirmationDialog("Restart from Day 1?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart today", role: .destructive) { store.start(today: today); Task { await reload() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This run's checklist history and progress photos are removed and today becomes Day 1.")
        }
        .confirmationDialog("End the challenge?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End challenge", role: .destructive) {
                store.end()
                SeventyFiveHardReminder.cancel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This run's checklist history and progress photos are removed.")
        }
        .alert("Notifications are off for NOOP", isPresented: $reminderDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow notifications for NOOP in the system Settings to get the evening reminder.")
        }
    }

    // MARK: - Derived state

    /// The day's log as the rules see it: what was entered by hand plus the workouts and water NOOP has.
    /// A frozen day already contains the merged values.
    private func effectiveLog(_ day: String) -> SeventyFiveHard.DayLog {
        var log = store.log(for: day)
        guard !store.isFrozen(day) else { return log }
        log.workoutMinutes = (autoWorkouts[day] ?? []) + log.workoutMinutes
        log.waterML = max(log.waterML, Int((autoWater[day] ?? 0).rounded()))
        return log
    }

    private var runDays: [String] {
        guard let start = store.startDay else { return [] }
        return SeventyFiveHard.dayKeys(startDay: start, through: today)
    }

    private var status: SeventyFiveHard.Status {
        guard let start = store.startDay else {
            return SeventyFiveHard.Status(state: .notStarted, dayNumber: 0, completedDays: 0, failedDayKey: nil)
        }
        return SeventyFiveHard.status(startDay: start, today: today, logs: runDays.map { effectiveLog($0) })
    }

    private var reviewSheetBinding: Binding<Bool> {
        Binding(get: { reviewDay != nil }, set: { if !$0 { reviewDay = nil } })
    }

    // MARK: - Loading

    private func reload() async {
        guard let start = store.startDay else {
            autoWorkouts = [:]
            autoWater = [:]
            loaded = true
            return
        }
        let days = SeventyFiveHard.dayKeys(startDay: start, through: today)
        let span = (SeventyFiveHard.daysBetween(start, today) ?? SeventyFiveHard.totalDays) + 3
        let rows = await repo.workoutRows(days: max(span, 7))
        var workouts: [String: [Int]] = [:]
        for row in rows {
            let key = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
            let seconds = row.durationS ?? Double(row.endTs - row.startTs)
            let minutes = Int(seconds / 60)
            if minutes > 0 { workouts[key, default: []].append(minutes) }
        }
        var water: [String: Double] = [:]
        for day in days where !store.isFrozen(day) {
            water[day] = await repo.hydrationTotal(day: day)
        }
        autoWorkouts = workouts
        autoWater = water
        loaded = true
        freezeCompletedDays(days)
        loadThumbs()
        syncReminder()
    }

    /// Lock in every elapsed day that is complete, so later edits elsewhere cannot undo it.
    private func freezeCompletedDays(_ days: [String]) {
        for day in days where day != today && !store.isFrozen(day) {
            let merged = effectiveLog(day)
            if SeventyFiveHard.isComplete(merged) { store.freeze(merged) }
        }
    }

    private func loadThumbs() {
        var thumbs: [String: PlatformImage] = [:]
        for day in runDays.suffix(14) where store.log(for: day).progressPhoto {
            if let data = store.photoData(day: day), let image = PlatformImage(data: data) {
                thumbs[day] = image
            }
        }
        photoThumbs = thumbs
    }

    private func syncReminder() {
        let todayDone = SeventyFiveHard.isComplete(effectiveLog(today))
        SeventyFiveHardReminder.reschedule(enabled: store.reminderEnabled,
                                           active: store.isActive && status.state == .active,
                                           todayComplete: todayDone,
                                           minutes: store.reminderMinutes)
    }

    /// Downscale a picked or captured photo, save it for the day and refresh what depends on it.
    private func storePhoto(_ data: Data, day: String) {
        let jpeg = AvatarImage.downscaledJPEG(from: data, maxDimension: 1280, quality: 0.8) ?? data
        store.savePhoto(jpeg, day: day)
        loadThumbs()
        afterChange()
    }

    /// Run after any hand edit: keep the reminder queue in step with the checklist.
    private func afterChange() {
        syncReminder()
    }

    // MARK: - Intro (no run yet)

    private var introCard: some View {
        StrandCard(padding: 18, tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("75 days. No days off.")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("A daily checklist with strict rules. NOOP fills in your workouts and water where it can; you tick the rest. Miss anything and the count goes back to Day 1.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.attempts > 0 {
                    Text("Runs started so far: \(store.attempts)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                NoopButton("Start Day 1 today", systemImage: "flag.checkered", kind: .primary, fullWidth: true) {
                    confirmStart = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rulesCard: some View {
        StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("The daily tasks").strandOverline()
                ForEach(SeventyFiveHard.Task.allCases, id: \.self) { task in
                    HStack(alignment: .top, spacing: NoopMetrics.space3) {
                        Image(systemName: Self.icon(task))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(Self.rule(task))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("This is a personal challenge tracker, not medical or training advice.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        let s = status
        let todayLog = effectiveLog(today)
        let total = SeventyFiveHard.Task.allCases.count
        let done = total - SeventyFiveHard.remaining(todayLog).count
        return StrandCard(padding: 18, tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(alignment: .center, spacing: NoopMetrics.space4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.attempts > 1 ? "Run \(store.attempts)" : "75 Hard").strandOverline()
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("Day \(s.dayNumber)")
                                .font(StrandFont.rounded(40))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("/ \(SeventyFiveHard.totalDays)")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    taskRing(done: done, total: total)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(s.completedDays), total: Double(SeventyFiveHard.totalDays))
                        .tint(StrandPalette.effortBright)
                    Text("\(s.completedDays) of \(SeventyFiveHard.totalDays) days complete")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func taskRing(done: Int, total: Int) -> some View {
        let fraction = total > 0 ? CGFloat(done) / CGFloat(total) : 0
        return ZStack {
            Circle().stroke(StrandPalette.hairlineStrong, lineWidth: 8)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(done == total ? StrandPalette.statusPositive : StrandPalette.effortBright,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(done)/\(total)")
                    .font(StrandFont.number(18))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("today").strandOverline()
            }
        }
        .frame(width: 78, height: 78)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Today's tasks"))
        .accessibilityValue(Text("\(done) of \(total) done"))
    }

    // MARK: - Day strip

    private var dayStrip: some View {
        let current = max(1, status.dayNumber)
        let first = max(1, current - 5)
        let last = min(SeventyFiveHard.totalDays, first + 9)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NoopMetrics.space2) {
                ForEach(Array(first...last), id: \.self) { number in
                    dayPill(number: number, current: current)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func dayPill(number: Int, current: Int) -> some View {
        let key = store.startDay.flatMap { SeventyFiveHard.dayKey(startDay: $0, offset: number - 1) }
        let complete = key.map { SeventyFiveHard.isComplete(effectiveLog($0)) } ?? false
        let isToday = number == current
        let isFuture = number > current
        return VStack(spacing: 4) {
            Text("\(number)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(isToday ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            Image(systemName: complete ? "checkmark.circle.fill" : (isFuture ? "circle.dotted" : "circle"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(complete ? StrandPalette.statusPositive
                                 : (isToday ? StrandPalette.effortBright : StrandPalette.textTertiary))
        }
        .frame(width: 44, height: 56)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isToday ? StrandPalette.surfaceRaised : StrandPalette.surfaceInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isToday ? StrandPalette.effortBright : StrandPalette.hairline, lineWidth: isToday ? 1.5 : 1)
        )
        .opacity(isFuture ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Day \(number)"))
        .accessibilityValue(Text(complete ? "complete" : (isToday ? "in progress" : (isFuture ? "upcoming" : "incomplete"))))
    }

    // MARK: - Checklist

    private func checklistCard(for day: String, title: String) -> some View {
        let log = effectiveLog(day)
        let remaining = SeventyFiveHard.remaining(log).count
        return StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack {
                    Text(title).strandOverline()
                    Spacer(minLength: 8)
                    Text(remaining == 0 ? "All done" : "\(remaining) left")
                        .font(StrandFont.caption)
                        .foregroundStyle(remaining == 0 ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                }
                workoutsRow(day: day, log: log)
                Divider().overlay(StrandPalette.hairline)
                toggleRow(.outdoorWorkout, day: day, log: log,
                          detail: "Tick once a 45-minute session was outside.") { $0.outdoorWorkout.toggle() }
                Divider().overlay(StrandPalette.hairline)
                waterRow(day: day, log: log)
                Divider().overlay(StrandPalette.hairline)
                readingRow(day: day, log: log)
                Divider().overlay(StrandPalette.hairline)
                toggleRow(.diet, day: day, log: log,
                          detail: "Your chosen plan, no cheat meals.") { $0.dietFollowed.toggle() }
                Divider().overlay(StrandPalette.hairline)
                toggleRow(.noAlcohol, day: day, log: log, detail: "Nothing alcoholic today.") { $0.noAlcohol.toggle() }
                Divider().overlay(StrandPalette.hairline)
                photoRow(day: day, log: log)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusIcon(_ done: Bool) -> some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(done ? StrandPalette.statusPositive : StrandPalette.textTertiary)
            .frame(width: 30)
    }

    private func rowText(_ task: SeventyFiveHard.Task, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.title(task))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(detail)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A task that is simply ticked by hand. The whole row is the button.
    private func toggleRow(_ task: SeventyFiveHard.Task, day: String, log: SeventyFiveHard.DayLog, detail: String,
                           change: @escaping (inout SeventyFiveHard.DayLog) -> Void) -> some View {
        let done = SeventyFiveHard.isDone(task, in: log)
        return Button {
            store.update(day, change)
            afterChange()
        } label: {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                statusIcon(done)
                rowText(task, detail: detail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.title(task)))
        .accessibilityValue(Text(done ? "done" : "not done"))
    }

    private func workoutsRow(day: String, log: SeventyFiveHard.DayLog) -> some View {
        let done = SeventyFiveHard.isDone(.workouts, in: log)
        let manual = store.isFrozen(day) ? [] : store.log(for: day).workoutMinutes
        let detail: String = log.workoutMinutes.isEmpty
            ? "None yet. Workouts NOOP detects or imports appear here."
            : log.workoutMinutes.map { "\($0) min" }.joined(separator: " · ")
                + "  (\(SeventyFiveHard.qualifyingWorkouts(log)) of \(SeventyFiveHard.requiredWorkouts) count)"
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                statusIcon(done)
                rowText(.workouts, detail: detail)
                Spacer(minLength: 0)
            }
            if !store.isFrozen(day) {
                HStack(spacing: NoopMetrics.space2) {
                    Menu {
                        ForEach([45, 60, 75, 90], id: \.self) { minutes in
                            Button("\(minutes) minutes") {
                                store.update(day) { $0.workoutMinutes.append(minutes) }
                                afterChange()
                            }
                        }
                    } label: {
                        Label("Add a workout", systemImage: "plus.circle")
                            .font(StrandFont.caption)
                    }
                    if !manual.isEmpty {
                        Button {
                            store.update(day) { if !$0.workoutMinutes.isEmpty { $0.workoutMinutes.removeLast() } }
                            afterChange()
                        } label: {
                            Label("Remove last added", systemImage: "minus.circle")
                                .font(StrandFont.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .padding(.leading, 42)
            }
        }
    }

    private func waterRow(day: String, log: SeventyFiveHard.DayLog) -> some View {
        let done = SeventyFiveHard.isDone(.water, in: log)
        let ounces = Int((Double(log.waterML) / 29.5735).rounded())
        let detail = "\(ounces) of 128 fl oz · \(log.waterML) of \(SeventyFiveHard.waterGoalML) ml"
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                statusIcon(done)
                rowText(.water, detail: detail)
                Spacer(minLength: 0)
            }
            ProgressView(value: min(Double(log.waterML), Double(SeventyFiveHard.waterGoalML)),
                         total: Double(SeventyFiveHard.waterGoalML))
                .tint(StrandPalette.metricCyan)
                .padding(.leading, 42)
            if !store.isFrozen(day) {
                HStack(spacing: NoopMetrics.space2) {
                    waterButton("+8 oz", ml: 237, day: day)
                    waterButton("+16 oz", ml: 473, day: day)
                    waterButton("+32 oz", ml: 946, day: day)
                }
                .padding(.leading, 42)
            }
        }
    }

    private func waterButton(_ label: String, ml: Int, day: String) -> some View {
        Button {
            Task {
                await repo.logHydration(amountMl: ml, day: day)
                await reload()
            }
        } label: {
            Text(label)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.vertical, 7)
                .padding(.horizontal, 12)
                .background(Capsule().fill(StrandPalette.surfaceInset))
                .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add \(label) of water"))
    }

    private func readingRow(day: String, log: SeventyFiveHard.DayLog) -> some View {
        let done = SeventyFiveHard.isDone(.reading, in: log)
        return HStack(alignment: .center, spacing: NoopMetrics.space3) {
            statusIcon(done)
            rowText(.reading, detail: "\(log.pagesRead) of \(SeventyFiveHard.pagesGoal) pages · non-fiction")
            Spacer(minLength: 0)
            HStack(spacing: NoopMetrics.space2) {
                Button {
                    store.update(day) { $0.pagesRead = max(0, $0.pagesRead - 1) }
                    afterChange()
                } label: {
                    Image(systemName: "minus.circle").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.textSecondary)
                .disabled(log.pagesRead == 0)
                .accessibilityLabel(Text("One page fewer"))
                Button {
                    store.update(day) { $0.pagesRead += 1 }
                    afterChange()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel(Text("One page more"))
                Button {
                    store.update(day) { $0.pagesRead = max($0.pagesRead, SeventyFiveHard.pagesGoal) }
                    afterChange()
                } label: {
                    Text("10")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Capsule().fill(StrandPalette.surfaceInset))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Mark ten pages read"))
            }
        }
    }

    private func photoRow(day: String, log: SeventyFiveHard.DayLog) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            statusIcon(log.progressPhoto)
            rowText(.progressPhoto, detail: log.progressPhoto ? "Saved on this device only." : "Take one now or choose one from your library.")
            Spacer(minLength: 0)
            if let image = photoThumbs[day] {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            #if os(iOS)
            if CameraCapture.isAvailable {
                Button {
                    cameraDay = day
                } label: {
                    Image(systemName: "camera.fill").font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel(Text("Take a progress photo"))
            }
            #endif
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 18))
            }
            .accessibilityLabel(Text(log.progressPhoto ? "Replace with a photo from your library" : "Choose a photo from your library"))
        }
        #if os(iOS)
        // Attached to the row, not the screen, so the camera can also open from the review sheet.
        .fullScreenCover(isPresented: cameraBinding(for: day)) {
            CameraCapture { data in
                if let data { storePhoto(data, day: day) }
                cameraDay = nil
            }
            .ignoresSafeArea()
        }
        #endif
    }

    private func cameraBinding(for day: String) -> Binding<Bool> {
        Binding(get: { cameraDay == day }, set: { if !$0 { cameraDay = nil } })
    }

    // MARK: - Photos

    @ViewBuilder private var photoStrip: some View {
        let days = runDays.filter { photoThumbs[$0] != nil }
        if !days.isEmpty {
            StrandCard(padding: 16) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text("Progress photos").strandOverline()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NoopMetrics.space2) {
                            ForEach(days, id: \.self) { day in
                                VStack(spacing: 4) {
                                    if let image = photoThumbs[day] {
                                        Image(platformImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 84, height: 112)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    Text(dayLabel(day))
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                            }
                        }
                    }
                    Text("The most recent two weeks. Photos never leave this device.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func dayLabel(_ day: String) -> String {
        guard let start = store.startDay, let offset = SeventyFiveHard.daysBetween(start, day) else { return day }
        return "Day \(offset + 1)"
    }

    // MARK: - Reminder

    private var reminderCard: some View {
        StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Toggle(isOn: reminderToggleBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Evening reminder")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Only on days that still have open tasks.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .tint(StrandPalette.accent)
                if store.reminderEnabled {
                    DatePicker("Remind me at", selection: reminderTimeBinding, displayedComponents: .hourAndMinute)
                        .font(StrandFont.subhead)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var reminderToggleBinding: Binding<Bool> {
        Binding(get: { store.reminderEnabled }, set: { on in
            guard on else {
                store.reminderEnabled = false
                SeventyFiveHardReminder.cancel()
                return
            }
            SeventyFiveHardReminder.requestPermission { granted in
                store.reminderEnabled = granted
                reminderDenied = !granted
                syncReminder()
            }
        })
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(get: {
            let cal = Calendar.current
            let startOfDay = cal.startOfDay(for: Date())
            return cal.date(byAdding: .minute, value: store.reminderMinutes, to: startOfDay) ?? Date()
        }, set: { date in
            let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
            store.reminderMinutes = (comps.hour ?? 20) * 60 + (comps.minute ?? 0)
            syncReminder()
        })
    }

    // MARK: - Failed / completed / end

    private var failedCard: some View {
        let failedDay = status.failedDayKey ?? today
        let open = SeventyFiveHard.remaining(effectiveLog(failedDay))
        return StrandCard(padding: 18, tint: StrandPalette.statusCritical) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusCritical)
                        .accessibilityHidden(true)
                    Text("\(dayLabel(failedDay)) was missed")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Left open: " + open.map { Self.title($0) }.joined(separator: ", ") + ".")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Strict rules mean the run starts again from Day 1. If you did finish that day and only forgot to tick something, review it first.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Review that day", systemImage: "list.bullet.clipboard", kind: .secondary, fullWidth: true) {
                    reviewDay = failedDay
                }
                NoopButton("Restart from Day 1", systemImage: "arrow.counterclockwise", kind: .destructive, fullWidth: true) {
                    confirmRestart = true
                }
                Button("End the challenge instead") { confirmEnd = true }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var completedCard: some View {
        StrandCard(padding: 18, tint: StrandPalette.gold) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: 8) {
                    Image(systemName: "trophy.fill")
                        .foregroundStyle(StrandPalette.gold)
                        .accessibilityHidden(true)
                    Text("75 days complete")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(store.attempts > 1 ? "Finished on run \(store.attempts). Every task, every day."
                                        : "Finished on the first run. Every task, every day.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Start a new run", systemImage: "flag.checkered", kind: .secondary, fullWidth: true) {
                    confirmRestart = true
                }
                Button("Close the challenge") { confirmEnd = true }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var endCard: some View {
        Button("End the challenge") { confirmEnd = true }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, NoopMetrics.space2)
    }

    // MARK: - Review sheet (a missed day)

    private var reviewSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    if let day = reviewDay {
                        Text("Only tick what you actually finished that day. Once every task is done the run continues.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        checklistCard(for: day, title: dayLabel(day))
                    }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Review day")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        reviewDay = nil
                        Task { await reload() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }

    // MARK: - Copy

    static func title(_ task: SeventyFiveHard.Task) -> String {
        switch task {
        case .workouts:       return "Two 45-minute workouts"
        case .outdoorWorkout: return "One workout outdoors"
        case .water:          return "A gallon of water"
        case .reading:        return "Read 10 pages"
        case .diet:           return "Stick to the diet"
        case .noAlcohol:      return "No alcohol"
        case .progressPhoto:  return "Progress photo"
        }
    }

    static func rule(_ task: SeventyFiveHard.Task) -> String {
        switch task {
        case .workouts:       return "Two workouts of at least 45 minutes each. Workouts NOOP detects or imports are counted for you."
        case .outdoorWorkout: return "One of the two has to be outdoors, whatever the weather."
        case .water:          return "Drink one US gallon (128 fl oz, 3,785 ml). Water logged in NOOP or Apple Health counts."
        case .reading:        return "Read ten pages of a non-fiction book."
        case .diet:           return "Follow a diet of your choosing, with no cheat meals."
        case .noAlcohol:      return "No alcohol."
        case .progressPhoto:  return "Take a progress photo. It is stored only on this device."
        }
    }

    static func icon(_ task: SeventyFiveHard.Task) -> String {
        switch task {
        case .workouts:       return "figure.strengthtraining.traditional"
        case .outdoorWorkout: return "sun.max.fill"
        case .water:          return "drop.fill"
        case .reading:        return "book.fill"
        case .diet:           return "fork.knife"
        case .noAlcohol:      return "wineglass"
        case .progressPhoto:  return "camera.fill"
        }
    }
}
