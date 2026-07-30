import CoreMedia
import Foundation

public final class TimelineNormalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: CMTime
    private var pausedAt: CMTime?
    private var accumulatedPause = CMTime.zero

    public init(epoch: CMTime) {
        self.epoch = epoch
    }

    public func reset(epoch: CMTime) {
        lock.withLock {
            self.epoch = epoch
            pausedAt = nil
            accumulatedPause = .zero
        }
    }

    public func pause(at time: CMTime) {
        lock.withLock {
            guard pausedAt == nil else { return }
            pausedAt = time
        }
    }

    public func resume(at time: CMTime) {
        lock.withLock {
            guard let pausedAt else { return }
            let interval = CMTimeSubtract(time, pausedAt)
            if interval.isNumeric && interval > .zero {
                accumulatedPause = CMTimeAdd(accumulatedPause, interval)
            }
            self.pausedAt = nil
        }
    }

    public func normalized(_ sourceTime: CMTime) -> CMTime {
        lock.withLock {
            let pause = accumulatedPause
            let effectivePause: CMTime
            if let pausedAt, sourceTime > pausedAt {
                effectivePause = CMTimeAdd(pause, CMTimeSubtract(sourceTime, pausedAt))
            } else {
                effectivePause = pause
            }
            let normalized = CMTimeSubtract(CMTimeSubtract(sourceTime, epoch), effectivePause)
            return normalized.isNumeric && normalized > .zero ? normalized : .zero
        }
    }
}

extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
