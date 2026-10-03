import Foundation
import NovelCore
import NovelUI
import Testing

@Test func outlineCountCachePreservesMetricsAfterReplacement() {
    let cache = ManuscriptCountCache()
    var episode = Episode(title: "話", content: "文\n👨‍👩‍👧‍👦\r\nか\u{3099}")
    #expect(cache.count(episode) == ManuscriptMetrics.countCharacters(in: episode.content))
    #expect(cache.count(episode) == ManuscriptMetrics.countCharacters(in: episode.content))
    episode.content = "変更\n本文"
    #expect(cache.count(episode) == ManuscriptMetrics.countCharacters(in: episode.content))
    episode.title = "改題"
    #expect(cache.count(episode) == 4)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_TYPING_BENCHMARK"] == "1"))
func typingEnergyOutlineCountBenchmark() {
    let cache = ManuscriptCountCache()
    var episodes = (0 ..< 150).map { Episode(title: "話\($0)", content: String(repeating: "文", count: 2000)) }
    for episode in episodes {
        _ = cache.count(episode)
    }
    var before: [Double] = [], after: [Double] = []
    for _ in 0 ..< 10 {
        episodes[0].content += "字"
        let start = ContinuousClock.now
        let old = episodes.reduce(0) { total, episode in
            let display = ManuscriptMetrics.countCharacters(in: episode.content)
            let accessibility = ManuscriptMetrics.countCharacters(in: episode.content)
            return total + display + accessibility
        }
        let middle = ContinuousClock.now
        let new = episodes.reduce(0) { $0 + cache.count($1) * 2 }
        let finish = ContinuousClock.now
        #expect(old == new)
        before.append(outlineMilliseconds(start.duration(to: middle)))
        after.append(outlineMilliseconds(middle.duration(to: finish)))
    }
    print("TYPING outline 300000 chars 150 rows median_ms before=\(before.sorted()[5]) after=\(after.sorted()[5])")
}

private func outlineMilliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
