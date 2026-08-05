import CoreSpotlight
import Foundation

/// 命名索引（Apple 明确要求生产使用命名索引而非 default）上的 donate / 删除 / 自检。
///
/// donate 走经典路径 CSSearchableItem + associateAppEntity（Apple "Path B"）：
/// 实测本机（macOS 26.5）`indexAppEntities` 的 XPC 会静默挂起、completion 永不回调；
/// 经典 API 自 10.11 起存在、更加可靠，实体关联后 Spotlight 仍具备 App Entity / OpenIntent 语义。
/// 所有调用都带超时：corespotlightd 无响应时报错并由下轮刷新重试，而不是堵死串行管道。
actor SpotlightIndexer {
    static let indexName = "SpotionSessions"

    struct TimeoutError: LocalizedError {
        var operation: String
        var errorDescription: String? {
            "CoreSpotlight 索引服务未在限时内响应（\(operation)）。已跳过本轮，将在下次刷新时重试；持续出现可尝试重启 corespotlightd 或系统。"
        }
    }

    // CSSearchableIndex 的实例方法官方文档标注可从任意线程调用；
    // nonisolated(unsafe) 用于放行 Swift 6 对非 Sendable 值跨隔离的 sending 检查。
    private nonisolated(unsafe) let index = CSSearchableIndex(name: SpotlightIndexer.indexName)
    /// CSSearchableIndex 弱引用 delegate，须自持
    private var delegate: (any CSSearchableIndexDelegate)?

    func installDelegate(_ newDelegate: any CSSearchableIndexDelegate) {
        delegate = newDelegate
        index.indexDelegate = newDelegate
    }

    func upsert(_ entities: [SessionEntity]) async throws {
        guard !entities.isEmpty else { return }
        // 新会话优先落盘；同 uniqueIdentifier 重复 donate 为原地更新
        let sorted = entities.sorted { $0.lastActivityAt > $1.lastActivityAt }
        var start = 0
        while start < sorted.count {
            let end = min(start + 100, sorted.count)
            // CSSearchableItem 非 Sendable；本地新建、仅传入 XPC 调用，用 unchecked 盒子过闭包捕获检查
            let batch = ItemBatch(items: sorted[start..<end].map { entity in
                let attributes = entity.attributeSet
                attributes.associateAppEntity(entity, priority: 0)
                return CSSearchableItem(
                    uniqueIdentifier: entity.id,
                    domainIdentifier: "spotion.\(entity.agent.rawValue)",
                    attributeSet: attributes
                )
            })
            try await withTimeout(20, operation: "index \(batch.items.count) items") { done in
                self.index.indexSearchableItems(batch.items) { done($0) }
            }
            start = end
        }
    }

    func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await withTimeout(20, operation: "delete \(ids.count) items") { done in
            self.index.deleteSearchableItems(withIdentifiers: ids) { done($0) }
        }
    }

    func deleteAll() async throws {
        try await withTimeout(20, operation: "delete all") { done in
            self.index.deleteAllSearchableItems { done($0) }
        }
    }

    func deleteDomain(_ domainIdentifier: String) async throws {
        try await withTimeout(20, operation: "delete domain") { done in
            self.index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { done($0) }
        }
    }

    /// CSUserQuery 直查索引内容：区分"索引没写进去"和"Spotlight UI 没显示"。
    func selfCheck(term: String) async -> Int {
        let context = CSUserQueryContext()
        context.fetchAttributes = ["title"]
        let query = CSUserQuery(userQueryString: term, userQueryContext: context)
        var count = 0
        do {
            for try await response in query.responses {
                if case .item = response { count += 1 }
            }
        } catch {
            NSLog("Spotion: self-check query failed: %@", error.localizedDescription)
        }
        return count
    }

    private struct ItemBatch: @unchecked Sendable {
        let items: [CSSearchableItem]
    }

    // MARK: - 带超时的 completion 桥接

    /// completion 只可能被消费一次；超时后迟到的回调被忽略。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<Void, any Error>

        init(_ continuation: CheckedContinuation<Void, any Error>) {
            self.continuation = continuation
        }

        func resume(_ error: (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func withTimeout(
        _ seconds: TimeInterval,
        operation: String,
        _ body: @escaping @Sendable (@escaping @Sendable ((any Error)?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = ResumeOnce(continuation)
            body { error in once.resume(error) }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                once.resume(TimeoutError(operation: operation))
            }
        }
    }
}

/// 系统请求重建索引时的回调（索引损坏、迁移等场景）。
final class SpotionIndexDelegate: NSObject, CSSearchableIndexDelegate {
    /// ObjC 回调闭包未标 @Sendable，但 CoreSpotlight 允许在任意线程稍后调用它。
    private struct UncheckedSendable<T>: @unchecked Sendable { let value: T }

    func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexAllSearchableItemsWithAcknowledgementHandler acknowledgementHandler: @escaping () -> Void
    ) {
        let ack = UncheckedSendable(value: acknowledgementHandler)
        Task { @MainActor in
            await AppCoordinator.shared.fullReindex()
            ack.value()
        }
    }

    func searchableIndex(
        _ searchableIndex: CSSearchableIndex,
        reindexSearchableItemsWithIdentifiers identifiers: [String],
        acknowledgementHandler: @escaping () -> Void
    ) {
        let ack = UncheckedSendable(value: acknowledgementHandler)
        Task { @MainActor in
            await AppCoordinator.shared.refreshAndApply()
            ack.value()
        }
    }
}
