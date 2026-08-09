import Foundation
import Security

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex Node executable inspection must only compile in FUMINIWAExperimental")
#endif

enum CodexNodeCodeSignatureInspector {
    static func observe(
        absolutePath: String,
        requestedArchitecture: CodexRuntimeArchitecture
    ) -> CodexNodeCodeSignatureObservation {
        var staticCode: SecStaticCode?
        let attributes = [
            kSecCodeAttributeArchitecture: architectureName(requestedArchitecture)
        ] as CFDictionary
        let createStatus = SecStaticCodeCreateWithPathAndAttributes(
            URL(fileURLWithPath: absolutePath) as CFURL,
            SecCSFlags(rawValue: 0),
            attributes,
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return CodexNodeCodeSignatureObservation(
                validity: .unavailable(status: createStatus),
                cdHash: nil,
                informationStatus: nil
            )
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSStrictValidate
                | kSecCSSingleThreaded
                | SecCSFlags.noNetworkAccess.rawValue
        )
        let validityStatus = SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            nil
        )
        let metadata = signingMetadata(staticCode)
        return observation(
            validityStatus: validityStatus,
            cdHash: metadata.cdHash,
            informationStatus: metadata.status
        )
    }

    private static func architectureName(
        _ architecture: CodexRuntimeArchitecture
    ) -> CFString {
        switch architecture {
        case .arm64:
            "arm64" as CFString
        case .x64:
            "x86_64" as CFString
        }
    }

    private static func signingMetadata(
        _ staticCode: SecStaticCode
    ) -> (cdHash: String?, status: Int32) {
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        let dictionary = information as? [CFString: Any]
        let cdHashData = dictionary?[kSecCodeInfoUnique] as? Data
        let cdHash = cdHashData?.count == 20
            ? cdHashData?.codexRuntimeLowercaseHex
            : nil
        return (cdHash, informationStatus)
    }

    private static func observation(
        validityStatus: Int32,
        cdHash: String?,
        informationStatus: Int32
    ) -> CodexNodeCodeSignatureObservation {
        if validityStatus == errSecCSUnsigned {
            return CodexNodeCodeSignatureObservation(
                validity: .unsigned,
                cdHash: cdHash,
                informationStatus: informationStatus
            )
        }
        guard validityStatus == errSecSuccess else {
            return CodexNodeCodeSignatureObservation(
                validity: .invalid(status: validityStatus),
                cdHash: cdHash,
                informationStatus: informationStatus
            )
        }
        return CodexNodeCodeSignatureObservation(
            validity: .valid,
            cdHash: cdHash,
            informationStatus: informationStatus
        )
    }
}
