import Foundation
import CoreGraphics

/// 챌린지: N일짜리 계획 + 날마다 체크할 항목 (저장 파일의 "challenges").
/// 페이지(index.html)의 chNow()와 같은 규칙으로 "오늘의 Day"를 정해요.
///   - 날짜 고정(fixed): Day N = 시작일 + N-1. 못 한 항목은 "밀린 항목"으로 남아요.
///   - 밀기(shift): 다 끝낼 때까지 그 Day에 머물러요. 오늘 끝냈으면 오늘은 그 Day를 100%로 보여줘요.
struct ChallengeItem: Identifiable {
    let id: String
    let text: String
    let url: String?
    let done: Bool
}

struct ChallengeToday {
    let id: String
    let title: String
    let vessel: String          // beaker | bottle | pot
    let state: String           // upcoming | active | finished
    let index: Int              // 0부터
    let count: Int
    let dayTitle: String
    let items: [ChallengeItem]
    let percent: Double         // 오늘 Day를 얼마나 채웠는지 0…1
    let behind: Int             // 밀린 항목 (날짜 고정)
    let daysLeft: Int?          // 마감·시험일까지 (D-n)
}

enum Challenge {
    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func date(_ key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    static func span(from a: String, to b: String) -> Int? {
        guard let x = date(a), let y = date(b) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        return cal.dateComponents([.day], from: cal.startOfDay(for: x), to: cal.startOfDay(for: y)).day
    }

    /// 지금 진행 중인 첫 챌린지 (없으면 곧 시작할 것). 끝난 건 빼요.
    static func today(_ rows: [[String: Any]], now: Date = Date()) -> ChallengeToday? {
        let list = rows.filter { ($0["archived"] as? Bool) != true }.compactMap { evaluate($0, today: key(now)) }
        return list.first { $0.state == "active" } ?? list.first { $0.state == "upcoming" }
    }

    static func evaluate(_ row: [String: Any], today tk: String) -> ChallengeToday? {
        guard let id = row["id"] as? String, let start = row["start"] as? String, date(start) != nil else { return nil }
        let days: [(title: String, items: [[String: Any]])] = (row["days"] as? [[String: Any]] ?? []).map {
            (($0["t"] as? String) ?? "", ($0["items"] as? [[String: Any]]) ?? [])
        }
        guard !days.isEmpty else { return nil }
        let checks = row["checks"] as? [String: Any] ?? [:]
        func checked(_ item: [String: Any]) -> String? { (item["id"] as? String).flatMap { checks[$0] as? String } }
        func dayDone(_ i: Int) -> Bool { days[i].items.allSatisfy { checked($0) != nil } }
        func finishedOn(_ i: Int) -> String { days[i].items.compactMap(checked).max() ?? "" }

        var state = "active", index = 0, behind = 0
        if start > tk {
            state = "upcoming"
        } else if row["mode"] as? String == "shift" {
            if let open = days.indices.first(where: { !dayDone($0) }) {
                index = open
                if open > 0 && finishedOn(open - 1) == tk { index = open - 1 }
            } else {
                index = days.count - 1
                if finishedOn(index) < tk { state = "finished" }
            }
        } else {
            index = span(from: start, to: tk) ?? 0
            if index >= days.count { index = days.count - 1; state = "finished" }
            for i in 0..<(state == "finished" ? days.count : index) {
                behind += days[i].items.filter { checked($0) == nil }.count
            }
        }
        let items = days[index].items.compactMap { item -> ChallengeItem? in
            guard let iid = item["id"] as? String, let text = item["text"] as? String else { return nil }
            return ChallengeItem(id: iid, text: text, url: item["url"] as? String, done: checked(item) != nil)
        }
        let percent = items.isEmpty ? 1 : Double(items.filter(\.done).count) / Double(items.count)
        let vessel = ["beaker", "bottle", "pot"].contains(row["vessel"] as? String ?? "") ? row["vessel"] as! String : "beaker"
        let end = (row["end"] as? String).flatMap { span(from: tk, to: $0) }
        return ChallengeToday(id: id, title: row["title"] as? String ?? "", vessel: vessel, state: state, index: index,
                              count: days.count, dayTitle: days[index].title, items: items, percent: percent, behind: behind, daysLeft: end)
    }

    /// 항목 체크 켜기/끄기 (위젯 버튼). 체크한 날짜를 남겨요.
    static func toggle(_ row: inout [String: Any], item: String, today: String) {
        var checks = row["checks"] as? [String: Any] ?? [:]
        if checks[item] != nil { checks.removeValue(forKey: item) } else { checks[item] = today }
        row["checks"] = checks
    }
}

// MARK: - 그릇 그림 (비커·물병·화분). 24×32 칸, 위가 0인 좌표. 위젯(SwiftUI)과 바탕화면 레서(AppKit)가 같이 써요.

struct VesselLayer {
    let path: CGPath
    let r: Double, g: Double, b: Double, a: Double
    var stroke: Double = 0        // 0 = 채우기
    var ink = false               // true = 글자색(밝기에 따라 바뀌는 윤곽선)
}

enum Vessel {
    static func rgb(_ hex: UInt32, _ a: Double = 1) -> (Double, Double, Double, Double) {
        (Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255, a)
    }
    static func layer(_ path: CGPath, _ c: (Double, Double, Double, Double), stroke: Double = 0, ink: Bool = false) -> VesselLayer {
        VesselLayer(path: path, r: c.0, g: c.1, b: c.2, a: c.3, stroke: stroke, ink: ink)
    }

