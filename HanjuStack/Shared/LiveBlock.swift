#if os(iOS)
import Foundation
import ActivityKit
import AppIntents

/// 잠금화면·다이내믹 아일랜드에 띄우는 "지금 하는 블록" (실시간 현황).
/// 앱이 켜져 있을 때 지금 블록이나 3시간 안에 시작하는 다음 블록으로 시작하고,
/// 블록이 끝나거나 완료되면 닫아요. 카운트다운은 시스템이 알아서 돌려요.
struct HanjuBlockActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var name: String
        var start: Date
        var end: Date
        var color: Int        // 1–7, 고정 일정은 0
        var fixed: Bool
    }
    /// 블록 id. 매주 고정 일정은 "id@날짜".
    var blockID: String
}

/// 잠금화면 실시간 현황의 "완료" 버튼. 앱을 열지 않고 블록을 완료로 바꾸고 현황을 닫아요.
struct CompleteLiveBlockIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "블록 완료"
    @Parameter(title: "블록") var blockID: String
    init() {}
    init(blockID: String) { self.blockID = blockID }

    func perform() async throws -> some IntentResult {
        let id = blockID
        if !id.contains("@") {
            try await editPlan { root, now in editRow("blocks", id, in: &root, now: now) { $0["done"] = true } }
        }
        for activity in Activity<HanjuBlockActivity>.activities where activity.attributes.blockID == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

enum LiveBlocks {
    struct Pick {
        let id: String
        let state: HanjuBlockActivity.ContentState
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 지금 진행 중인 블록, 없으면 3시간 안에 시작하는 가장 이른 블록 (완료한 건 빼고).
    static func pick(_ state: [String: Any], now: Date = Date()) -> Pick? {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: now), key = dayKey(now)
        let weekday = (cal.component(.weekday, from: now) + 5) % 7
        func at(_ slot: Int) -> Date { today.addingTimeInterval(TimeInterval(slot * 600)) }
        var candidates: [Pick] = []
        for row in state["blocks"] as? [[String: Any]] ?? [] {
            guard row["date"] as? String == key, (row["done"] as? Bool) != true,
                  let id = row["id"] as? String, let name = row["name"] as? String else { continue }
            let start = (row["start"] as? NSNumber)?.intValue ?? 0, len = (row["len"] as? NSNumber)?.intValue ?? 6
            candidates.append(Pick(id: id, state: .init(name: name, start: at(start), end: at(start + len),
                                                         color: (row["c"] as? NSNumber)?.intValue ?? 1, fixed: false)))
        }
        for row in state["fixed"] as? [[String: Any]] ?? [] {
            guard (row["wd"] as? NSNumber)?.intValue == weekday,
                  let id = row["id"] as? String, let name = row["name"] as? String else { continue }
            let start = (row["start"] as? NSNumber)?.intValue ?? 0, len = (row["len"] as? NSNumber)?.intValue ?? 6
            candidates.append(Pick(id: "\(id)@\(key)", state: .init(name: name, start: at(start), end: at(start + len), color: 0, fixed: true)))
        }
        if let current = candidates.filter({ $0.state.start <= now && now < $0.state.end }).min(by: { $0.state.start < $1.state.start }) {
            return current
        }
        return candidates.filter { $0.state.start > now && $0.state.start.timeIntervalSince(now) <= 3 * 3600 }
            .min { $0.state.start < $1.state.start }
    }

    /// 앱이 화면에 있을 때 불러요. 맞는 현황 하나만 남기고 나머지는 닫아요.
    static func refresh(_ state: [String: Any]?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let target = state.flatMap { pick($0) }
        Task {
            var showing = false
            for activity in Activity<HanjuBlockActivity>.activities {
                if let target, activity.attributes.blockID == target.id, !showing {
                    showing = true
                    if activity.content.state != target.state {
                        await activity.update(ActivityContent(state: target.state, staleDate: target.state.end))
                    }
                } else {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
            if let target, !showing {
                _ = try? Activity.request(attributes: HanjuBlockActivity(blockID: target.id),
                                          content: ActivityContent(state: target.state, staleDate: target.state.end),
                                          pushType: nil)
            }
        }
    }
}
#endif
