import Foundation
import NovelTiming
import Observation

/// One foreground lane per document host. Manuscript saves never await this lane.
@MainActor @Observable
public final class WritingSyncScheduler {
    public private(set) var revision = 0
    public private(set) var failed = false
    @ObservationIgnored private let timing: FuminiwaTiming
    @ObservationIgnored private let now: () -> Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var contextID: String?
    @ObservationIgnored private var operation: (() async throws -> Void)?
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var visible: [String: Set<UUID>] = [:]
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryAfter = Duration.zero
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var flight: Task<Void, Error>?
    @ObservationIgnored private var flightID: UUID?
    @ObservationIgnored private var pendingAppend = false

    public init(
        timing: FuminiwaTiming = .init(),
        now: (() -> Duration)? = nil,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        let origin = ContinuousClock.now
        self.timing = timing
        self.now = now ?? { origin.duration(to: .now) }
        self.sleep = sleep
    }

    public func attach(contextID: String, foreground: Bool, synchronize: @escaping () async throws -> Void) {
        if self.contextID != contextID {
            stopFlight()
            self.contextID = contextID
            failures = 0; retryAfter = .zero; failed = false
        }
        operation = synchronize
        self.foreground = foreground
        if foreground {
            schedule(after: .zero)
        } else {
            stopFlight()
        }
    }

    public func detach(contextID: String) {
        guard self.contextID == contextID else { return }
        stopFlight()
        foreground = false
        operation = nil
    }

    public func setForeground(_ value: Bool, contextID: String) {
        guard self.contextID == contextID, foreground != value else { return }
        foreground = value
        if value {
            schedule(after: .zero)
        } else {
            stopFlight()
        }
    }

    public func setVisible(_ value: Bool, token: UUID, contextID: String) {
        let wasVisible = visible[contextID]?.isEmpty == false
        if value {
            visible[contextID, default: []].insert(token)
        } else {
            visible[contextID]?.remove(token)
            if visible[contextID]?.isEmpty == true {
                visible.removeValue(forKey: contextID)
            }
        }
        guard self.contextID == contextID, wasVisible != (visible[contextID]?.isEmpty == false) else { return }
        schedule(after: value || failed ? .zero : interval)
    }

    public func recordAppended(contextID: String) {
        guard self.contextID == contextID else { return }
        pendingAppend = true
        schedule(after: .zero)
    }

    /// Explicit reads/sends also share single-flight and the failure cooldown.
    public func synchronize(contextID: String) async throws {
        guard self.contextID == contextID, foreground, let operation else { return }
        if let flight {
            try await flight.value; return
        }
        guard now() >= retryAfter else { throw WritingError.unavailable }
        timer?.cancel(); timer = nil
        pendingAppend = false
        let id = UUID()
        flightID = id
        let task = Task { try await operation() }
        flight = task
        do {
            try await task.value
            guard flightID == id, self.contextID == contextID, foreground else { return }
            flight = nil; flightID = nil
            failures = 0; retryAfter = .zero; failed = false
            revision &+= 1
            schedule(after: pendingAppend ? .zero : interval)
        } catch {
            guard flightID == id else { throw error }
            flight = nil; flightID = nil
            if !(error is CancellationError) {
                failures = min(failures + 1, 13)
                failed = true
                let retry = timing.writingSyncRetryInitialSeconds * Double(1 << (failures - 1))
                retryAfter = now() + .seconds(min(timing.writingSyncRetryMaximumSeconds, retry))
            }
            schedule(after: error is CancellationError ? interval : .zero)
            throw error
        }
    }

    private var interval: Duration {
        .seconds(visible[contextID ?? ""]?.isEmpty == false
            ? timing.writingSyncVisibleSeconds : timing.writingSyncHiddenSeconds)
    }

    private func schedule(after delay: Duration) {
        timer?.cancel(); timer = nil
        guard foreground, flight == nil, let contextID else { return }
        let delay = max(delay, retryAfter - now())
        let sleep = sleep
        timer = Task { [weak self] in
            do {
                try await sleep(max(.zero, delay))
                try Task.checkCancellation()
                guard let self, self.contextID == contextID, foreground else { return }
                timer = nil
                try await synchronize(contextID: contextID)
            } catch { /* synchronize owns retry policy; canceled sleeps never wake it. */ }
        }
    }

    private func stopFlight() {
        timer?.cancel(); timer = nil
        flight?.cancel(); flight = nil; flightID = nil
        pendingAppend = false
    }
}
