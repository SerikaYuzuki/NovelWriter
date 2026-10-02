import Foundation
import NovelCore
@testable import NovelUI
import Testing

struct ThemeContrastTests {
    private func luminance(_ hex: UInt32) -> Double {
        let components = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)]
            .map { value -> Double in
                let channel = value / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
        return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
    }

    @Test func bodyTextContrastInBothAppearances() {
        let foregrounds: [FuminiwaColor] = [.textPrimary, .textSecondary, .accent, .leaf, .warning, .danger]
        let backgrounds: [FuminiwaColor] = [.paper, .surface, .elevatedSurface, .sunken]
        for dark in [false, true] {
            for foreground in foregrounds {
                for background in backgrounds {
                    let front = luminance(dark ? foreground.rgb.dark : foreground.rgb.light)
                    let back = luminance(dark ? background.rgb.dark : background.rgb.light)
                    let contrast = (max(front, back) + 0.05) / (min(front, back) + 0.05)
                    #expect(contrast >= 4.5, "\(foreground) / \(background), dark=\(dark): \(contrast)")
                }
            }
            for foreground in [FuminiwaColor.textPrimary, .textSecondary] {
                let front = luminance(dark ? foreground.rgb.dark : foreground.rgb.light)
                let back = luminance(dark ? FuminiwaColor.accentMuted.rgb.dark : FuminiwaColor.accentMuted.rgb.light)
                #expect((max(front, back) + 0.05) / (min(front, back) + 0.05) >= 4.5)
            }
        }
    }

    @Test func countsInvalidateOnContentChangeEvenWithSameLength() {
        let cache = ManuscriptCountCache()
        var episode = Episode(title: "話", content: "あいう")
        #expect(cache.count(episode) == 3)
        #expect(cache.count(episode) == 3)
        episode.content = "あ\nう"
        #expect(cache.count(episode) == ManuscriptMetrics.countCharacters(in: episode.content))
        episode.content = "👨‍👩‍👧‍👦あ"
        #expect(cache.count(episode) == ManuscriptMetrics.countCharacters(in: episode.content))
    }

    @Test func chapterCountsFollowEditsAdditionsAndRemovals() {
        let cache = ManuscriptCountCache()
        var chapter = Chapter(title: "章", episodes: [Episode(title: "話", content: "あいう")])
        #expect(cache.count(chapter) == 3)
        chapter.episodes[0].content = "あ\nう"
        #expect(cache.count(chapter) == 2)
        chapter.episodes.append(Episode(title: "次の話", content: "えお"))
        #expect(cache.count(chapter) == 4)
        chapter.episodes.removeFirst()
        #expect(cache.count(chapter) == 2)
    }
}
