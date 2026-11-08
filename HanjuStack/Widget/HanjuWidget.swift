import SwiftUI
import WidgetKit
#if os(macOS)
import AppKit
#endif
import AppIntents
import CoreText

// 한 주 쌓기 위젯 — reads (and edits) the copy the app keeps inside this extension's container.
// v4 uses ten-minute slots; older saves are converted only when reading.


struct Block: Identifiable {
    let id: String
    let name: String
    let len: Int
    let color: Int
    let date: String
    let start: Int
    let done: Bool
    var fixed: Bool = false   // 매주 반복 일정
    var wd: Int = 0           // 반복 요일 (월 = 0)
    var end: Int { start + len }
}

/// Visible hours, set in the app (default 8시–24시).
struct DayRange {
    var from = 8
    var to = 24
    var first: Int { from * 6 }
    var last: Int { to * 6 }
    var slots: Int { max(1, last - first) }
}

/// 시간 없는 공통 할 일. scope "day" 는 매일, "week" 는 월요일마다 체크가 새로 시작돼요.
struct Todo: Identifiable {
    let id: String
    let text: String
    let scope: String
    let doneOn: String?
    var repeats = false
    func done(at date: Date) -> Bool { doneOn != nil && doneOn == todoPeriod(scope, date) }
    /// 한 번짜리는 체크한 날(주)이 지나면 사라져요. ↻ 반복은 계속 남아요.
    func visible(at date: Date) -> Bool { repeats || doneOn == nil || doneOn! >= todoPeriod(scope, date) }
}

func todoPeriod(_ scope: String, _ date: Date) -> String {
    scope == "week" ? dayKey(weekDates(of: date)[0]) : dayKey(date)
}

struct Board {
    var todos: [Todo] = []
    var blocks: [Block] = []
    var range = DayRange()
    var language = HanjuLanguage.system
    var dark = false          // 앱의 절전 모드(어두운 화면)
    var challenges: [[String: Any]] = []   // 챌린지 (오늘의 Day는 그리는 날짜로 정해요)
    func challenge(at date: Date) -> ChallengeToday? { Challenge.today(challenges, now: date) }
}

extension View {
    /// 앱에서 고른 라이트/절전 모드를 위젯에도 적용
    func boardLook(_ board: Board) -> some View {
        self.environment(\.colorScheme, board.dark ? .dark : .light)
            .containerBackground(for: .widget) {
                board.dark ? Color(red: 0.09, green: 0.10, blue: 0.13).opacity(0.92)
                           : Color(red: 0.95, green: 0.96, blue: 0.98).opacity(0.92)
            }
    }
}

func monthDay(_ d: Date) -> String {
    let cal = Calendar(identifier: .gregorian)
    return "\(cal.component(.month, from: d))/\(cal.component(.day, from: d))"
}

/// 나눔고딕 (위젯 안 Fonts 폴더에 들어 있음, SIL OFL)
let nanumRegistered: Bool = {
    guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts"), !urls.isEmpty else { return false }
    CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    return true
}()
func wf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    guard nanumRegistered else { return .system(size: size, weight: weight) }
    let name = weight == .heavy || weight == .black ? "NanumGothicExtraBold"
        : (weight == .bold || weight == .semibold) ? "NanumGothicBold" : "NanumGothic"
    return Font.custom(name, size: size)
}

func int(_ v: Any?, _ fallback: Int) -> Int { (v as? NSNumber)?.intValue ?? fallback }

