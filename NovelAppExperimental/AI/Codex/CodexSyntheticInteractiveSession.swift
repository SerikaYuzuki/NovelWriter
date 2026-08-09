import Foundation

// State transitions stay in one actor so ready/start/cancel cannot be split
// across independently isolated owners.
// swiftlint:disable file_length

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex synthetic interactive transport must only compile in FUMINIWAExperimental")
#endif

enum CodexSyntheticInteractiveStopReason: Sendable, Equatable {
    case cancelled
    case attestationTimedOut
    case requestTimedOut
    case terminalDrainTimedOut

    var error: CodexSyntheticInteractiveTransportError {
        switch self {
        case .cancelled:
            .cancelled
        case .attestationTimedOut:
            .attestationTimedOut
        case .requestTimedOut:
            .requestTimedOut
        case .terminalDrainTimedOut:
            .terminalDrainTimedOut
        }
    }
}

private enum CodexSyntheticCancelOutcome: Sendable, Equatable {
    case succeeded
    case failed
}

private enum CodexSyntheticSessionLifecycle: Sendable {
    case running
    case finalizing
    case settled
}

// The actor keeps every protocol phase and stop winner in one isolation domain.
// swiftlint:disable:next type_body_length
actor CodexSyntheticInteractiveSession {
    private let factory: any CodexSyntheticInteractiveChannelFactory
    private let request: CodexSyntheticInteractiveTransportRequest
    private let channelReuseRegistry: CodexSyntheticChannelReuseRegistry
    private let clock = ContinuousClock()

    private var channel: (any CodexSyntheticInteractiveChannel)?
    private var hostState: CodexSidecarHostSessionState
    private var decoder = CodexSidecarFrameDecoder()
    private var stopReason: CodexSyntheticInteractiveStopReason?
    private var cancellationTask: Task<CodexSyntheticCancelOutcome, Never>?
    private var attestationTimer: Task<Void, Never>?
    private var requestTimer: Task<Void, Never>?
    private var terminalDrainTimer: Task<Void, Never>?
    private var openRace: CodexSyntheticOpenRace?
    private var openTask: Task<Bool, Never>?
    private var openCancellationTask: Task<Bool, Never>?
    private var providerTerminalWasClaimed = false
    private var terminalDrainDeadline: ContinuousClock.Instant?
    private var attestationWasClaimed = false
    private var cancellationPreparationFailed = false
    private var lifecycle: CodexSyntheticSessionLifecycle = .running
    private var lateDeliveryWasCancelled = false

    init(
        factory: any CodexSyntheticInteractiveChannelFactory,
        request: CodexSyntheticInteractiveTransportRequest,
        channelReuseRegistry: CodexSyntheticChannelReuseRegistry
    ) {
        self.factory = factory
        self.request = request
        self.channelReuseRegistry = channelReuseRegistry
        hostState = CodexSidecarHostSessionState(
            requestID: request.requestID,
            expectedRuntime: request.expectedRuntime.identity
        )
    }

    func run() async throws -> CodexSyntheticInteractiveTerminal {
        var terminal: CodexSyntheticInteractiveTerminal?
        var primaryError: CodexSyntheticInteractiveTransportError?

        do {
            terminal = try await runProtocol()
        } catch let error as CodexSyntheticInteractiveTransportError {
            primaryError = error
        } catch let error as CodexSidecarLocalError {
            primaryError = .protocolFailure(error)
        } catch {
            primaryError = .channelIOFailed(.readResponse)
        }

        lifecycle = .finalizing
        attestationTimer?.cancel()
        requestTimer?.cancel()
        terminalDrainTimer?.cancel()

        let openCancellationFailed = await openCancellationTask?.value ?? false
        let lateCleanupFailed = await openTask?.value ?? false
        let cancellationOutcome = await cancellationTask?.value
        let cleanupFailed = await cleanupChannel()
        channel = nil
        lifecycle = .settled
        let shouldDropDelivery = lateDeliveryWasCancelled || Task.isCancelled

        if cleanupFailed || lateCleanupFailed || openCancellationFailed {
            throw CodexSyntheticInteractiveTransportError.cleanupFailed
        }
        if cancellationOutcome == .failed || cancellationPreparationFailed {
            throw CodexSyntheticInteractiveTransportError.channelIOFailed(
                .requestCancellation
            )
        }
        if let primaryError {
            throw primaryError
        }
        if shouldDropDelivery {
            throw CodexSyntheticInteractiveTransportError.cancelled
        }
        guard let terminal else {
            throw CodexSyntheticInteractiveTransportError.channelIOFailed(.readResponse)
        }
        return terminal
    }

    func requestStop(_ reason: CodexSyntheticInteractiveStopReason) {
        recordStop(reason)
    }

    // swiftlint:disable:next function_body_length
    private func runProtocol() async throws -> CodexSyntheticInteractiveTerminal {
        let runStartedAt = clock.now
        let attestationDeadline = runStartedAt.advanced(by: request.attestationTimeout)
        let requestDeadline = runStartedAt.advanced(by: request.requestTimeout)
        scheduleAttestationTimeout(request.attestationTimeout)
        scheduleRequestTimeout(request.requestTimeout)
        try checkHandshakeStop(
            attestationDeadline: attestationDeadline,
            requestDeadline: requestDeadline
        )

        let openedChannel: any CodexSyntheticInteractiveChannel
        do {
            openedChannel = try await openChannel()
        } catch {
            try checkHandshakeStop(
                attestationDeadline: attestationDeadline,
                requestDeadline: requestDeadline
            )
            throw error
        }
        let didClaimChannel = await channelReuseRegistry.claim(openedChannel)
        if !didClaimChannel {
            try checkHandshakeStop(
                attestationDeadline: attestationDeadline,
                requestDeadline: requestDeadline
            )
            throw CodexSyntheticInteractiveTransportError.reusedChannel
        }
        channel = openedChannel
        scheduleCancellationIfNeeded()
        try checkHandshakeStop(
            attestationDeadline: attestationDeadline,
            requestDeadline: requestDeadline
        )

        let helloFrame = try hostState.encodeHelloFrame()
        try checkHandshakeStop(
            attestationDeadline: attestationDeadline,
            requestDeadline: requestDeadline
        )
        try await write(
            helloFrame,
            using: openedChannel,
            operation: .writeHello
        )
        try checkHandshakeStop(
            attestationDeadline: attestationDeadline,
            requestDeadline: requestDeadline
        )

        try await receiveIsolatedAttestation(
            using: openedChannel,
            attestationDeadline: attestationDeadline,
            requestDeadline: requestDeadline
        )
        try checkHandshakeStop(
            attestationDeadline: attestationDeadline,
            requestDeadline: requestDeadline
        )
        attestationTimer?.cancel()

        try checkForStop(deadline: requestDeadline, timeoutReason: .requestTimedOut)

        let startFrame = try hostState.encodeStartFrame(
            applicationPayload: request.applicationPayload
        )
        try checkForStop(deadline: requestDeadline, timeoutReason: .requestTimedOut)
        try await write(
            startFrame,
            using: openedChannel,
            operation: .writeStart
        )
        try checkForStop(deadline: requestDeadline, timeoutReason: .requestTimedOut)

        return try await receiveResponse(
            using: openedChannel,
            deadline: requestDeadline
        )
    }

    private func receiveIsolatedAttestation(
        using channel: any CodexSyntheticInteractiveChannel,
        attestationDeadline: ContinuousClock.Instant,
        requestDeadline: ContinuousClock.Instant
    ) async throws {
        while true {
            try checkHandshakeStop(
                attestationDeadline: attestationDeadline,
                requestDeadline: requestDeadline
            )
            guard let bytes = try await read(
                using: channel,
                operation: .readAttestation
            ) else {
                let observedAt = clock.now
                try checkHandshakeStop(
                    attestationDeadline: attestationDeadline,
                    requestDeadline: requestDeadline,
                    observedAt: observedAt
                )
                try decoder.finish()
                try hostState.finishAtEOF()
                return
            }
            let observedAt = clock.now
            try checkHandshakeStop(
                attestationDeadline: attestationDeadline,
                requestDeadline: requestDeadline,
                observedAt: observedAt
            )
            guard !bytes.isEmpty else {
                throw CodexSyntheticInteractiveTransportError.channelIOFailed(
                    .readAttestation
                )
            }

            let frames = try decoder.append(bytes)
            guard !frames.isEmpty else { continue }
            guard frames.count == 1, decoder.isAtFrameBoundary else {
                throw CodexSyntheticInteractiveTransportError.attestationFrameNotIsolated
            }
            let event = try CodexSidecarMessageCodec.decodeEvent(frame: frames[0])
            try checkHandshakeStop(
                attestationDeadline: attestationDeadline,
                requestDeadline: requestDeadline,
                observedAt: observedAt
            )
            try hostState.accept(event)
            claimAttestation()
            return
        }
    }

    private func receiveResponse(
        using channel: any CodexSyntheticInteractiveChannel,
        deadline: ContinuousClock.Instant
    ) async throws -> CodexSyntheticInteractiveTerminal {
        var terminal: CodexSyntheticInteractiveTerminal?

        while true {
            try checkResponseStop(deadline: deadline)
            guard let bytes = try await read(using: channel, operation: .readResponse) else {
                let observedAt = clock.now
                try checkResponseStop(deadline: deadline, observedAt: observedAt)
                try decoder.finish()
                try hostState.finishAtEOF()
                guard let terminal else {
                    throw CodexSidecarLocalError.unexpectedEOF
                }
                return terminal
            }
            let observedAt = clock.now
            try checkResponseStop(deadline: deadline, observedAt: observedAt)
            guard !bytes.isEmpty else {
                throw CodexSyntheticInteractiveTransportError.channelIOFailed(
                    .readResponse
                )
            }

            for frame in try decoder.append(bytes) {
                try checkResponseStop(deadline: deadline, observedAt: observedAt)
                let event = try CodexSidecarMessageCodec.decodeEvent(frame: frame)
                try checkResponseStop(deadline: deadline, observedAt: observedAt)
                try hostState.accept(event)
                switch event {
                case .ready, .started:
                    break
                case let .completed(_, structuredOutput, usage):
                    claimProviderTerminal(observedAt: observedAt)
                    terminal = .completed(
                        structuredOutput: structuredOutput,
                        usage: usage
                    )
                case let .failed(_, code):
                    claimProviderTerminal(observedAt: observedAt)
                    terminal = .failed(code)
                }
            }
        }
    }

    private func write(
        _ frame: Data,
        using channel: any CodexSyntheticInteractiveChannel,
        operation: CodexSyntheticChannelOperation
    ) async throws {
        do {
            try await channel.write(frame)
        } catch {
            if Task.isCancelled {
                recordStop(.cancelled)
            }
            if let stopReason {
                throw stopReason.error
            }
            throw CodexSyntheticInteractiveTransportError.channelIOFailed(operation)
        }
    }

    private func read(
        using channel: any CodexSyntheticInteractiveChannel,
        operation: CodexSyntheticChannelOperation
    ) async throws -> Data? {
        do {
            return try await channel.read()
        } catch {
            if Task.isCancelled {
                recordStop(.cancelled)
            }
            if let stopReason {
                throw stopReason.error
            }
            throw CodexSyntheticInteractiveTransportError.channelIOFailed(operation)
        }
    }

    private func checkForStop(
        deadline: ContinuousClock.Instant,
        timeoutReason: CodexSyntheticInteractiveStopReason
    ) throws {
        if Task.isCancelled {
            recordStop(.cancelled)
        } else if clock.now >= deadline {
            recordStop(timeoutReason)
        }
        if let stopReason {
            throw stopReason.error
        }
    }

    private func checkHandshakeStop(
        attestationDeadline: ContinuousClock.Instant,
        requestDeadline: ContinuousClock.Instant,
        observedAt: ContinuousClock.Instant? = nil
    ) throws {
        if Task.isCancelled {
            recordStop(.cancelled)
        } else if stopReason == nil {
            let now = observedAt ?? clock.now
            let firstDeadline = attestationWasClaimed
                ? requestDeadline
                : min(attestationDeadline, requestDeadline)
            if now >= firstDeadline {
                let reason: CodexSyntheticInteractiveStopReason =
                    attestationWasClaimed || requestDeadline < attestationDeadline
                        ? .requestTimedOut
                        : .attestationTimedOut
                recordStop(reason)
            }
        }
        if let stopReason {
            throw stopReason.error
        }
    }

    private func checkResponseStop(
        deadline: ContinuousClock.Instant,
        observedAt: ContinuousClock.Instant? = nil
    ) throws {
        let now = observedAt ?? clock.now
        let deadlineExpired = now >= deadline
        let terminalDrainExpired = terminalDrainDeadline.map { now >= $0 } ?? false
        if Task.isCancelled {
            recordStop(.cancelled)
        } else if providerTerminalWasClaimed, terminalDrainExpired {
            recordStop(.terminalDrainTimedOut)
        } else if !providerTerminalWasClaimed, deadlineExpired {
            recordStop(.requestTimedOut)
        }
        if let stopReason {
            throw stopReason.error
        }
    }

    private func recordStop(_ reason: CodexSyntheticInteractiveStopReason) {
        switch lifecycle {
        case .settled:
            return
        case .finalizing:
            if reason == .cancelled {
                lateDeliveryWasCancelled = true
            }
            return
        case .running:
            break
        }
        if reason == .attestationTimedOut, attestationWasClaimed {
            return
        }
        if reason == .requestTimedOut, providerTerminalWasClaimed {
            return
        }
        guard stopReason == nil else { return }
        stopReason = reason
        if openRace != nil, openCancellationTask == nil {
            let factory = factory
            openCancellationTask = Task.detached {
                do {
                    try await factory.requestOpenCancellation()
                    return false
                } catch {
                    return true
                }
            }
        }
        openRace?.resolve(.stopped(reason))
        openTask?.cancel()
        scheduleCancellationIfNeeded()
    }

    private func claimAttestation() {
        guard !attestationWasClaimed else { return }
        attestationWasClaimed = true
        attestationTimer?.cancel()
    }

    private func claimProviderTerminal(observedAt: ContinuousClock.Instant) {
        guard !providerTerminalWasClaimed else { return }
        providerTerminalWasClaimed = true
        requestTimer?.cancel()
        let deadline = observedAt.advanced(
            by: CodexSyntheticInteractiveTransportRequest.terminalDrainTimeout
        )
        terminalDrainDeadline = deadline
        let remaining = clock.now.duration(to: deadline)
        terminalDrainTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: max(.zero, remaining))
            } catch {
                return
            }
            await self?.requestStop(.terminalDrainTimedOut)
        }
    }

    private func openChannel() async throws -> any CodexSyntheticInteractiveChannel {
        let race = CodexSyntheticOpenRace()
        openRace = race
        let factory = factory
        let task = Task {
            do {
                let channel = try await factory.openContentFree()
                guard race.resolve(.opened(channel)) else {
                    let ownsLateChannel = await channelReuseRegistry.claim(channel)
                    guard ownsLateChannel else {
                        return false
                    }
                    let cleanupTask = Task.detached {
                        do {
                            try await channel.cleanup()
                            return false
                        } catch {
                            return true
                        }
                    }
                    return await cleanupTask.value
                }
                return false
            } catch {
                race.resolve(.failed)
                return false
            }
        }
        openTask = task

        if let stopReason {
            task.cancel()
            race.resolve(.stopped(stopReason))
        }

        let outcome = await race.wait()
        openRace = nil
        switch outcome {
        case let .opened(channel):
            openTask = nil
            return channel
        case .failed:
            openTask = nil
            if Task.isCancelled {
                recordStop(.cancelled)
            }
            if let stopReason {
                throw stopReason.error
            }
            throw CodexSyntheticInteractiveTransportError.channelOpenFailed
        case let .stopped(reason):
            throw reason.error
        }
    }

    private func scheduleCancellationIfNeeded() {
        guard cancellationTask == nil, let channel, stopReason != nil else { return }

        let cancelFrame: Data?
        switch hostState.phase {
        case .awaitingStarted, .started:
            do {
                cancelFrame = try hostState.encodeCancelFrame()
            } catch {
                cancellationPreparationFailed = true
                cancelFrame = nil
            }
        case .awaitingHello, .awaitingReady, .attested, .terminal, .closed:
            cancelFrame = nil
        }

        cancellationTask = Task.detached {
            do {
                try await channel.requestCancellation(cancelFrame: cancelFrame)
                return .succeeded
            } catch {
                return .failed
            }
        }
    }

    private func scheduleAttestationTimeout(_ timeout: Duration) {
        attestationTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.requestStop(.attestationTimedOut)
        }
    }

    private func scheduleRequestTimeout(_ timeout: Duration) {
        requestTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.requestStop(.requestTimedOut)
        }
    }

    private func cleanupChannel() async -> Bool {
        guard let channel else { return false }
        let cleanupTask = Task.detached {
            do {
                try await channel.cleanup()
                return false
            } catch {
                return true
            }
        }
        return await cleanupTask.value
    }
}
