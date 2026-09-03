import Foundation

/// Multicasts one agent event feed to every screen that is listening.
///
/// A bare `AsyncStream` is unicast: when two transcripts iterate the same
/// stream, each element goes to exactly one of them and the other silently
/// never sees it. Clients publish through this instead, and each `stream()`
/// caller gets its own delivery of every event published from then on.
public final class EventFanout: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EventEnvelope>.Continuation] = [:]
    private var replay: [EventEnvelope] = []
    private let replayLimit: Int
    private var isFinished = false

    /// - Parameter replayLimit: how many recent events a new subscriber
    ///   receives on attach. A screen subscribes a moment after it asks for
    ///   history, and without a small replay the events in between are lost.
    public init(replayLimit: Int = 256) {
        self.replayLimit = replayLimit
    }

    public func stream() -> AsyncStream<EventEnvelope> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            lock.lock()
            let backlog = replay
            let finished = isFinished
            if !finished { continuations[id] = continuation }
            lock.unlock()

            for envelope in backlog {
                continuation.yield(envelope)
            }
            if finished {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock()
                continuations[id] = nil
                lock.unlock()
            }
        }
    }

    public func yield(_ envelope: EventEnvelope) {
        lock.lock()
        replay.append(envelope)
        if replay.count > replayLimit {
            replay.removeFirst(replay.count - replayLimit)
        }
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(envelope)
        }
    }

    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        isFinished = true
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }
}