func loadBoard() -> Board {
    guard let store = try? HanjuStore.production(), let root = try? store.read() else { return Board() }
    var board = Board()
    board.language = HanjuLanguage.resolve(root["language"])
    board.dark = root["theme"] as? String == "saver"
    if let r = root["range"] as? [String: Any] {
        let from = min(23, max(0, int(r["from"], 8)))
        let to = min(24, max(from + 1, int(r["to"], 24)))
        board.range = DayRange(from: from, to: to)
    }
    // Saves from before the time-range update counted from 8:00.
    let shift = int(root["v"], 0) >= 3 ? 0 : 16
    let factor = int(root["v"], 0) >= 4 ? 1 : 3
    let weekly: [Block] = ((root["fixed"] as? [[String: Any]]) ?? []).compactMap { r in
        guard let id = r["id"] as? String, let name = r["name"] as? String else { return nil }
        return Block(id: id, name: name, len: max(1, int(r["len"], 2)) * factor, color: 0, date: "",
                     start: max(0, int(r["start"], 0) + shift) * factor, done: false, fixed: true, wd: int(r["wd"], 0))
    }
    let dated: [Block] = ((root["blocks"] as? [[String: Any]]) ?? []).compactMap { r in
        guard let id = r["id"] as? String, let name = r["name"] as? String,
              let date = r["date"] as? String else { return nil }
        return Block(id: id, name: name, len: max(1, int(r["len"], 2)) * factor, color: int(r["c"], 1), date: date,
                     start: max(0, int(r["start"], 0) + shift) * factor, done: (r["done"] as? NSNumber)?.boolValue ?? false)
    }
    // 못 끝낸 블록 다음 날로: 앱을 아직 안 열었어도 위젯에는 지난 7일의 못 끝낸 블록을 오늘에 보여줘요.
    var shown = dated
    if root["rollover"] as? Bool != false {
        let now = Date(), today = dayKey(now)
        let since = dayKey(Calendar(identifier: .gregorian).date(byAdding: .day, value: -7, to: now) ?? now)
        shown = dated.map { b in
            guard !b.done, b.date < today, b.date >= since else { return b }
            return Block(id: b.id, name: b.name, len: b.len, color: b.color, date: today, start: b.start, done: false)
        }
    }
    board.blocks = weekly + shown
    board.challenges = root["challenges"] as? [[String: Any]] ?? []
    board.todos = ((root["todos"] as? [[String: Any]]) ?? []).compactMap { r in
        guard let id = r["id"] as? String, let text = r["text"] as? String else { return nil }
        return Todo(id: id, text: text, scope: r["scope"] as? String == "week" ? "week" : "day", doneOn: r["doneOn"] as? String,
                    repeats: (r["repeat"] as? Bool) == true)
    }
    return board
}

func dayKey(_ d: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: d)
}

func weekDates(of d: Date) -> [Date] {
    let cal = Calendar(identifier: .gregorian)
    let start = cal.startOfDay(for: d)
    let back = (cal.component(.weekday, from: start) + 5) % 7   // Monday = 0
    let monday = cal.date(byAdding: .day, value: -back, to: start)!
    return (0..<7).map { cal.date(byAdding: .day, value: $0, to: monday)! }
}

func weekdayIndex(_ d: Date) -> Int { (Calendar(identifier: .gregorian).component(.weekday, from: d) + 5) % 7 }

/// Blocks shown on one day: that date's blocks plus the weekly ones for its weekday.
func items(_ all: [Block], on day: Date) -> [Block] {
    let key = dayKey(day), wd = weekdayIndex(day)
    return all.filter { $0.fixed ? $0.wd == wd : $0.date == key }.sorted { $0.start < $1.start }
}

func blockColor(_ c: Int) -> Color {
    let hex: [UInt32] = [0x24a9b8, 0xe6b21c, 0x8a56d3, 0x3fa55f, 0xdc4d4a, 0x3f6fd8, 0xe5852a]
    let v = hex[(max(1, c) - 1) % 7]
    return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
}
func inkColor(_ c: Int) -> Color { c == 2 ? Color(red: 0.16, green: 0.13, blue: 0) : .white }
let fixedGray = Color(red: 0.55, green: 0.57, blue: 0.64)
let doneGray = Color(red: 0.62, green: 0.63, blue: 0.66).opacity(0.55)
func fillColor(_ b: Block) -> Color { b.fixed ? fixedGray : b.done ? doneGray : blockColor(b.color) }
func textColor(_ b: Block) -> Color { b.fixed || b.done ? .white : inkColor(b.color) }

func clock(_ slot: Int, _ language: String = "ko") -> String {
    let m = slot * 10, h = m / 60
    if language == "en" { return String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m % 60, h % 24 < 12 ? "AM" : "PM") }
    return String(format: "%d:%02d", h, m % 60)
}

