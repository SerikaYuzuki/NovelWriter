import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex deployment manifest verification must only compile in FUMINIWAExperimental")
#endif

enum CodexDeploymentManifestResourceBudget {
    static func addingFileSize(_ size: UInt64, to current: UInt64) throws -> UInt64 {
        let total = current.addingReportingOverflow(size)
        let isWithinLimit = !total.overflow
            && total.partialValue <= CodexDeploymentManifestLimits.maximumTotalFileBytes
        guard isWithinLimit else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        return total.partialValue
    }
}

struct CodexDeploymentManifestBuilder {
    private struct StabilityCheck {
        let absolutePath: String
        let metadata: stat
    }

    private struct Context {
        var entries: [CodexDeploymentManifestEntry] = []
        var coveredEntryCount = 1
        var emittedEntryCount = 0
        var totalFileBytes: UInt64 = 0
        var canonicalByteCount = 35 + 4 + 8
        var stabilityChecks: [StabilityCheck] = []
    }

    private struct DirectoryFrame {
        let absolutePath: String
        let relativeBytes: Data
        let relativePath: String
        let initialMetadata: stat
        let components: [Data]
        var nextComponentIndex = 0
    }

    let rootPath: String
    let testingHooks: CodexDeploymentManifestTestingHooks

    func build() throws -> [CodexDeploymentManifestEntry] {
        let rootMetadata = try CodexDeploymentManifestFileIO.requireCanonicalRoot(rootPath)
        var context = Context()
        var stack = try [beginDirectory(
            absolutePath: rootPath,
            relativeBytes: Data(),
            initialMetadata: rootMetadata,
            context: &context
        )]

        while !stack.isEmpty {
            let frame = stack[stack.index(before: stack.endIndex)]
            if frame.nextComponentIndex >= frame.components.count {
                try completeLastDirectory(stack: &stack, context: &context)
                continue
            }
            try visitNextComponent(stack: &stack, context: &context)
        }

        guard context.emittedEntryCount == context.coveredEntryCount else {
            throw CodexDeploymentManifestError.treeChanged
        }
        try verifyStableSnapshot(context.stabilityChecks)
        return context.entries
    }

    private func completeLastDirectory(
        stack: inout [DirectoryFrame],
        context: inout Context
    ) throws {
        let completed = stack.removeLast()
        testingHooks.afterDirectoryTraversal?(completed.relativePath)
        let finalMetadata = try CodexDeploymentManifestFileIO
            .stableLstat(completed.absolutePath)
        try CodexDeploymentManifestFileIO.requireStable(
            completed.initialMetadata,
            finalMetadata
        )
        context.stabilityChecks.append(
            StabilityCheck(
                absolutePath: completed.absolutePath,
                metadata: finalMetadata
            )
        )
    }

    private func visitNextComponent(
        stack: inout [DirectoryFrame],
        context: inout Context
    ) throws {
        let frameIndex = stack.index(before: stack.endIndex)
        let frame = stack[frameIndex]
        let componentBytes = frame.components[frame.nextComponentIndex]
        stack[frameIndex].nextComponentIndex += 1
        let component = try CodexDeploymentManifestVerifier
            .decodeCanonicalComponent(componentBytes)
        let childRelativeBytes = joinedRelativePath(frame.relativeBytes, componentBytes)
        let childPath = try CodexDeploymentManifestVerifier
            .decodeCanonicalRelativePath(childRelativeBytes)
        let childAbsolutePath = joinedAbsolutePath(frame.absolutePath, component)
        let childMetadata = try CodexDeploymentManifestFileIO
            .stableLstat(childAbsolutePath)

        if isSelfManifest(childRelativeBytes) {
            try validateExcludedSelfManifest(
                absolutePath: childAbsolutePath,
                metadata: childMetadata,
                context: &context
            )
            return
        }

        try CodexDeploymentManifestFileIO.validateSupportedEntry(childMetadata)
        if CodexDeploymentManifestFileIO.fileType(childMetadata) == mode_t(S_IFDIR) {
            try stack.append(beginDirectory(
                absolutePath: childAbsolutePath,
                relativeBytes: childRelativeBytes,
                initialMetadata: childMetadata,
                context: &context
            ))
        } else {
            try visitFile(
                absolutePath: childAbsolutePath,
                relativePath: childPath,
                relativeBytes: childRelativeBytes,
                initialMetadata: childMetadata,
                context: &context
            )
        }
    }