    static func star(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let pts: [(CGFloat, CGFloat)] = [(0, -r), (r * 0.3, -r * 0.3), (r, 0), (r * 0.3, r * 0.3), (0, r), (-r * 0.3, r * 0.3), (-r, 0), (-r * 0.3, -r * 0.3)]
        p.addLines(between: pts.map { CGPoint(x: x + $0.0, y: y + $0.1) }); p.closeSubpath()
        return p
    }

    static func body(_ bottle: Bool) -> CGPath {
        let p = CGMutablePath()
        if bottle {
            p.move(to: CGPoint(x: 10, y: 4)); p.addLine(to: CGPoint(x: 14, y: 4)); p.addLine(to: CGPoint(x: 14, y: 7.5))
            p.addQuadCurve(to: CGPoint(x: 19, y: 12), control: CGPoint(x: 19, y: 9)); p.addLine(to: CGPoint(x: 19, y: 28))
            p.addQuadCurve(to: CGPoint(x: 17, y: 30), control: CGPoint(x: 19, y: 30)); p.addLine(to: CGPoint(x: 7, y: 30))
            p.addQuadCurve(to: CGPoint(x: 5, y: 28), control: CGPoint(x: 5, y: 30)); p.addLine(to: CGPoint(x: 5, y: 12))
            p.addQuadCurve(to: CGPoint(x: 10, y: 7.5), control: CGPoint(x: 5, y: 9))
        } else {
            p.move(to: CGPoint(x: 9, y: 2)); p.addLine(to: CGPoint(x: 9, y: 11)); p.addLine(to: CGPoint(x: 3, y: 28))
            p.addQuadCurve(to: CGPoint(x: 5, y: 30), control: CGPoint(x: 2.6, y: 30)); p.addLine(to: CGPoint(x: 19, y: 30))
            p.addQuadCurve(to: CGPoint(x: 21, y: 28), control: CGPoint(x: 21.4, y: 30)); p.addLine(to: CGPoint(x: 15, y: 11))
            p.addLine(to: CGPoint(x: 15, y: 2))
        }
        p.closeSubpath()
        return p
    }