// MARK: - 위젯 안에서 바로 처리하는 버튼 동작 (앱을 열지 않음)

struct ToggleBlockIntent: AppIntent {
    static let title: LocalizedStringResource = "블록 완료 바꾸기"
    @Parameter(title: "블록") var blockID: String
    init() {}
    init(blockID: String) { self.blockID = blockID }
    func perform() async throws -> some IntentResult {
        let id = blockID
        try await editPlan { root, now in
            editRow("blocks", id, in: &root, now: now) { $0["done"] = !(($0["done"] as? NSNumber)?.boolValue ?? false) }
        }
        return .result()
    }
}

struct ToggleTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "할 일 체크 바꾸기"
    @Parameter(title: "할 일") var todoID: String
    init() {}
    init(todoID: String) { self.todoID = todoID }
    func perform() async throws -> some IntentResult {
        let id = todoID, today = Date()
        try await editPlan { root, now in
            editRow("todos", id, in: &root, now: now) { row in
                let period = todoPeriod(row["scope"] as? String == "week" ? "week" : "day", today)
                if row["doneOn"] as? String == period { row["doneOn"] = NSNull() } else { row["doneOn"] = period }
            }
        }
        return .result()
    }
}

struct ToggleChallengeItemIntent: AppIntent {
    static let title: LocalizedStringResource = "챌린지 항목 체크 바꾸기"
    @Parameter(title: "챌린지") var challengeID: String
    @Parameter(title: "항목") var itemID: String
    init() {}
    init(challengeID: String, itemID: String) { self.challengeID = challengeID; self.itemID = itemID }
    func perform() async throws -> some IntentResult {
        let id = challengeID, item = itemID, today = dayKey(Date())
        try await editPlan { root, now in
            editRow("challenges", id, in: &root, now: now) { Challenge.toggle(&$0, item: item, today: today) }
        }
        return .result()
    }
}

struct DeleteBlockIntent: AppIntent {
    static let title: LocalizedStringResource = "블록 삭제"
    @Parameter(title: "블록") var blockID: String
    init() {}
    init(blockID: String) { self.blockID = blockID }
    func perform() async throws -> some IntentResult {
        let id = blockID
        try await editPlan { root, now in
            var blocks = root["blocks"] as? [[String: Any]] ?? []
            blocks.removeAll { ($0["id"] as? String) == id }
            root["blocks"] = blocks
            var dead = root["deleted"] as? [String: Any] ?? [:]
            dead[id] = now
            root["deleted"] = dead
        }
        return .result()
    }
}

// MARK: - Timeline

struct Entry: TimelineEntry {
    let date: Date
    let board: Board
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), board: Board()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), board: loadBoard()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // 새로 그리기 전에 다른 기기에서 바뀐 게 있으면 받아 와요 (iCloud 동기화가 켜진 앱스토어판만).
        guard let cloud = CloudPlan.shared else { return completion(timeline()) }
        Task {
            await cloud.syncNow()
            completion(timeline())
        }
    }

    func timeline() -> Timeline<Entry> {
        let cal = Calendar.current
        let now = Date()
        let board = loadBoard()
        var dates = [now]
        for i in 1...7 {
            if let d = cal.date(byAdding: .day, value: i, to: cal.startOfDay(for: now)) { dates.append(d) }
        }
        // 다른 기기 변경을 놓치지 않게 30분마다도 다시 그려요 (날짜가 바뀌는 자정에도).
        let soon = Entry(date: now.addingTimeInterval(30 * 60), board: board)
        let entries = ([Entry(date: now, board: board), soon] + dates.dropFirst().map { Entry(date: $0, board: board) })
            .sorted { $0.date < $1.date }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60)))
    }
}

// MARK: - 블록 조각

