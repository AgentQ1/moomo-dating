import Foundation

/// Fan-out state holder for the mock social services: keeps the latest value
/// and streams every change to any number of observers, each stream opening
/// with the current value.
///
/// That is the shape of a Firestore snapshot listener — subscribe, get the
/// current snapshot, then get every change — so models written against these
/// mocks port to the live services unchanged.
///
/// Same continuation-dictionary pattern `MockAuthenticationService` hand-rolls
/// for `userStream`; pulled out because five services each need it.
final class StreamBroadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var currentValue: Value

    init(_ initial: Value) {
        currentValue = initial
    }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return currentValue
    }

    /// A new stream, opening with the current value.
    func stream() -> AsyncStream<Value> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let value = currentValue
            lock.unlock()

            continuation.yield(value)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations[id] = nil
                lock.unlock()
            }
        }
    }

    func send(_ value: Value) {
        lock.lock()
        currentValue = value
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(value) }
    }

    /// Mutate under the lock, then broadcast the result.
    func update(_ mutate: (inout Value) -> Void) {
        lock.lock()
        mutate(&currentValue)
        let value = currentValue
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(value) }
    }
}
