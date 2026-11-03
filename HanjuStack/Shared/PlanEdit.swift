import Foundation
import WidgetKit

// 위젯 버튼·잠금화면 버튼처럼 앱 화면 밖에서 계획을 고칠 때 쓰는 공통 도구.

/// 저장 파일을 고치고, 바뀐 항목에 시각(u)을 찍고, 맥·아이폰으로 바로 올려요.
func editPlan(_ change: (inout [String: Any], Double) -> Void) async throws {
    let store = try HanjuStore.production()
    let now = PlanMerge.nowMs()
    try store.update { current in
        guard var root = current else { throw HanjuStore.StoreError.invalidData }
        change(&root, now); return root
    }
    WidgetCenter.shared.reloadAllTimelines()
    await CloudPlan.shared?.syncNow()
}

func editRow(_ list: String, _ id: String, in root: inout [String: Any], now: Double, _ change: (inout [String: Any]) -> Void) {
    var rows = root[list] as? [[String: Any]] ?? []
    guard let i = rows.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
    change(&rows[i]); rows[i]["u"] = now
    root[list] = rows
}