/// One piece of a block. A block can be cut into pieces when it crosses a column edge.
struct Piece: View {
    let block: Block
    let height: CGFloat
    let showText: Bool
    let fontSize: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Button(intent: ToggleBlockIntent(blockID: block.id)) {
            shape.fill(fillColor(block).opacity(0.92))
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if showText && height >= fontSize + 3 {
                        Text((block.done ? "✓ " : block.fixed ? "↻ " : "") + block.name)
                            .font(wf(fontSize, .semibold))
                            .foregroundStyle(textColor(block))
                            .lineLimit(1)
                            .padding(.horizontal, 3)
                            .padding(.top, 1)
                    } else if block.done {
                        Image(systemName: "checkmark").font(wf(7, .heavy))
                            .foregroundStyle(.white).padding(1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(block.fixed)
        .invalidatableContent()
    }
}

/// A vertical strip covering slots [first, last). Pieces are placed with padding so taps land where they're drawn.
struct Strip: View {
    let blocks: [Block]
    let first: Int
    let last: Int
    let showText: Bool
    let fontSize: CGFloat
    var highlight = false

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.height / CGFloat(max(1, last - first))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(highlight ? Color.accentColor : Color.clear, lineWidth: 1))
                ForEach(blocks) { b in
                    let s = max(b.start, first), e = min(b.end, last)
                    if e > s {
                        let h = max(3, unit * CGFloat(e - s) - 1)
                        Piece(block: b, height: h, showText: showText, fontSize: fontSize)
                            .frame(width: max(0, geo.size.width - 2), height: h)
                            .padding(.leading, 1)
                            .padding(.top, unit * CGFloat(s - first))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }
}

// MARK: - 한 주 판 (큰 위젯)

struct WeekView: View {
    let entry: Entry

    var body: some View {
        let days = weekDates(of: entry.date)
        let todayKey = dayKey(entry.date)
        let range = entry.board.range
        let keys = Set(days.map { dayKey($0) })
        let mine = entry.board.blocks.filter { !$0.fixed && keys.contains($0.date) }
        let total = mine.reduce(0) { $0 + $1.len }
        let doneSum = mine.filter { $0.done }.reduce(0) { $0 + $1.len }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(monthDay(days[0])) – \(monthDay(days[6]))").font(wf(14, .heavy)).monospacedDigit()
                Spacer()
                Text(HanjuLanguage.text("완료 ", "Done ", language: entry.board.language) + String(format: "%g / %g", Double(doneSum) / 6, Double(total) / 6) + HanjuLanguage.text("시간", "h", language: entry.board.language))
                    .font(wf(10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    let key = dayKey(days[i])
                    let list = items(entry.board.blocks, on: days[i])
                    let regular = list.filter { !$0.fixed }
                    VStack(spacing: 3) {
                        Link(destination: URL(string: "hanju://day/\(key)")!) {
                            HStack(spacing: 2) {
                                Text(HanjuLanguage.days(entry.board.language)[i]).font(wf(10, .bold))
                                    .foregroundStyle(key == todayKey ? Color.accentColor : Color.primary)
                                if !regular.isEmpty && regular.allSatisfy({ $0.done }) {
                                    Circle().fill(blockColor(4)).frame(width: 5, height: 5)
                                }
                            }
                        }
                        Strip(blocks: list, first: range.first, last: range.last,
                              showText: true, fontSize: 8, highlight: key == todayKey)
                    }
                }
            }
        }
        .boardLook(entry.board)
    }
}

// MARK: - 오늘 (중간 위젯: 시간을 여러 줄로 접어서 쌓기)

/// Today's hours folded into columns, e.g. 9–12 | 13–16 | 17–20 | 21–24.
struct FoldedDayView: View {
    let entry: Entry
    let columns = 4

