import Foundation
import NovelSyncV2
import Testing

@Test(arguments: ["A", "AAAAA", "Zg=", "Zg==", "Zg\n", "Z g", "+w", "/w", "é", "Zh", "Zm9", "_x", "__9"])
func strictBase64RejectsInvalid(_ raw: String) {
    #expect(Data(base64URL: raw) == nil)
}

@Test func strictBase64RoundTripsEveryTail() {
    #expect(Data(base64URL: "") == Data())
    for count in 0 ... 260 {
        let bytes = Data((0 ..< count).map { UInt8($0 % 256) })
        let raw = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(Data(base64URL: raw) == bytes)
    }
}
