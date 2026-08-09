import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex synthetic interactive transport must only compile in FUMINIWAExperimental")
#endif

actor CodexSyntheticChannelReuseRegistry {
    static let shared = CodexSyntheticChannelReuseRegistry()

    private final class WeakChannel: @unchecked Sendable {
        weak var value: (any CodexSyntheticInteractiveChannel)?

        init(_ value: any CodexSyntheticInteractiveChannel) {
            self.value = value
        }
    }

    private var claimedChannels: [WeakChannel] = []

    func claim(_ channel: any CodexSyntheticInteractiveChannel) -> Bool {
        claimedChannels.removeAll { $0.value == nil }
        let identity = ObjectIdentifier(channel)
        guard !claimedChannels.contains(where: {
            $0.value.map(ObjectIdentifier.init) == identity
        }) else {
            return false
        }
        claimedChannels.append(WeakChannel(channel))
        return true
    }
}
