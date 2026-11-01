import Foundation

/// 맥 ↔ 아이폰 계획 동기화 (서버 없음). iCloud 키-값 저장소 하나에 계획 전체를 올려요.
/// 맥과 iOS 앱은 번들 ID가 같아서 같은 저장소를 써요 (같은 Apple ID로 로그인한 기기끼리).
///
/// 규칙
/// - 이 기기에서 바뀌면(페이지 저장, 위젯 체크) 올리고, 올린 시각을 기억해요.
/// - 다른 기기가 더 나중에 올린 게 오면 받아서 이 기기 저장 파일을 바꿔요.
///   이 기기에도 아직 안 올린 변경이 있었으면 바꾸기 전에 before-cloud-*.json 으로 백업해요.
/// - 처음 설치한 기기의 예시 블록만 있는 계획은 올리지 않아서, 다른 기기의 진짜 계획을 덮지 않아요.
/// 앱스토어 서명판에서만 켜져요 (Info.plist의 HanjuCloudSync). 개인용 빌드에서는 아무것도 하지 않아요.
final class CloudSync {
    private let kv = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private let store: HanjuStore
    private var observer: NSObjectProtocol?
    /// 이 기기 저장 파일이 클라우드 내용으로 바뀌었을 때 (화면·위젯 새로고침용)
    var onApplied: (() -> Void)?

    private var stamp: Double {
        get { defaults.double(forKey: "hanju.cloud.stamp") }
        set { defaults.set(newValue, forKey: "hanju.cloud.stamp") }
    }
    /// 마지막으로 올리거나 받은 시점의 저장 파일 revision
    private(set) var syncedRevision: Int {
        get { defaults.object(forKey: "hanju.cloud.revision") as? Int ?? -1 }
        set { defaults.set(newValue, forKey: "hanju.cloud.revision") }
    }

    static func enabled(_ bundle: Bundle = .main) -> Bool {
        let value = bundle.object(forInfoDictionaryKey: "HanjuCloudSync")
        return (value as? Bool) == true || (value as? String)?.uppercased() == "YES"
    }

    init?(store: HanjuStore, bundle: Bundle = .main) {
        guard Self.enabled(bundle) else { return nil }
        self.store = store
    }

    func start() {
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                          object: kv, queue: .main) { [weak self] _ in self?.reconcile() }
        kv.synchronize()
        reconcile()
    }

    private func remote() -> (stamp: Double, state: [String: Any])? {
        guard let data = kv.data(forKey: "plan"), let state = try? HanjuStore.decode(data) else { return nil }
        return (kv.double(forKey: "savedAt"), state)
    }

    /// 클라우드와 이 기기 중 새로운 쪽으로 맞춰요. 앱이 켜질 때, 다른 기기 변경이 왔을 때, 앱으로 돌아올 때 불러요.
    func reconcile() {
        let local = try? store.read()
        let revision = HanjuStore.revision(local)
        if let remote = remote(), remote.stamp > stamp + 0.001 {
            if let local, revision != syncedRevision, !Self.sampleOnly(local) { backup(local) }
            apply(remote)
            return
        }
        if let local, revision != syncedRevision { push(local) }
    }

    /// 이 기기에서 저장했거나 위젯이 바꾼 내용을 올려요.
    func push(_ state: [String: Any]) {
        let revision = HanjuStore.revision(state)
        guard !Self.sampleOnly(state) else { syncedRevision = revision; return }
        var upload = state
        upload.removeValue(forKey: "_revision")
        guard let data = try? JSONSerialization.data(withJSONObject: upload, options: [.sortedKeys]) else { return }
        guard data.count < 900_000 else { NSLog("HanjuStack: plan too large for iCloud sync (%d bytes)", data.count); return }
        let now = Date().timeIntervalSince1970
        kv.set(data, forKey: "plan")
        kv.set(now, forKey: "savedAt")
        kv.synchronize()
        stamp = now
        syncedRevision = revision
    }

    /// 위젯처럼 앱 밖에서 바뀐 걸 발견했을 때
    func localChanged(_ state: [String: Any]) {
        if HanjuStore.revision(state) != syncedRevision { push(state) }
    }

    private func apply(_ remote: (stamp: Double, state: [String: Any])) {
        guard let saved = try? store.update({ _ in remote.state }) else { return }
        stamp = remote.stamp
        syncedRevision = HanjuStore.revision(saved)
        onApplied?()
    }

    private func backup(_ state: [String: Any]) {
        let url = store.url.deletingLastPathComponent().appendingPathComponent("before-cloud-\(Int(Date().timeIntervalSince1970)).json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 처음 열었을 때 생기는 예시 블록뿐이고 할 일도 없는 계획
    static func sampleOnly(_ state: [String: Any]) -> Bool {
        let rows = (state["blocks"] as? [[String: Any]] ?? []) + (state["fixed"] as? [[String: Any]] ?? [])
        let todos = state["todos"] as? [[String: Any]] ?? []
        return todos.isEmpty && !rows.isEmpty && rows.allSatisfy { ($0["sample"] as? Bool) == true }
    }
}
