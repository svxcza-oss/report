import Foundation

/// Both executables use this exact file inside their signed App Group container.
final class HanjuStore {
    enum StoreError: LocalizedError {
        case unavailable, invalidData, stale
        var errorDescription: String? {
            switch self {
            case .unavailable: return "공유 저장소에 접근할 수 없어요. 앱과 위젯의 App Group 및 서명을 확인해 주세요."
            case .invalidData: return "올바른 한 주 쌓기 저장 파일이 아니에요."
            case .stale: return "위젯에서 바뀐 내용을 먼저 불러왔어요. 변경을 다시 해 주세요."
            }
        }
    }
    private let resolve: () -> URL
    var url: URL { resolve() }
    init(url: URL) { resolve = { url } }
    init(resolver: @escaping () -> URL) { resolve = resolver }
    static func production(bundle: Bundle = .main) throws -> HanjuStore {
        if let local = personal(bundle: bundle) { return local }
        guard let group = bundle.object(forInfoDictionaryKey: "HanjuAppGroup") as? String,
              !group.isEmpty, !group.contains("$("),
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { throw StoreError.unavailable }
        return HanjuStore(url: folder.appendingPathComponent("state.json"))
    }
    /// 개인용 빌드(build-local.sh): 개발자 계정 없이 애드혹 서명. App Group 대신
    /// 샌드박스가 없는 앱이 위젯 컨테이너 안의 같은 파일을 직접 읽고 써요.
    static func personal(bundle: Bundle) -> HanjuStore? {
        guard let widgetID = bundle.object(forInfoDictionaryKey: "HanjuLocalWidgetID") as? String,
              !widgetID.isEmpty, !widgetID.contains("$(") else { return nil }
        if bundle.bundleIdentifier == widgetID {
            return HanjuStore(url: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/state.json"))
        }
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let container = home.appendingPathComponent("Library/Containers/\(widgetID)")
        let fallback = home.appendingPathComponent("Library/Application Support/HanjuStack/state.json")
        return HanjuStore(resolver: {
            // 위젯을 아직 한 번도 추가하지 않았으면 macOS가 위젯 폴더를 만들기 전이라 앱 폴더에 저장해요.
            guard fm.fileExists(atPath: container.path) else { return fallback }
            let shared = container.appendingPathComponent("Data/Documents/state.json")
            if !fm.fileExists(atPath: shared.path), fm.fileExists(atPath: fallback.path) {
                try? fm.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: fallback, to: shared)
            }
            return shared
        })
    }
    static func validate(_ state: [String: Any]) throws {
        let version = (state["v"] as? NSNumber)?.intValue ?? 0
        guard let blocks = state["blocks"] as? [[String: Any]], (0...4).contains(version),
              state["fixed"] == nil || state["fixed"] is [[String: Any]] else { throw StoreError.invalidData }
        let fixed = state["fixed"] as? [[String: Any]] ?? []
        let limit = version >= 4 ? 144 : version >= 3 ? 48 : 32
        for row in blocks + fixed {
            guard let id = row["id"] as? String, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                  row["name"] is String, let start = row["start"] as? NSNumber,
                  let len = row["len"] as? NSNumber,
                  start.doubleValue.isFinite, len.doubleValue.isFinite,
                  start.doubleValue == Double(start.intValue), len.doubleValue == Double(len.intValue),
                  start.intValue >= 0, start.intValue <= limit, len.intValue > 0, len.intValue <= limit, start.intValue + len.intValue <= limit else { throw StoreError.invalidData }
        }
        guard JSONSerialization.isValidJSONObject(state) else { throw StoreError.invalidData }
    }
    func read() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var failure: Error?, result: [String: Any]?, coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { target in
            do { result = try Self.decode(Data(contentsOf: target)) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        return result
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StoreError.invalidData }
        try validate(root); return root
    }
    static func revision(_ state: [String: Any]?) -> Int { (state?["_revision"] as? NSNumber)?.intValue ?? 0 }
    /// Coordinated read-modify-write prevents widget intents overwriting each other.
    @discardableResult func update(expected: Int? = nil, _ transform: ([String: Any]?) throws -> [String: Any]) throws -> [String: Any] {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var failure: Error?, result: [String: Any]?, coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordination) { target in
            do {
                let current = FileManager.default.fileExists(atPath: target.path) ? try Self.decode(Data(contentsOf: target)) : nil
                if let expected, Self.revision(current) != expected { throw StoreError.stale }
                var next = try transform(current); try Self.validate(next)
                next["_revision"] = Self.revision(current) + 1
                try JSONSerialization.data(withJSONObject: next, options: [.sortedKeys]).write(to: target, options: .atomic)
                result = next
            } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        guard let result else { throw StoreError.unavailable }; return result
    }
}
