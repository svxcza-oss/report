#if os(iOS)
import SwiftUI
import WidgetKit
import ActivityKit
import UIKit

// MARK: - 잠금화면 위젯 (동그라미 / 직사각형 / 시계 옆 한 줄)

struct LockEntry: TimelineEntry {
    let date: Date
    let board: Board
}

/// 블록이 시작하고 끝나는 순간마다 새로 그려서 "지금/다음"이 맞게 바뀌어요.
struct LockProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockEntry { LockEntry(date: Date(), board: Board()) }
    func getSnapshot(in context: Context, completion: @escaping (LockEntry) -> Void) {
        completion(LockEntry(date: Date(), board: loadBoard()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LockEntry>) -> Void) {
        guard let cloud = CloudPlan.shared else { return completion(timeline()) }
        Task {
            await cloud.syncNow()
            completion(timeline())
        }
    }
    func timeline() -> Timeline<LockEntry> {
        let now = Date(), board = loadBoard()
        let cal = Calendar(identifier: .gregorian), today = cal.startOfDay(for: now)
        var dates = Set<Date>([now, cal.date(byAdding: .day, value: 1, to: today)!])
        for b in items(board.blocks, on: now) {
            for slot in [b.start, b.end] {
                let d = today.addingTimeInterval(TimeInterval(slot * 600))
                if d > now { dates.insert(d) }
            }
        }
        let entries = dates.sorted().map { LockEntry(date: $0, board: board) }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
    }
}

struct LockSummary {
    let current: Block?
    let next: Block?
    let done: Int
    let total: Int
    let todosLeft: Int

    init(_ entry: LockEntry) {
        let slot = Int(entry.date.timeIntervalSince(Calendar(identifier: .gregorian).startOfDay(for: entry.date)) / 600)
        let list = items(entry.board.blocks, on: entry.date)
        let open = list.filter { !$0.done }
        current = open.first { $0.start <= slot && slot < $0.end }
        next = open.filter { $0.start > slot }.min { $0.start < $1.start }
        let regular = list.filter { !$0.fixed }
        done = regular.filter { $0.done }.count
        total = regular.count
        todosLeft = entry.board.todos.filter { $0.scope == "day" && $0.visible(at: entry.date) && !$0.done(at: entry.date) }.count
    }
}

struct LockView: View {
    let entry: LockEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        let s = LockSummary(entry), en = entry.board.language == "en"
        let shown = s.current ?? s.next
        Group {
            switch family {
            case .accessoryCircular:
                Gauge(value: Double(s.done), in: 0...Double(max(1, s.total))) {
                    Image(systemName: "square.stack.3d.up.fill")
                } currentValueLabel: {
                    Text("\(s.done)/\(s.total)").monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
            case .accessoryInline:
                if let b = shown {
                    Text("\(s.current != nil ? (en ? "Now" : "지금") : clock(b.start, entry.board.language)) \(b.name)")
                } else {
                    Text(en ? "All blocks done" : "오늘 블록 끝 🎉")
                }
            default:
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up.fill")
                        Text(shown == nil ? (en ? "Today" : "오늘") : s.current != nil ? (en ? "Now" : "지금") : (en ? "Next" : "다음"))
                    }
                    .font(.caption2.weight(.semibold))
                    if let b = shown {
                        Text(b.name).font(.headline).lineLimit(1)
                        Text("\(clock(b.start, entry.board.language))–\(clock(b.end, entry.board.language))"
                             + (s.todosLeft > 0 ? (en ? " · \(s.todosLeft) to-dos" : " · 할 일 \(s.todosLeft)개") : ""))
                            .font(.caption2).monospacedDigit()
                    } else {
                        Text(s.total > 0 ? (en ? "All done 🎉" : "다 끝냈어요 🎉") : (en ? "No blocks today" : "오늘 블록 없음")).font(.headline)
                        Text(en ? "\(s.todosLeft) to-dos left" : "남은 할 일 \(s.todosLeft)개").font(.caption2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        .widgetURL(URL(string: "hanju://day/\(dayKey(entry.date))"))
    }
}

struct HanjuLockWidget: Widget {
    let kind = "HanjuLock"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockProvider()) { LockView(entry: $0) }
            .configurationDisplayName("한 주 쌓기 잠금화면")
            .description("지금·다음 블록과 오늘 완료 개수를 잠금화면에서 봐요.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - 실시간 현황 (잠금화면 아래 + 다이내믹 아일랜드)

let lesserFace: Image = {
    if let image = UIImage(named: "frame-05") { return Image(uiImage: image).interpolation(.none) }
    return Image(systemName: "square.stack.3d.up.fill")
}()

func liveTint(_ state: HanjuBlockActivity.ContentState) -> Color { blockColor(max(1, state.color)) }

func liveTime(_ date: Date) -> String {
    let c = Calendar(identifier: .gregorian).dateComponents([.hour, .minute], from: date)
    return String(format: "%d:%02d", c.hour ?? 0, c.minute ?? 0)
}

struct LiveDoneButton: View {
    let context: ActivityViewContext<HanjuBlockActivity>
    var body: some View {
        Button(intent: CompleteLiveBlockIntent(blockID: context.attributes.blockID)) {
            Label("완료", systemImage: "checkmark").font(.caption.weight(.bold))
        }
        .tint(liveTint(context.state))
    }
}

struct LiveBlockLockView: View {
    let context: ActivityViewContext<HanjuBlockActivity>
    var body: some View {
        let s = context.state
        HStack(spacing: 12) {
            lesserFace.resizable().scaledToFit().frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(Date() < s.start ? "다음 · \(liveTime(s.start)) 시작" : "함께 진행 중")
                    .font(.caption).foregroundStyle(.secondary)
                Text(s.name).font(.headline).lineLimit(1)
                ProgressView(timerInterval: s.start...s.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(liveTint(s))
            }
            VStack(alignment: .trailing, spacing: 6) {
                Text(timerInterval: s.start...s.end, countsDown: true)
                    .font(.title3.weight(.semibold)).monospacedDigit().multilineTextAlignment(.trailing).frame(width: 84)
                LiveDoneButton(context: context)
            }
        }
        .padding(14)
        .activityBackgroundTint(Color(.systemBackground).opacity(0.85))
    }
}

struct HanjuLiveBlock: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HanjuBlockActivity.self) { context in
            LiveBlockLockView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    lesserFace.resizable().scaledToFit().frame(width: 40, height: 40)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                        .font(.title3.weight(.semibold)).monospacedDigit().frame(width: 80)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.name).font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        ProgressView(timerInterval: context.state.start...context.state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                            .tint(liveTint(context.state))
                        LiveDoneButton(context: context)
                    }
                }
            } compactLeading: {
                lesserFace.resizable().scaledToFit().frame(width: 22, height: 22)
            } compactTrailing: {
                Text(timerInterval: context.state.start...context.state.end, countsDown: true)
                    .monospacedDigit().frame(width: 48).foregroundStyle(liveTint(context.state))
            } minimal: {
                lesserFace.resizable().scaledToFit().frame(width: 20, height: 20)
            }
            .widgetURL(URL(string: "hanju://day/\(LiveBlocks.dayKey(context.state.start))"))
        }
    }
}
#endif
