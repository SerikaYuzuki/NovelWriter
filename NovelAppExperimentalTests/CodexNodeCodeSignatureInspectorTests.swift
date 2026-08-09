@testable import FUMINIWAExperimental
import Security
import Testing

@Test("OS提供universal executableの署名をarchitecture別に観測する")
func codexNodeCodeSignatureInspectorHonorsRequestedArchitecture() throws {
    let arm64Observation = CodexNodeCodeSignatureInspector.observe(
        absolutePath: "/usr/bin/git",
        requestedArchitecture: .arm64
    )
    let x64Observation = CodexNodeCodeSignatureInspector.observe(
        absolutePath: "/usr/bin/git",
        requestedArchitecture: .x64
    )

    let arm64CDHash = try availableOSFixtureCDHash(arm64Observation)
    let x64CDHash = try availableOSFixtureCDHash(x64Observation)

    #if arch(arm64)
    #expect(arm64CDHash != nil)
    #elseif arch(x86_64)
    #expect(x64CDHash != nil)
    #else
    Issue.record("unsupported test host architecture")
    #endif

    #expect(arm64Observation != x64Observation)
    if let arm64CDHash, let x64CDHash {
        #expect(arm64CDHash != x64CDHash)
    }
}

private func availableOSFixtureCDHash(
    _ observation: CodexNodeCodeSignatureObservation
) throws -> String? {
    switch observation.validity {
    case let .unavailable(createStatus):
        #expect(createStatus != errSecSuccess)
        #expect(observation.cdHash == nil)
        #expect(observation.informationStatus == nil)
        return nil
    case .valid:
        return try recordedOSFixtureCDHash(observation)
    case let .invalid(validityStatus):
        #expect(validityStatus != errSecSuccess)
        return try recordedOSFixtureCDHash(observation)
    case .unsigned:
        Issue.record("OS-provided signed fixture was unexpectedly unsigned")
        return nil
    }
}

private func recordedOSFixtureCDHash(
    _ observation: CodexNodeCodeSignatureObservation
) throws -> String {
    #expect(observation.informationStatus != nil)
    let cdHash = try #require(observation.cdHash)
    #expect(cdHash.utf8.count == 40)
    #expect(cdHash.utf8.allSatisfy(isLowercaseHexDigit))
    return cdHash
}

private func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
        || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
}