    var body: some View {
        let range = entry.board.range
        let list = items(entry.board.blocks, on: entry.date)
        let hours = range.to - range.from
        let perCol = max(1, Int((Double(hours) / Double(columns)).rounded(.up)))
        let cols = Int((Double(hours) / Double(perCol)).rounded(.up))
        return VStack(alignment: .leading, spacing: 4) {
            TodayHeader(entry: entry, list: list)
            HStack(alignment: .top, spacing: 6) {
                ForEach(0..<cols, id: \.self) { c in
                    let h0 = range.from + c * perCol
                    let h1 = min(range.to, h0 + perCol)
                    HStack(alignment: .top, spacing: 2) {
                        // hour labels down the left edge of each fold
                        GeometryReader { geo in
                            let step = geo.size.height / CGFloat(perCol)
                            ForEach(0..<(h1 - h0), id: \.self) { k in
                                Text(clock((h0 + k) * 6, entry.board.language))
                                    .font(wf(8, .medium)).monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                                    .padding(.top, step * CGFloat(k))
                            }
                        }
                        .frame(width: 38)
                        // the fold always spans perCol hours so every fold has the same scale
                        Strip(blocks: list, first: h0 * 6, last: h0 * 6 + perCol * 6, showText: true, fontSize: 8)
                    }
                }
            }
        }
        .boardLook(entry.board)
        .widgetURL(URL(string: "hanju://day/\(dayKey(entry.date))"))
    }
}

struct TodayHeader: View {
    let entry: Entry
    let list: [Block]
    var body: some View {
        let cal = Calendar(identifier: .gregorian)
        let regular = list.filter { !$0.fixed }
        return HStack {
            Text("\(cal.component(.month, from: entry.date))/\(cal.component(.day, from: entry.date)) \(HanjuLanguage.days(entry.board.language)[weekdayIndex(entry.date)])")
                .font(wf(13, .bold))
            Spacer()
            if !regular.isEmpty && regular.allSatisfy({ $0.done }) {
                Text("CLEAR").font(wf(9, .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(blockColor(4)))
            }
        }
    }
}

// MARK: - 오늘 (작은·큰 위젯: 목록)

struct TodayView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if family == .systemMedium {
            FoldedDayView(entry: entry)
        } else {
            TodayList(entry: entry, large: family == .systemLarge)
        }
    }
}

struct TodayList: View {
    let entry: Entry
    let large: Bool

