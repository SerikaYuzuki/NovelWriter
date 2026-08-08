@testable import FUMINIWAExperimental
import NovelAI
import Testing

@MainActor
@Test("provider route変更後は旧新どちらのproviderも開始しない")
func changedProviderRoutePreventsProviderStart() async throws {
    let harness = try makeHarness()
    let replacementProbe = ProviderProbe()
    let replacementRoute = try makeRoute(
        leaseID: replacementRouteLeaseUUID,
        probe: replacementProbe,
        disclosureRevision: "route-v2"
    )
    harness.operation.preparePreview()

    harness.operation.updateRoute(replacementRoute)
    harness.operation.confirmAndSend()

    #expect(harness.operation.phase == .invalidated)
    #expect(harness.operation.failure == .stale(.providerChanged))
    #expect(await harness.providerProbe.recordedRequests().isEmpty)
    #expect(await replacementProbe.recordedRequests().isEmpty)
}

@MainActor
@Test("実行中に次回providerを変えても現在requestの表示先を取り違えない")
func routeChangeWhileRunningKeepsActiveProviderDisclosure() async throws {
    let harness = try makeHarness()
    let replacementProbe = ProviderProbe()
    let replacementRoute = makeReplacementProviderRoute(probe: replacementProbe)
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.providerProbe.waitUntilStarted()

    harness.operation.updateRoute(replacementRoute)

    #expect(harness.operation.phase == .running)
    #expect(harness.operation.providerDescriptor == testProviderDescriptor)
    #expect(harness.operation.providerDisclosure.revision == "route-v1")
    #expect(await replacementProbe.recordedRequests().isEmpty)

    harness.operation.cancel()
    await harness.operation.waitForCurrentRequest()

    #expect(harness.operation.phase == .cancelled)
    #expect(harness.operation.providerDescriptor == testProviderDescriptor)
    #expect(harness.operation.providerDisclosure.revision == "route-v1")
}

@MainActor
@Test("route変更後に旧providerが失敗しても失敗表示の送信先を保持する")
func routeChangeBeforeFailureKeepsTerminalProviderDisclosure() async throws {
    let harness = try makeHarness()
    let replacementProbe = ProviderProbe()
    harness.operation.preparePreview()
    harness.operation.confirmAndSend()
    await harness.providerProbe.waitUntilStarted()
    harness.operation.updateRoute(makeReplacementProviderRoute(probe: replacementProbe))

    await harness.providerProbe.fail(.providerUnavailable)
    await harness.operation.waitForCurrentRequest()

    #expect(harness.operation.phase == .failed)
    #expect(harness.operation.providerDescriptor == testProviderDescriptor)
    #expect(harness.operation.providerDisclosure.revision == "route-v1")
    #expect(await replacementProbe.recordedRequests().isEmpty)
}
