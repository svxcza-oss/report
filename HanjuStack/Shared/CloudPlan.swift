import Foundation
import CloudKit
import WidgetKit

/// 맥 ↔ 아이폰 계획 동기화 (서버 없음). 사용자 iCloud의 비공개 CloudKit 데이터베이스에 계획 하나를 둬요.
///
/// - 바뀔 때마다 서버 것과 항목 단위로 합쳐서(PlanMerge) 올리고, 받을 때도 합쳐서 이 기기 저장 파일에 써요.
///   그래서 두 기기에서 따로 고쳐도 서로 덮어쓰지 않아요.
/// - 다른 기기가 올리면 CloudKit이 조용한 알림을 보내고, 앱이 켜져 있는 동안은 20초마다도 확인해요.
/// - 위젯도 체크한 직후 올리고, 위젯이 새로 그려질 때 받아 와요.
/// - 앱스토어 서명판에서만 켜져요 (Info.plist의 HanjuCloudSync). 개인용 빌드에서는 nil이에요.
final class CloudPlan: @unchecked Sendable {
    static let shared: CloudPlan? = {
        guard enabled(), let store = try? HanjuStore.production(),
              let id = Bundle.main.object(forInfoDictionaryKey: "HanjuCloudContainer") as? String,
              !id.isEmpty, !id.contains("$(") else { return nil }
        return CloudPlan(store: store, container: id)
    }()

    static func enabled(_ bundle: Bundle = .main) -> Bool {
        let value = bundle.object(forInfoDictionaryKey: "HanjuCloudSync")
        return (value as? Bool) == true || (value as? String)?.uppercased() == "YES"
    }

    let store: HanjuStore
    private let database: CKDatabase
    private let zone = CKRecordZone.ID(zoneName: "Hanju", ownerName: CKCurrentUserDefaultName)
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: "plan", zoneID: zone) }
    private let queue = DispatchQueue(label: "hanju.cloud")
    private var chain: Task<Void, Never>?
    private var again = false
    /// 이 기기 저장 파일이 바뀌었을 때 (화면 새로고침용). 메인 스레드에서 불려요.
    var onApplied: (() -> Void)?
    private(set) var lastError: String?

    init(store: HanjuStore, container: String) {
        self.store = store
        database = CKContainer(identifier: container).privateCloudDatabase
    }

    /// 순서대로 한 번씩만 돌게 줄을 세워요. 도는 중에 또 부르면 끝나고 한 번 더 돌아요.
    func sync() {
        queue.sync {
            if chain != nil { again = true; return }
            chain = Task { [weak self] in
                guard let self else { return }
                repeat {
                    self.queue.sync { self.again = false }
                    await self.syncNow()
                } while self.queue.sync(execute: { self.again })
                self.queue.sync { self.chain = nil }
            }
        }
    }

    /// 받아서 합치고, 달라졌으면 올려요. 위젯처럼 한 번만 쓰고 끝나는 곳에서는 이걸 직접 기다려요.
    @discardableResult
    func syncNow() async -> Bool {
        var changedHere = false
        do {
            try await prepare()
            var serverRecord = try await fetch()
            for _ in 0..<3 {
                let remote = serverRecord.flatMap { ($0["data"] as? Data).flatMap { try? HanjuStore.decode($0) } }
                let local = try store.read()
                guard let merged = PlanMerge.merge(local, remote) else { return changedHere }
                if !PlanMerge.same(merged, local) {
                    _ = try store.update { current in PlanMerge.merge(current, merged) ?? merged }
                    changedHere = true
                }
                if PlanMerge.same(merged, remote) || (remote == nil && PlanMerge.sampleOnly(merged)) { break }
                let record = serverRecord ?? CKRecord(recordType: "Plan", recordID: recordID)
                let data: Data = try JSONSerialization.data(withJSONObject: PlanMerge.clean(merged), options: [.sortedKeys])
                record["data"] = data
                record["savedAt"] = Date()
                do {
                    let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
                    if case .failure(let error) = saved[recordID] { throw error }
                    break
                } catch let error as CKError where error.code == .serverRecordChanged {
                    serverRecord = error.serverRecord   // 그사이 다른 기기가 올렸어요 → 다시 합쳐요
                }
            }
            lastError = nil
        } catch {
            lastError = (error as? CKError).map { "CloudKit \($0.code.rawValue): \($0.localizedDescription)" } ?? error.localizedDescription
            NSLog("HanjuStack sync: %@", lastError ?? "")
        }
        if changedHere {
            WidgetCenter.shared.reloadAllTimelines()
            DispatchQueue.main.async { [weak self] in self?.onApplied?() }
        }
        return changedHere
    }

    private func fetch() async throws -> CKRecord? {
        do { return try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    /// 처음 한 번: 영역(zone)과 "바뀌면 알려 줘" 구독을 만들어요.
    private func prepare() async throws {
        let key = "hanju.cloudkit.ready.v1"
        if UserDefaults.standard.bool(forKey: key) { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
        let subscription = CKDatabaseSubscription(subscriptionID: "hanju-plan-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true      // 조용한 알림: 화면에 아무것도 안 띄우고 앱만 깨워요
        subscription.notificationInfo = info
        _ = try? await database.modifySubscriptions(saving: [subscription], deleting: [])
        UserDefaults.standard.set(true, forKey: key)
    }
}