    private func beginDirectory(
        absolutePath: String,
        relativeBytes: Data,
        initialMetadata: stat,
        context: inout Context
    ) throws -> DirectoryFrame {
        try CodexDeploymentManifestFileIO.validateSupportedEntry(initialMetadata)
        guard CodexDeploymentManifestFileIO.fileType(initialMetadata) == mode_t(S_IFDIR) else {
            throw CodexDeploymentManifestError.unsupportedEntry
        }

        let relativePath = relativeBytes.isEmpty
            ? ""
            : try CodexDeploymentManifestVerifier.decodeCanonicalRelativePath(relativeBytes)
        try addEntry(
            CodexDeploymentManifestEntry(
                kind: .directory,
                path: relativePath,
                pathBytes: relativeBytes,
                mode: CodexDeploymentManifestFileIO.permissionMode(initialMetadata),
                size: nil,
                digest: nil
            ),
            context: &context
        )

        let components = try CodexDeploymentManifestDirectoryIO.components(
            at: absolutePath,
            initial: initialMetadata,
            parentRelativeBytes: relativeBytes,
            coveredEntryCount: &context.coveredEntryCount
        )
        return DirectoryFrame(
            absolutePath: absolutePath,
            relativeBytes: relativeBytes,
            relativePath: relativePath,
            initialMetadata: initialMetadata,
            components: components
        )
    }

    private func visitFile(
        absolutePath: String,
        relativePath: String,
        relativeBytes: Data,
        initialMetadata: stat,
        context: inout Context
    ) throws {
        guard initialMetadata.st_size >= 0 else {
            throw CodexDeploymentManifestError.treeChanged
        }
        guard let size = UInt64(exactly: initialMetadata.st_size) else {
            throw CodexDeploymentManifestError.treeChanged
        }
        context.totalFileBytes = try CodexDeploymentManifestResourceBudget
            .addingFileSize(size, to: context.totalFileBytes)

        let file = try CodexDeploymentManifestFileHasher.hashRegularFile(
            at: absolutePath,
            relativePath: relativePath,
            initial: initialMetadata,
            afterContentRead: testingHooks.afterFileContentRead
        )
        try addEntry(
            CodexDeploymentManifestEntry(
                kind: .file,
                path: relativePath,
                pathBytes: relativeBytes,
                mode: CodexDeploymentManifestFileIO.permissionMode(initialMetadata),
                size: file.size,
                digest: file.digest
            ),
            context: &context
        )
        context.stabilityChecks.append(
            StabilityCheck(absolutePath: absolutePath, metadata: file.stableMetadata)
        )
    }

    private func validateExcludedSelfManifest(
        absolutePath: String,
        metadata: stat,
        context: inout Context
    ) throws {
        try CodexDeploymentManifestFileIO.validateSupportedEntry(metadata)
        guard CodexDeploymentManifestFileIO.fileType(metadata) == mode_t(S_IFREG) else {
            throw CodexDeploymentManifestError.unsupportedEntry
        }
        let hasValidSize = metadata.st_size >= 0
            && metadata.st_size <= CodexDeploymentManifestLimits.maximumCanonicalManifestBytes
        guard hasValidSize else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        context.stabilityChecks.append(
            StabilityCheck(absolutePath: absolutePath, metadata: metadata)
        )
    }

    private func addEntry(
        _ entry: CodexDeploymentManifestEntry,
        context: inout Context
    ) throws {
        let emitted = context.emittedEntryCount.addingReportingOverflow(1)
        let emittedIsValid = !emitted.overflow
            && emitted.partialValue <= context.coveredEntryCount
            && emitted.partialValue <= CodexDeploymentManifestLimits.maximumEntryCount
        guard emittedIsValid else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        context.emittedEntryCount = emitted.partialValue

        let fileFieldBytes = entry.kind == .file ? 8 + 32 : 0
        let recordByteCount = 8 + 1 + 4 + entry.pathBytes.count + 2 + fileFieldBytes
        let byteCount = context.canonicalByteCount.addingReportingOverflow(recordByteCount)
        let byteCountIsValid = !byteCount.overflow
            && byteCount.partialValue
            <= CodexDeploymentManifestLimits.maximumCanonicalManifestBytes
        guard byteCountIsValid else {
            throw CodexDeploymentManifestError.resourceLimit
        }
        context.canonicalByteCount = byteCount.partialValue
        context.entries.append(entry)
    }

    private func verifyStableSnapshot(_ checks: [StabilityCheck]) throws {
        for check in checks {
            let current = try CodexDeploymentManifestFileIO.stableLstat(check.absolutePath)
            try CodexDeploymentManifestFileIO.requireStable(check.metadata, current)
        }
    }

    private func joinedRelativePath(_ parent: Data, _ component: Data) -> Data {
        guard !parent.isEmpty else { return component }
        var joined = parent
        joined.append(0x2F)
        joined.append(component)
        return joined
    }

    private func joinedAbsolutePath(_ parent: String, _ component: String) -> String {
        parent == "/" ? "/\(component)" : "\(parent)/\(component)"
    }

    private func isSelfManifest(_ relativeBytes: Data) -> Bool {
        relativeBytes == Data(CodexDeploymentManifestLimits.selfManifestPath.utf8)
    }
}