    /// phase(초)를 바꿔 가며 그리면 물결과 거품이 움직여요. 위젯은 0으로 멈춘 그림.
    static func layers(_ kind: String, _ percent: Double, phase: Double = 0) -> [VesselLayer] {
        let pct = max(0, min(1, percent))
        var out: [VesselLayer] = []
        if kind == "pot" {
            let top = 20 - (3 + pct * 13)
            out.append(layer(CGPath(rect: CGRect(x: 3, y: 19, width: 18, height: 3), transform: nil), rgb(0xb8643a)))
            let pot = CGMutablePath(); pot.addLines(between: [CGPoint(x: 4, y: 22), CGPoint(x: 20, y: 22), CGPoint(x: 18, y: 30), CGPoint(x: 6, y: 30)]); pot.closeSubpath()
            out.append(layer(pot, rgb(0xd0784a)))
            out.append(layer(CGPath(ellipseIn: CGRect(x: 4, y: 20.3, width: 16, height: 2.2), transform: nil), rgb(0x6b4630)))
            if pct <= 0 {
                out.append(layer(CGPath(ellipseIn: CGRect(x: 10.5, y: 19.4, width: 3, height: 2), transform: nil), rgb(0x8a5a3a)))
                return out
            }
            let sway = sin(phase * 1.6) * 0.5 * pct
            let stem = CGMutablePath(); stem.move(to: CGPoint(x: 12, y: 21)); stem.addQuadCurve(to: CGPoint(x: 12 + sway, y: top), control: CGPoint(x: 12 - sway, y: (21 + top) / 2))
            out.append(layer(stem, rgb(0x3fa55f), stroke: 1.6))
            if pct >= 0.25 {
                let leaf = CGMutablePath(); leaf.move(to: CGPoint(x: 12, y: 16)); leaf.addQuadCurve(to: CGPoint(x: 5.5, y: 11.5), control: CGPoint(x: 7, y: 15.5))
                leaf.addQuadCurve(to: CGPoint(x: 12, y: 16), control: CGPoint(x: 10.5, y: 11.5)); out.append(layer(leaf, rgb(0x4cb86b)))
            }
            if pct >= 0.55 {
                let leaf = CGMutablePath(); leaf.move(to: CGPoint(x: 12, y: 12.5)); leaf.addQuadCurve(to: CGPoint(x: 18.5, y: 8), control: CGPoint(x: 17, y: 12))
                leaf.addQuadCurve(to: CGPoint(x: 12, y: 12.5), control: CGPoint(x: 13.5, y: 8)); out.append(layer(leaf, rgb(0x3fa55f)))
            }
            if pct >= 1 {
                for k in 0..<5 {
                    let a = Double(k) / 5 * .pi * 2 - .pi / 2
                    out.append(layer(CGPath(ellipseIn: CGRect(x: 12 + sway + 2.5 * cos(a) - 2, y: top + 2.5 * sin(a) - 2, width: 4, height: 4), transform: nil), rgb(0xdc4d4a)))
                }
                out.append(layer(CGPath(ellipseIn: CGRect(x: 12 + sway - 1.5, y: top - 1.5, width: 3, height: 3), transform: nil), rgb(0xe6b21c)))
                out += sparkles(phase, at: [(3, 6, 2.2), (21, 9, 1.8)])
            }
            return out
        }
        let bottle = kind == "bottle"
        let shape = body(bottle)
        out.append(layer(shape, (1, 1, 1, 0.4)))
        if pct > 0 {
            let level = 30 - pct * (bottle ? 23 : 26)
            let wave = CGMutablePath()
            wave.move(to: CGPoint(x: -1, y: 32)); wave.addLine(to: CGPoint(x: -1, y: level))
            for i in 0..<4 {
                let x = -1 + Double(i) * 6.5
                wave.addQuadCurve(to: CGPoint(x: x + 6.5, y: level), control: CGPoint(x: x + 3.25, y: level - 1.2 * cos(phase * 2.2 + Double(i))))
            }
            wave.addLine(to: CGPoint(x: 25, y: 32)); wave.closeSubpath()
            out.append(layer(wave.intersection(shape), rgb(bottle ? 0x3f6fd8 : 0x24a9b8)))
            for (x, dy, r, delay) in [(10.0, 5.0, 0.9, 0.0), (13.5, 9.0, 0.7, 0.8), (11.5, 13.0, 0.8, 1.6)] {
                let rise = phase == 0 ? 0 : (phase + delay).truncatingRemainder(dividingBy: 2.4) / 2.4 * 5
                let y = level + dy - rise
                if y < 29, y > level + 0.5 {
                    out.append(layer(CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2), transform: nil), (1, 1, 1, 0.75)))
                }
            }
        }
        out.append(layer(shape, (0, 0, 0, 1), stroke: 1.3, ink: true))
        if bottle {
            out.append(layer(CGPath(rect: CGRect(x: 9.5, y: 1, width: 5, height: 3.4), transform: nil), rgb(0xe5852a)))
        } else {
            let rim = CGMutablePath(); rim.move(to: CGPoint(x: 7.5, y: 2)); rim.addLine(to: CGPoint(x: 16.5, y: 2))
            out.append(layer(rim, (0, 0, 0, 1), stroke: 1.3, ink: true))
        }
        if pct >= 1 { out += sparkles(phase, at: [(2.5, 5, 2.2), (21.5, 7, 1.8)]) }
        return out
    }

    static func sparkles(_ phase: Double, at spots: [(CGFloat, CGFloat, CGFloat)]) -> [VesselLayer] {
        spots.enumerated().map { (i, s) -> VesselLayer in
            let glow = phase == 0 ? 1 : 0.35 + 0.65 * abs(sin(phase * 2.8 + Double(i)))
            return layer(star(s.0, s.1, s.2), rgb(0xe6b21c, glow))
        }
    }
}
