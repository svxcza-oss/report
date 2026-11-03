import Foundation

/// 두 계획(이 기기 / 다른 기기·위젯)을 항목 하나하나 비교해서 합쳐요. 통째로 덮어쓰지 않아요.
///
/// - 블록·고정·할 일마다 `u`(마지막으로 바뀐 시각, ms)가 있어요. 같은 id면 `u`가 큰 쪽이 이겨요.
/// - 지운 항목은 `deleted[id] = 지운 시각`으로 남겨요. 지운 시각이 그 항목의 `u`보다 늦으면 합칠 때 빠져요.
/// - 모드·시간 범위·언어 같은 설정은 `_settingsAt`이 늦은 쪽을 따라요.
/// - 처음 설치해서 생긴 예시 블록뿐인 계획은 진짜 계획과 섞지 않아요.
enum PlanMerge {
    static let lists = ["blocks", "fixed", "todos"]
    static let settings = ["theme", "mascot", "lesser", "range", "language", "ai", "rollover"]

    static func ms(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    static func nowMs() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    static func sampleOnly(_ state: [String: Any]) -> Bool {
        let rows = (state["blocks"] as? [[String: Any]] ?? []) + (state["fixed"] as? [[String: Any]] ?? [])
        let todos = state["todos"] as? [[String: Any]] ?? []
        return todos.isEmpty && !rows.isEmpty && rows.allSatisfy { ($0["sample"] as? Bool) == true }
    }

    static func merge(_ a: [String: Any]?, _ b: [String: Any]?) -> [String: Any]? {
        guard let a else { return b.map(clean) }
        guard let b else { return clean(a) }
        if sampleOnly(a) && !sampleOnly(b) { return clean(b) }
        if sampleOnly(b) && !sampleOnly(a) { return clean(a) }

        var out = clean(a)
        // 설정은 더 나중에 바뀐 쪽
        if ms(b["_settingsAt"]) > ms(a["_settingsAt"]) {
            for key in settings { out[key] = b[key] }
            out["_settingsAt"] = b["_settingsAt"]
        }
        // 지운 기록 합치기 (60일 지난 건 정리)
        var dead: [String: Double] = [:]
        for source in [a, b] {
            for (id, at) in source["deleted"] as? [String: Any] ?? [:] { dead[id] = max(dead[id] ?? 0, ms(at)) }
        }
        let cutoff = nowMs() - 60 * 86_400_000
        dead = dead.filter { $0.value > cutoff }

        for key in lists {
            var order: [String] = []
            var winner: [String: [String: Any]] = [:]
            for row in (a[key] as? [[String: Any]] ?? []) + (b[key] as? [[String: Any]] ?? []) {
                guard let id = row["id"] as? String else { continue }
                if let current = winner[id] {
                    if ms(row["u"]) > ms(current["u"]) { winner[id] = row }
                } else {
                    order.append(id); winner[id] = row
                }
            }
            out[key] = order.compactMap { id -> [String: Any]? in
                guard let row = winner[id] else { return nil }
                if let at = dead[id], at >= ms(row["u"]) { return nil }
                return row
            }
        }
        out["deleted"] = dead
        out["n"] = max(Int(ms(a["n"])), Int(ms(b["n"])))
        out["v"] = max(Int(ms(a["v"])), Int(ms(b["v"])))
        return out
    }

    /// Same plan, ignoring the local save counter.
    static func same(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
        canonical(a.map(clean)) == canonical(b.map(clean))
    }

    static func canonical(_ state: [String: Any]?) -> Data? {
        guard let state else { return nil }
        return try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    }

    static func clean(_ state: [String: Any]) -> [String: Any] {
        var out = state
        out.removeValue(forKey: "_revision")
        return out
    }
}
