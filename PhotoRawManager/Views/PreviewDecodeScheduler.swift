import Foundation

/// Serial scheduler for main preview decoding.
///
/// Fast culling needs only the latest selected photo. This cancels queued decode work
/// whenever a newer selection arrives and gives each job a generation check.
final class PreviewDecodeScheduler {
    static let shared = PreviewDecodeScheduler()

    private let queue: OperationQueue
    private let lock = NSLock()
    private var generation: UInt64 = 0

    private init() {
        let q = OperationQueue()
        q.name = "com.pickshot.preview.decode"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        queue = q
    }

    @discardableResult
    func schedule(_ block: @escaping (_ isCurrent: @escaping () -> Bool) -> Void) -> UInt64 {
        let gen = nextGeneration(cancelQueued: true)
        let op = BlockOperation()
        op.addExecutionBlock { [weak op, weak self] in
            guard let self, op?.isCancelled == false else { return }
            block {
                op?.isCancelled == false && self.isCurrent(gen)
            }
        }
        queue.addOperation(op)
        return gen
    }

    func cancel() {
        _ = nextGeneration(cancelQueued: true)
    }

    private func nextGeneration(cancelQueued: Bool) -> UInt64 {
        if cancelQueued {
            queue.cancelAllOperations()
        }
        lock.lock()
        generation &+= 1
        let gen = generation
        lock.unlock()
        return gen
    }

    private func isCurrent(_ gen: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == gen
    }
}
