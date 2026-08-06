import CoreSpotlight
import Foundation

/// Donation / deletion / self-check on a named index (Apple explicitly says
/// production code should use a named index, not the default one).
///
/// Donation uses the classic CSSearchableItem + associateAppEntity path
/// (Apple's "Path B"): on this machine (macOS 26.5) `indexAppEntities`'s XPC
/// hangs silently and its completion never fires. The classic API has existed
/// since 10.11 and is far more battle-tested; with the entity associated,
/// Spotlight still gets full App Entity / OpenIntent semantics.
/// Every call carries a timeout: when corespotlightd is unresponsive the call
/// errors out and the next refresh retries, instead of wedging the serial
/// pipeline forever.
actor SpotlightIndexer {
    static let indexName = "SpotionSessions"

    struct TimeoutError: LocalizedError {
        var operation: String
        var errorDescription: String? {
            "CoreSpotlight 索引服务未在限时内响应（\(operation)）。已跳过本轮，将在下次刷新时重试；持续出现可尝试重启 corespotlightd 或系统。"
        }
    }

    // CSSearchableIndex instance methods are documented as callable from any
    // thread; nonisolated(unsafe) waives Swift 6's sending checks for this
    // non-Sendable value crossing isolation.
    private nonisolated(unsafe) let index = CSSearchableIndex(name: SpotlightIndexer.indexName)
    /// CSSearchableIndex holds its delegate weakly — we must retain it.
    private var delegate: (any CSSearchableIndexDelegate)?

    func installDelegate(_ newDelegate: any CSSearchableIndexDelegate) {
        delegate = newDelegate
        index.indexDelegate = newDelegate
    }

    func upsert(_ entities: [SessionEntity]) async throws {
        guard !entities.isEmpty else { return }
        // Newest sessions land first; re-donating the same uniqueIdentifier
        // updates in place.
        let sorted = entities.sorted { $0.lastActivityAt > $1.lastActivityAt }
        var start = 0
        while start < sorted.count {
            let end = min(start + 100, sorted.count)
            // CSSearchableItem is not Sendable; the items are freshly created
            // and only passed into the XPC call, so an unchecked box gets them
            // past the closure-capture check.
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

    /// Queries the index content directly via CSUserQuery: separates "our
    /// donation never landed" from "the Spotlight UI is not showing it".
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

    // MARK: - Completion bridging with timeout

    /// The completion may be consumed at most once; a callback arriving after
    /// the timeout is ignored.
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

/// Callbacks for system-requested reindexing (index corruption, migration…).
final class SpotionIndexDelegate: NSObject, CSSearchableIndexDelegate {
    /// The ObjC callback closures are not marked @Sendable, but CoreSpotlight
    /// allows calling them later from any thread.
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
            await AppCoordinator.shared.reindexIdentifiers(identifiers)
            ack.value()
        }
    }
}
