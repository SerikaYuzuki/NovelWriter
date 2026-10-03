import NovelTiming
import Testing

struct FuminiwaTimingTests {
    @Test func nonFiniteAndRelatedBounds() {
        let timing = FuminiwaTiming(
            promotionIdleSeconds: 90, promotionMaximumSeconds: 0,
            headPollNormalSeconds: .nan, headPollTypingSeconds: 0,
            sendRetryInitialSeconds: 5, sendRetryMaximumSeconds: -1
        )
        #expect(timing.promotionIdleSeconds == 90)
        #expect(timing.promotionMaximumSeconds == 90)
        #expect(timing.headPollNormalSeconds == 10)
        #expect(timing.headPollTypingSeconds == 1)
        #expect(timing.sendRetryMaximumSeconds == 5)
    }
}