    var body: some View {
        let list = items(entry.board.blocks, on: entry.date)
        let limit = large ? 9 : 3
        return VStack(alignment: .leading, spacing: 7) {
            TodayHeader(entry: entry, list: list)
            if list.isEmpty {
                Text(HanjuLanguage.text("오늘 쌓은 블록이 없어요", "No blocks today", language: entry.board.language)).font(wf(11)).foregroundStyle(.secondary)
            } else {
                ForEach(Array(list.prefix(limit))) { b in
                    TodayRow(block: b, compact: !large, language: entry.board.language)
                }
                if list.count > limit {
                    Text("+ \(list.count - limit)" + HanjuLanguage.text("개", " more", language: entry.board.language)).font(wf(9)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .boardLook(entry.board)
        .widgetURL(URL(string: "hanju://day/\(dayKey(entry.date))"))
    }
}

struct TodayRow: View {
    let block: Block
    let compact: Bool
    var language = HanjuLanguage.system

    var piece: some View {
        VStack(spacing: 1) {
            ForEach(0..<min(block.len, 4), id: \.self) { _ in
                Rectangle().fill(fillColor(block)).frame(width: 8, height: 4)
            }
        }
    }

    var body: some View {
        if block.fixed {
            HStack(spacing: 7) {
                piece
                VStack(alignment: .leading, spacing: 1) {
                    Text(block.name).font(wf(12, .semibold)).lineLimit(1)
                        .foregroundStyle(.secondary)
                    if !compact {
                        Text("\(clock(block.start, language))–\(clock(block.end, language)) \(HanjuLanguage.text("· 매주", "· weekly", language: language))")
                            .font(wf(10)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 6) {
                Button(intent: ToggleBlockIntent(blockID: block.id)) {
                    HStack(spacing: 7) {
                        piece
                        VStack(alignment: .leading, spacing: 1) {
                            Text(block.name).font(wf(12, .semibold)).lineLimit(1)
                                .strikethrough(block.done)
                                .foregroundStyle(block.done ? Color.secondary : Color.primary)
                            if !compact {
                                Text("\(clock(block.start, language))–\(clock(block.end, language))")
                                    .font(wf(10)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: block.done ? "checkmark.square.fill" : "square")
                            .font(wf(13))
                            .foregroundStyle(block.done ? blockColor(4) : Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .invalidatableContent()
                if !compact {
                    Button(intent: DeleteBlockIntent(blockID: block.id)) {
                        Image(systemName: "xmark")
                            .font(wf(10, .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 할 일 목록 (시간 없이 할 일만 나열, 체크로 완료)

struct CheckRow: View {
    let block: Block
    let day: String
    let size: CGFloat

    var body: some View {
        Button(intent: ToggleBlockIntent(blockID: block.id)) {
            HStack(spacing: 7) {
                Image(systemName: block.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: size + 3))
                    .foregroundStyle(block.done ? Color.secondary : blockColor(block.color))
                Text(block.name).font(wf(size, .semibold)).lineLimit(1)
                    .strikethrough(block.done)
                    .foregroundStyle(block.done ? Color.secondary : Color.primary)
                Spacer(minLength: 4)
                Text(day).font(wf(size - 2)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .invalidatableContent()
    }
}

/// 이번 주 할 일을 날짜 순서대로 한 줄씩. 고정(↻) 일정은 빼고, 시간은 안 보여줘요.
struct TodoListView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        let keys = weekDates(of: entry.date).map { dayKey($0) }
        let todayKey = dayKey(entry.date)
        let week = entry.board.blocks.filter { !$0.fixed && keys.contains($0.date) }
        let todos = week.filter { !$0.done }.sorted { ($0.date, $0.start) < ($1.date, $1.start) }   // 체크한 건 위젯에서 빼요
        let cols = family == .systemLarge ? 1 : 2
        let perCol = family == .systemMedium ? 4 : family == .systemSmall ? 4 : 11
        let room = cols * perCol
        let shown = todos.count > room ? Array(todos.prefix(room - 1)) : todos
        let size: CGFloat = family == .systemSmall ? 11 : 12
        let done = week.count - todos.count
        let label: (Block) -> String = { b in
            b.date == todayKey ? HanjuLanguage.text("오늘", "Today", language: entry.board.language) : HanjuLanguage.days(entry.board.language)[keys.firstIndex(of: b.date) ?? 0]
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(HanjuLanguage.text("할 일", "Tasks", language: entry.board.language)).font(wf(14, .heavy))
                Spacer()
                Text("\(done) / \(week.count)").font(wf(11)).monospacedDigit().foregroundStyle(.secondary)
            }
            if todos.isEmpty {
                Text(week.isEmpty ? HanjuLanguage.text("이번 주 할 일이 없어요", "No tasks this week", language: entry.board.language)
                                  : HanjuLanguage.text("이번 주 할 일 다 했어요 🎉", "All done this week 🎉", language: entry.board.language)).font(wf(11)).foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<cols, id: \.self) { c in
                        VStack(alignment: .leading, spacing: family == .systemLarge ? 9 : 7) {
                            ForEach(Array(shown.dropFirst(c * perCol).prefix(perCol))) { b in
                                CheckRow(block: b, day: label(b), size: size)
                            }
                            if c == cols - 1 && todos.count > shown.count {
                                Text("+ \(todos.count - shown.count)" + HanjuLanguage.text("개 더", " more", language: entry.board.language)).font(wf(10)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .boardLook(entry.board)
    }
}

// MARK: - 공통 할 일 (오늘 / 이번 주) — 체크는 바로, 추가는 + 로 앱의 입력칸 열기

struct TodoRow: View {
    let todo: Todo
    let done: Bool
    let size: CGFloat
    var body: some View {
        Button(intent: ToggleTodoIntent(todoID: todo.id)) {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: size + 3))
                    .foregroundStyle(done ? Color.secondary : Color.accentColor)
                Text(todo.text).font(wf(size, .semibold)).lineLimit(1)
                    .strikethrough(done)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .invalidatableContent()
    }
}

struct TodoSection: View {
    let scope: String
    let entry: Entry
    let limit: Int
    let size: CGFloat
    var body: some View {
        let en = entry.board.language == "en"
        let all = entry.board.todos.filter { $0.scope == scope && $0.visible(at: entry.date) }
        // 위젯에는 아직 안 한 것만. 체크한 건 바로 사라지고 앱에서만 보여요 (개수는 위에 n/m으로).
        let open = all.filter { !$0.done(at: entry.date) }, closed = all.filter { $0.done(at: entry.date) }
        let ordered = open
        let shown = ordered.count > limit ? Array(ordered.prefix(max(1, limit - 1))) : ordered
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(scope == "week" ? (en ? "This week" : "이번 주 할 일") : (en ? "Today" : "오늘 할 일")).font(wf(size + 1, .heavy))
                Text("\(closed.count)/\(all.count)").font(wf(size - 2)).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Link(destination: URL(string: "hanju://todo/\(scope)")!) {
                    Image(systemName: "plus.circle.fill").font(.system(size: size + 5)).foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel(en ? "Add" : "추가")
            }
            if all.isEmpty {
                Text(en ? "Tap + to add" : "+ 를 눌러 추가해요").font(wf(size - 1)).foregroundStyle(.secondary)
            } else if open.isEmpty {
                Text(en ? "All done 🎉" : "다 했어요 🎉").font(wf(size - 1)).foregroundStyle(.secondary)
            } else {
                ForEach(shown) { TodoRow(todo: $0, done: $0.done(at: entry.date), size: size) }
                if ordered.count > shown.count {
                    Text(en ? "+ \(ordered.count - shown.count) more" : "+ \(ordered.count - shown.count)개 더").font(wf(size - 2)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - 챌린지 칸: 오늘의 Day 항목 + 레서의 그릇(비커·물병·화분)

/// 그릇 그림. 채운 만큼 물이 차거나 새싹이 자라요 (Shared/Challenge.swift의 Vessel).
struct VesselIcon: View {
    let kind: String
    let percent: Double
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / 26, size.height / 32)
            ctx.translateBy(x: (size.width - 26 * s) / 2 + s, y: (size.height - 32 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            for l in Vessel.layers(kind, percent) {
                let shading: GraphicsContext.Shading = l.ink ? .foreground : .color(Color(red: l.r, green: l.g, blue: l.b).opacity(l.a))
                if l.stroke > 0 {
                    ctx.stroke(Path(l.path), with: shading, style: StrokeStyle(lineWidth: l.stroke, lineCap: .round, lineJoin: .round))
                } else {
                    ctx.fill(Path(l.path), with: shading)
                }
            }
        }
        .accessibilityLabel("\(Int((percent * 100).rounded()))%")
    }
}

struct ChallengeRow: View {
    let challenge: String
    let item: ChallengeItem
    let size: CGFloat
    var body: some View {
        Button(intent: ToggleChallengeItemIntent(challengeID: challenge, itemID: item.id)) {
            HStack(spacing: 6) {
                Image(systemName: item.done ? "checkmark.square.fill" : "square")
                    .font(.system(size: size + 3))
                    .foregroundStyle(item.done ? Color.secondary : blockColor(1))
                Text(item.text).font(wf(size, .semibold)).lineLimit(1)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .invalidatableContent()
    }
}

struct ChallengeSection: View {
    let challenge: ChallengeToday
    let language: String
    let limit: Int
    let size: CGFloat
    var body: some View {
        let en = language == "en"
        let ordered = challenge.items.filter { !$0.done }   // 체크한 건 위젯에서 빼요
        let shown = ordered.count > limit ? Array(ordered.prefix(max(1, limit - 1))) : ordered
        let dday = challenge.daysLeft.map { $0 > 0 ? "D-\($0)" : $0 == 0 ? "D-day" : "D+\(-$0)" }
        return VStack(alignment: .leading, spacing: 5) {
            Link(destination: URL(string: "hanju://challenge")!) {
                HStack(alignment: .center, spacing: 5) {
                    VesselIcon(kind: challenge.vessel, percent: challenge.state == "active" ? challenge.percent : 0)
                        .frame(width: size + 7, height: size + 15)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(challenge.title).font(wf(size + 1, .heavy)).lineLimit(1)
                        Text(challenge.state == "upcoming" ? (en ? "Starts soon" : "곧 시작")
                             : challenge.state == "finished" ? (en ? "Finished 🎉" : "완주 🎉")
                             : "Day \(challenge.index + 1)/\(challenge.count)" + (challenge.dayTitle.isEmpty ? "" : " · \(challenge.dayTitle)"))
                            .font(wf(size - 2)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(Int((challenge.percent * 100).rounded()))%").font(wf(size + 1, .heavy)).monospacedDigit()
                        if let dday { Text(dday).font(wf(size - 3)).foregroundStyle(.secondary) }
                    }
                }
            }
            if challenge.state == "active" {
                if ordered.isEmpty {
                    Text(en ? "Today's vessel is full 🎉" : "오늘 그릇 가득 🎉").font(wf(size - 1)).foregroundStyle(.secondary)
                }
                ForEach(shown) { ChallengeRow(challenge: challenge.id, item: $0, size: size) }
                if ordered.count > shown.count || challenge.behind > 0 {
                    Text([ordered.count > shown.count ? (en ? "+ \(ordered.count - shown.count) more" : "+ \(ordered.count - shown.count)개 더") : nil,
                          challenge.behind > 0 ? (en ? "\(challenge.behind) left from earlier" : "밀린 항목 \(challenge.behind)개") : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(wf(size - 2)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct CommonTodoView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        let ch = entry.board.challenge(at: entry.date)
        let lang = entry.board.language
        Group {
            switch family {
            case .systemSmall:
                TodoSection(scope: "day", entry: entry, limit: 4, size: 11)
            case .systemMedium:
                // 챌린지가 있으면 오늘 할 일 | 챌린지, 없으면 오늘 | 이번 주
                HStack(alignment: .top, spacing: 14) {
                    TodoSection(scope: "day", entry: entry, limit: 4, size: 11)
                    if let ch { ChallengeSection(challenge: ch, language: lang, limit: 3, size: 11) }
                    else { TodoSection(scope: "week", entry: entry, limit: 4, size: 11) }
                }
            case .systemLarge:
                VStack(alignment: .leading, spacing: ch == nil ? 12 : 9) {
                    TodoSection(scope: "day", entry: entry, limit: ch == nil ? 7 : 4, size: 12)
                    TodoSection(scope: "week", entry: entry, limit: ch == nil ? 6 : 3, size: 12)
                    if let ch { ChallengeSection(challenge: ch, language: lang, limit: 5, size: 12) }
                }
            default:
                HStack(alignment: .top, spacing: 18) {
                    TodoSection(scope: "day", entry: entry, limit: 12, size: 12)
                    TodoSection(scope: "week", entry: entry, limit: 12, size: 12)
                    if let ch { ChallengeSection(challenge: ch, language: lang, limit: 11, size: 12) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .boardLook(entry.board)
    }
}

// MARK: - 위젯 등록

struct HanjuCommonTodoWidget: Widget {
    let kind = "HanjuTodo"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { CommonTodoView(entry: $0) }
            .configurationDisplayName("오늘·이번 주 할 일")
            .description("시간 없는 할 일 체크리스트와 챌린지. 네모를 누르면 바로 체크되고 아래로 내려가요. + 를 누르면 바로 추가할 수 있어요.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct HanjuListWidget: Widget {
    let kind = "HanjuList"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { TodoListView(entry: $0) }
            .configurationDisplayName("할 일 목록")
            .description("이번 주 할 일만 시간 없이 나열해요. 네모를 누르면 바로 완료돼요.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct HanjuWeekWidget: Widget {
    let kind = "HanjuWeek"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { WeekView(entry: $0) }
            .configurationDisplayName("한 주 판")
            .description("이번 주 블록을 한눈에 봐요. 블록을 누르면 바로 완료로 바뀌어요.")
            .supportedFamilies([.systemLarge])
    }
}

struct HanjuDayWidget: Widget {
    let kind = "HanjuDay"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { TodayView(entry: $0) }
            .configurationDisplayName("오늘 블록")
            .description("가로로 긴 크기는 오늘 시간을 접어서 블록으로 보여줘요. 누르면 바로 완료돼요.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct HanjuWidgets: WidgetBundle {
    var body: some Widget {
        HanjuWeekWidget()
        HanjuDayWidget()
        HanjuListWidget()
        HanjuCommonTodoWidget()
        #if os(iOS)
        HanjuLockWidget()
        HanjuLiveBlock()
        #endif
    }
}
