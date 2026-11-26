import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// BreathJourneyViews.swift - the cards that sit around the Breathe trainer: today's progress and streak,
// "start by goal" shortcuts, the end-of-session summary, and the session history. Pure presentation over
// `BreathSession` values; the trainer itself (BreathingView) owns the session and the log.

// MARK: - Formatting

enum BreathFormat {
    /// "4:05" for a duration in seconds.
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "Nov 24, 6:12 PM" style stamp for a session start.
    static func stamp(_ startedAt: Double) -> String {
        Date(timeIntervalSince1970: startedAt).formatted(date: .abbreviated, time: .shortened)
    }

    /// Single-letter weekday labels for the `count` days ending today, oldest first.
    static func weekdayLetters(endingAt now: Date = Date(), count: Int = 7) -> [String] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return (0..<count).map { i in
            let d = cal.date(byAdding: .day, value: -(count - 1 - i), to: now) ?? now
            return f.string(from: d)
        }
    }
}

// MARK: - Today card (goal ring, streak, week)

struct BreathTodayCard: View {
    let sessions: [BreathSession]
    let today: String
    @Binding var goalMinutes: Int

    private var todaySeconds: Int { BreathSessionStats.seconds(on: today, sessions: sessions) }
    private var progress: Double {
        BreathSessionStats.goalProgress(today: today, goalMinutes: goalMinutes, sessions: sessions)
    }
    private var streaks: StreakCalculator.Streaks { BreathSessionStats.streaks(today: today, sessions: sessions) }
    private var week: [Int] { BreathSessionStats.dailyMinutes(endingAt: today, days: 7, sessions: sessions) }

