import Foundation

public actor RecordingEngine {
    public typealias UpdateHandler = @Sendable (RecordingSnapshot) -> Void

    private let factory: any RecordingPipelineFactory
    private let updateHandler: UpdateHandler
    private var snapshot = RecordingSnapshot.idle
    private var pipeline: (any RecordingPipeline)?
    private var eventTask: Task<Void, Never>?
    private var countdownToken: UUID?

    public init(
        factory: any RecordingPipelineFactory = LiveRecordingPipelineFactory(),
        updateHandler: @escaping UpdateHandler = { _ in }
    ) {
        self.factory = factory
        self.updateHandler = updateHandler
    }

    public func currentSnapshot() -> RecordingSnapshot {
        snapshot
    }

    public func beginSelection() {
        guard [.idle, .completed, .failed].contains(snapshot.phase) else { return }
        transition(.selecting)
    }

    public func endSelection() {
        guard snapshot.phase == .selecting else { return }
        transition(.idle)
    }

    public func start(_ request: RecordingRequest, countdown: Int = 3) async throws {
        guard [.idle, .completed, .failed].contains(snapshot.phase) else {
            throw RecorderError.invalidConfiguration("A recording is already active.")
        }
        let issues = request.configuration.validationIssues(
            hasResolvedScreenTarget: request.screenTarget != nil
        )
        if let issue = issues.first {
            throw RecorderError.invalidConfiguration(issue.message)
        }

        do {
            let pipeline = try factory.makePipeline(for: request)
            self.pipeline = pipeline
            try await pipeline.prepare()
            let token = UUID()
            countdownToken = token

            if countdown > 0 {
                for remaining in stride(from: countdown, through: 1, by: -1) {
                    guard countdownToken == token else { return }
                    transition(.countingDown, countdown: remaining)
                    try await Task.sleep(for: .seconds(1))
                }
            }
            guard countdownToken == token else { return }
            countdownToken = nil

            try await pipeline.start()
            transition(.recording)
            observeEvents(from: pipeline)
        } catch is CancellationError {
            await pipeline?.cancel()
            pipeline = nil
            transition(.idle)
            throw RecorderError.cancelled
        } catch {
            await pipeline?.cancel()
            pipeline = nil
            transition(.failed, message: error.localizedDescription)
            throw error
        }
    }

    public func cancelCountdown() async {
        guard snapshot.phase == .countingDown else { return }
        countdownToken = nil
        await pipeline?.cancel()
        pipeline = nil
        transition(.idle)
    }

    public func pause() async {
        guard snapshot.phase == .recording, let pipeline else { return }
        await pipeline.pause()
        transition(.paused)
    }

    public func resume() async {
        guard snapshot.phase == .paused, let pipeline else { return }
        await pipeline.resume()
        transition(.recording)
    }

    @discardableResult
    public func stop(message: String? = nil) async throws -> URL? {
        guard [.recording, .paused].contains(snapshot.phase), let pipeline else {
            return snapshot.outputURL
        }
        transition(.finalizing, message: message)
        eventTask?.cancel()
        eventTask = nil
        do {
            let url = try await pipeline.stop()
            self.pipeline = nil
            transition(.completed, outputURL: url, message: message)
            return url
        } catch {
            await pipeline.cancel()
            self.pipeline = nil
            transition(.failed, message: error.localizedDescription)
            throw error
        }
    }

    public func reset() async {
        guard [.completed, .failed].contains(snapshot.phase) else { return }
        transition(.idle)
    }

    public func cancelActiveRecording() async {
        countdownToken = nil
        eventTask?.cancel()
        eventTask = nil
        await pipeline?.cancel()
        pipeline = nil
        transition(.idle)
    }

    private func observeEvents(from pipeline: any RecordingPipeline) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in pipeline.events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: PipelineEvent) async {
        switch event {
        case let .warning(message):
            transition(snapshot.phase, message: message)
        case let .stopRequested(message):
            _ = try? await stop(message: message)
        case let .fatal(message):
            await pipeline?.cancel()
            pipeline = nil
            transition(.failed, message: message)
        }
    }

    private func transition(
        _ phase: RecordingPhase,
        countdown: Int? = nil,
        outputURL: URL? = nil,
        message: String? = nil
    ) {
        snapshot = RecordingSnapshot(
            phase: phase,
            countdown: countdown,
            outputURL: outputURL,
            message: message
        )
        updateHandler(snapshot)
    }
}
