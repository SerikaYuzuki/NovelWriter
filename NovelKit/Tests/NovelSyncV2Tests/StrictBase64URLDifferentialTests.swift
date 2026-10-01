import Foundation
import NovelSyncV2
import Testing

@Test func strictBase64URLMatchesFoundationForEveryLengthAndRemainder() {
    var generator = SystemRandomNumberGenerator()
    for length in 0 ... 300 {
        for _ in 0 ..< 20 {
            let bytes = Data((0 ..< length).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            let encoded = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let padded = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            #expect(Data(base64URL: encoded) == Data(base64Encoded: padded))
            #expect(Data(base64URL: encoded) == bytes)
        }
    }
}

@Test func strictBase64URLRejectsNonzeroUnusedBitsAndNonURLAlphabet() throws {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
    // A one-byte tail leaves four unused bits; a two-byte tail leaves two.
    for first in UInt8.min ... UInt8.max {
        for length in [1, 2] {
            let bytes = Data(repeating: first, count: length)
            let valid = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let prefix = String(valid.dropLast())
            let last = try #require(valid.utf8.last)
            let index = try #require(alphabet.firstIndex(of: last))
            let unused = length == 1 ? 15 : 3
            for tail in 1 ... unused {
                let invalid = prefix + String(UnicodeScalar(alphabet[index | tail]))
                #expect(Data(base64URL: invalid) == nil)
            }
        }
    }
    for text in ["A", "AAAAA", "AA=", "AA==", "+w", "/w", "AA\n", " AA", "é"] {
        #expect(Data(base64URL: text) == nil)
    }
}