    var body: some View {
        StrandCard(padding: 16, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(alignment: .center, spacing: NoopMetrics.space4) {
                    ring
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today").strandOverline()
                        Text("\(todaySeconds / 60) of \(goalMinutes) min")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        HStack(spacing: 6) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(streaks.current > 0 ? StrandPalette.metricAmber : StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                            Text(streakLine)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    goalMenu
                }
                weekBars
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var streakLine: String {
        if streaks.current == 0 {
            return streaks.longest > 0 ? "No streak yet · best \(streaks.longest) days" : "Breathe today to start a streak"
        }
        return "\(streaks.current)-day streak · best \(streaks.longest)"
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.hairlineStrong, lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(progress))
                .stroke(StrandPalette.restBright, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: progress >= 1 ? "checkmark" : "wind")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.restBright)
        }
        .frame(width: 62, height: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Daily breathing goal"))
        .accessibilityValue(Text("\(Int((progress * 100).rounded())) percent"))
    }

    private var goalMenu: some View {
        Menu {
            ForEach(BreathSessionStore.goalChoices, id: \.self) { minutes in
                Button {
                    goalMinutes = minutes
                } label: {
                    if minutes == goalMinutes {
                        Label("\(minutes) min a day", systemImage: "checkmark")
                    } else {
                        Text("\(minutes) min a day")
                    }
                }
            }
        } label: {
            Label("Goal", systemImage: "target")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityLabel(Text("Daily goal"))
    }

    private var weekBars: some View {
        let letters = BreathFormat.weekdayLetters()
        let peak = max(goalMinutes, week.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
            ForEach(Array(week.enumerated()), id: \.offset) { index, minutes in
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(StrandPalette.surfaceInset)
                            .frame(height: 36)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(minutes >= goalMinutes ? StrandPalette.restBright : StrandPalette.restColor)
                            .frame(height: minutes > 0 ? max(4, 36 * CGFloat(minutes) / CGFloat(peak)) : 0)
                    }
                    Text(index < letters.count ? letters[index] : "")
                        .font(StrandFont.overline)
                        .foregroundStyle(index == week.count - 1 ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(minutes) minutes"))
            }
        }
    }
}

// MARK: - Start by goal

/// A named intention mapped to one catalog protocol, so a newcomer can start from what they want to feel
/// rather than from a technique name.
struct BreathIntent: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let blurb: String
    let protocolId: String

    static let all: [BreathIntent] = [
        BreathIntent(id: "calm", title: "Calm", icon: "leaf.fill",
                     blurb: "Longer exhales to settle down", protocolId: "relax_4_6"),
        BreathIntent(id: "sleep", title: "Sleep", icon: "moon.stars.fill",
                     blurb: "4-7-8 to wind down for bed", protocolId: "four_seven_eight"),
        BreathIntent(id: "focus", title: "Focus", icon: "scope",
                     blurb: "Box breathing to steady attention", protocolId: "box_4_4_4_4"),
        BreathIntent(id: "balance", title: "Balance", icon: "circle.lefthalf.filled",
                     blurb: "Coherence pace for HRV", protocolId: "coherence_5_5"),
        BreathIntent(id: "energy", title: "Energy", icon: "bolt.fill",
                     blurb: "Brisk bellows breath to wake up", protocolId: "bhastrika"),
    ]

    /// Only intents whose protocol exists in the catalog, so a renamed id never yields a dead card.
    static var available: [BreathIntent] {
        all.filter { BreathProtocolCatalog.protocolById($0.protocolId) != nil }
    }
}

struct BreathIntentRow: View {
    let selectedProtocolId: String?
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Start by goal").strandOverline()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space3) {
                    ForEach(BreathIntent.available) { intent in
                        Button {
                            onPick(intent.protocolId)
                        } label: {
                            card(intent, selected: intent.protocolId == selectedProtocolId)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(intent.title). \(intent.blurb)"))
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(_ intent: BreathIntent, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: intent.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(selected ? StrandPalette.restBright : StrandPalette.textSecondary)
            Text(intent.title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(intent.blurb)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 148, height: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(StrandPalette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? StrandPalette.restBright : StrandPalette.hairline, lineWidth: selected ? 1.5 : 1)
        )
    }
}

// MARK: - End-of-session summary

struct BreathSummaryCard: View {
    let session: BreathSession
    let streak: Int
    let totalSessions: Int
    let onBreatheAgain: () -> Void

    var body: some View {
        StrandCard(padding: 16, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(StrandPalette.restBright)
                        .accessibilityHidden(true)
                    Text("Session complete")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(session.protocolName)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)

                HStack(spacing: NoopMetrics.space2) {
                    BreathStatTile(label: "Time", value: BreathFormat.clock(session.durationSeconds))
                    if let breaths = session.breaths {
                        BreathStatTile(label: "Breaths", value: "\(breaths)")
                    }
                    if let pct = BreathSessionStats.rmssdPercentChange(session) {
                        BreathStatTile(label: "HRV", value: String(format: "%+d%%", pct))
                    }
                    BreathStatTile(label: "Streak", value: "\(streak)")
                }

                HStack {
                    Text(totalSessions == 1 ? "Your first logged session." : "\(totalSessions) sessions logged.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 8)
                    NoopButton("Breathe again", systemImage: "arrow.clockwise", kind: .secondary) {
                        onBreatheAgain()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BreathStatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).strandOverline()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(StrandPalette.surfaceInset))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - History

struct BreathHistoryCard: View {
    let sessions: [BreathSession]
    let onSeeAll: () -> Void

    var body: some View {
        StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("Recent sessions").strandOverline()
                    Spacer(minLength: 8)
                    if sessions.count > 3 {
                        Button("See all") { onSeeAll() }
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
                if sessions.isEmpty {
                    Text("Sessions of a minute or longer are saved here, with your HRV change when a strap is connected.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(sessions.prefix(3)) { session in
                        BreathHistoryRow(session: session)
                    }
                    HStack(spacing: NoopMetrics.space2) {
                        BreathStatTile(label: "Sessions", value: "\(sessions.count)")
                        BreathStatTile(label: "Total min", value: "\(BreathSessionStats.totalMinutes(sessions))")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BreathHistoryRow: View {
    let session: BreathSession

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: "wind")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.restBright)
                .frame(width: 30, height: 30)
                .background(Circle().fill(StrandPalette.surfaceInset))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.protocolName)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(BreathFormat.stamp(session.startedAt))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(BreathFormat.clock(session.durationSeconds))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let pct = BreathSessionStats.rmssdPercentChange(session) {
                    Text(String(format: "%+d%% HRV", pct))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(pct >= 0 ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The full history, newest first, with swipe-to-delete.
struct BreathHistorySheet: View {
    @Binding var sessions: [BreathSession]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sessions) { session in
                        BreathHistoryRow(session: session)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { sessions[$0].id }
                        for id in ids { sessions = BreathSessionStore.delete(id: id) }
                    }
                } footer: {
                    Text("\(sessions.count) sessions · \(BreathSessionStats.totalMinutes(sessions)) minutes. Stored only on this device.")
                }
            }
            .navigationTitle("Breath sessions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}
