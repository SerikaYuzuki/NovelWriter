import Foundation
import Observation
import OSLog

public struct AssistantRuntimeTiming: Sendable {
    public static let defaultStallSeconds = 60.0
    public static let defaultChatMaxSeconds = 180.0
    public static let defaultReviewMaxSeconds = 150.0
    public static let defaultTickSeconds = 1.0
    public enum Key {
        public static let stall = "fuminiwa.timing.assistantStallSeconds"
        public static let chatMax = "fuminiwa.timing.assistantChatMaxSeconds"
        public static let reviewMax = "fuminiwa.timing.assistantReviewMaxSeconds"
        public static let tick = "fuminiwa.timing.assistantTickSeconds"
    }

    public let stallSeconds: Double
    public let maxSeconds: Double
    public let tickSeconds: Double
    public init(defaults: UserDefaults, purpose: AssistantPurpose) {
        func value(_ key: String, _ fallback: Double) -> Double {
            guard let number = defaults.object(forKey: key) as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { return fallback }
            return number.doubleValue
        }
        stallSeconds = value(Key.stall, Self.defaultStallSeconds)
        maxSeconds = value(purpose == .advice ? Key.chatMax : Key.reviewMax,
                           purpose == .advice ? Self.defaultChatMaxSeconds : Self.defaultReviewMaxSeconds)
        tickSeconds = value(Key.tick, Self.defaultTickSeconds)
    }
}

public struct AssistantRequestKey: Hashable, Sendable {
    public let work: UUID
    public let account: String
    public let lane: String
    public init(work: UUID, account: String, lane: String) {
        self.work = work; self.account = account; self.lane = lane
    }
}

@MainActor @Observable
public final class AssistantRequestCenter {
    public struct Status {
        public let id: UUID
        public var progress = AssistantProgress(phase: .queued)
        public var elapsedSeconds = 0
        public var stalled = false
        public var inFlight = true
        public var failure: String?
    }

    public private(set) var statuses: [AssistantRequestKey: Status] = [:]
    public private(set) var revision = 0
    public var conversationSelections: [AssistantRequestKey: UUID] = [:]
    public var conversationPermissions: [AssistantRequestKey: String] = [:]
    @ObservationIgnored private var tasks: [AssistantRequestKey: Task<Void, Never>] = [:]
    @ObservationIgnored private var starts: [AssistantRequestKey: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var events: [AssistantRequestKey: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var cancellationCategories: [AssistantRequestKey: String] = [:]
    @ObservationIgnored public var unsentRetries: [AssistantRequestKey: @MainActor () -> Void] = [:]
    @ObservationIgnored public var recoveredRequestIDs: Set<UUID> = []
    @ObservationIgnored private var cancellation: [AssistantRequestKey: String] = [:]
    private static let logger = Logger(subsystem: "dev.serikayuzuki.fuminiwa", category: "assistant")
    public init() {}

    @discardableResult
    public func start(key: AssistantRequestKey, id: UUID = UUID(), timing: AssistantRuntimeTiming,
                      operation: @escaping @MainActor (UUID, @escaping @MainActor (AssistantProgress) -> Void) async throws -> Void,
                      ended: @escaping @MainActor (UUID, String?) async throws -> Void = { _, _ in }) -> Bool {
        guard statuses[key]?.inFlight != true else { return false }
        statuses[key] = Status(id: id); starts[key] = .now; events[key] = .now; cancellation[key] = nil
        tasks[key] = Task { @MainActor [self] in
            let watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(timing.tickSeconds)) } catch { return }
                    tick(key: key, id: id, timing: timing)
                }
            }
            var failure: String?
            do {
                try Task.checkCancellation()
                try await operation(id) { [weak self] progress in self?.heartbeat(key: key, id: id, progress: progress) }
                try Task.checkCancellation()
            } catch {
                failure = cancellation[key] ?? Self.reason(error)
                let category = cancellationCategories[key] ?? Self.category(error)
                Self.logger.error("request failed: \(category, privacy: .public)")
            }
            watchdog.cancel()
            // Keep the single-flight slot until the durable terminal marker is saved.
            do { try await ended(id, failure) } catch {
                failure = failure ?? "依頼の結果状態を保存できませんでした。AIパネルを開いて確認してください。"
                Self.logger.error("request failed: persistence")
            }
            if statuses[key]?.id == id {
                statuses[key]?.inFlight = false; statuses[key]?.failure = failure
                tasks[key] = nil; starts[key] = nil; events[key] = nil; cancellation[key] = nil; cancellationCategories[key] = nil
                revision += 1
            }
        }
        return true
    }

    public func cancel(_ key: AssistantRequestKey, reason: String = "中止しました。再送できます。", category: String = "cancelled") {
        guard statuses[key]?.inFlight == true else { return }
        cancellation[key] = reason; cancellationCategories[key] = category; tasks[key]?.cancel()
    }

    public func retryUnsent(_ key: AssistantRequestKey) -> Bool {
        guard statuses[key]?.inFlight != true, let retry = unsentRetries[key] else { return false }
        retry(); return true
    }

    public func cancelAll() {
        unsentRetries.removeAll()
        for key in tasks.keys {
            cancel(key, reason: "アカウントが変わったため中断しました。")
        }
    }

    public func cancel(work: UUID) {
        unsentRetries = unsentRetries.filter { $0.key.work != work }
        for key in tasks.keys where key.work == work {
            cancel(key, reason: "作品が削除されたため中断しました。")
        }
    }

    public func wait(_ key: AssistantRequestKey) {
        events[key] = .now; statuses[key]?.stalled = false
    }

    public func isRunning(_ id: UUID) -> Bool {
        statuses.values.contains { $0.id == id && $0.inFlight }
    }

    public func changed() {
        revision += 1
    }

    func heartbeat(key: AssistantRequestKey, id: UUID, progress: AssistantProgress) {
        guard statuses[key]?.id == id, statuses[key]?.inFlight == true else { return }
        events[key] = .now; statuses[key]?.progress = progress; statuses[key]?.stalled = false
    }

    func tick(key: AssistantRequestKey, id: UUID, timing: AssistantRuntimeTiming, now: ContinuousClock.Instant = .now) {
        guard statuses[key]?.id == id, let start = starts[key], let event = events[key] else { return }
        let elapsed = start.duration(to: now)
        statuses[key]?.elapsedSeconds = Int(elapsed.components.seconds)
        if elapsed >= .seconds(timing.maxSeconds) {
            cancel(key, reason: "制限時間を超えたため中断しました。再送してください。", category: "timeout")
        } else if event.duration(to: now) >= .seconds(timing.stallSeconds), statuses[key]?.progress.phase != .elapsedOnly {
            statuses[key]?.stalled = true
        }
    }

    private static func category(_ error: Error) -> String {
        if error is CancellationError {
            return "cancelled"
        }
        if let error = error as? URLError {
            return error.code == .timedOut ? "timeout" : "network"
        }
        if let error = error as? AssistantError {
            switch error { case let .http(code): return "http_\(code)"; default: return String(describing: error) }
        }
        return "invalid_response_or_persistence"
    }

    private static func reason(_ error: Error) -> String {
        if error is CancellationError {
            return "中断しました。再送してください。"
        }
        if let error = error as? URLError {
            return error.code == .timedOut ? "通信が時間切れになりました。再送してください。" : "ネットワークに接続できませんでした。接続を確認して再送してください。"
        }
        if error is DecodingError {
            return AssistantError.invalidResponse.localizedDescription
        }
        return error.localizedDescription
    }
}
