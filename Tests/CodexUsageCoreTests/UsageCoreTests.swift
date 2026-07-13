import Foundation
import Testing
@testable import CodexUsageCore

@Test func executableDiscoverySupportsRenamedChatGPTApp() {
    #expect(CodexAppServerClient.codexExecutableCandidates.first ==
        "/Applications/ChatGPT.app/Contents/Resources/codex")
    #expect(CodexAppServerClient.codexExecutableCandidates.contains(
        "/Applications/Codex.app/Contents/Resources/codex"))
}

@Test func usageSourceOnlySupportsRealtimeAppServer() {
    #expect(UsageSource.allCases == [.appServer])
}

@Test func usageWindowClampsRemainingPercent() {
    #expect(UsageWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil).remainingPercent == 93)
    #expect(UsageWindow(usedPercent: 140, windowMinutes: 300, resetsAt: nil).remainingPercent == 0)
    #expect(UsageWindow(usedPercent: -5, windowMinutes: 300, resetsAt: nil).remainingPercent == 100)
}

@Test func appServerParserPrefersCodexBucket() throws {
    let input = """
    {"rateLimits":{"limitId":"legacy","primary":{"usedPercent":50,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"pro","primary":{"usedPercent":6,"windowDurationMins":300,"resetsAt":1781089333},"secondary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":1781146054}}}}
    """

    let snapshot = try AppServerUsageParser.parseResult(Data(input.utf8), receivedAt: Date(timeIntervalSince1970: 1_781_080_000))
    #expect(snapshot.primary?.remainingPercent == 94)
    #expect(snapshot.secondary?.remainingPercent == 79)
    #expect(snapshot.planType == "pro")
    #expect(snapshot.source == .appServer)
}

@Test func usageSnapshotIdentifiesWindowsByDuration() throws {
    let input = """
    {"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":6,"windowDurationMins":300,"resetsAt":1781089333},"secondary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":1781146054}}}}
    """

    let snapshot = try AppServerUsageParser.parseResult(Data(input.utf8), receivedAt: Date(timeIntervalSince1970: 1_781_080_000))
    #expect(snapshot.fiveHourWindow?.remainingPercent == 94)
    #expect(snapshot.sevenDayWindow?.remainingPercent == 79)
    #expect(!snapshot.isFiveHourLimitTemporarilyUnlimited)
}

@Test func weeklyOnlyCodexLimitDoesNotPopulateFiveHourWindow() throws {
    let input = """
    {"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":21,"windowDurationMins":10080,"resetsAt":1781146054}}}}
    """

    let snapshot = try AppServerUsageParser.parseResult(Data(input.utf8), receivedAt: Date(timeIntervalSince1970: 1_781_080_000))
    #expect(snapshot.fiveHourWindow == nil)
    #expect(snapshot.sevenDayWindow?.remainingPercent == 79)
    #expect(snapshot.isFiveHourLimitTemporarilyUnlimited)
}

@Test func realtimeSnapshotStalenessUsesFifteenMinuteThreshold() {
    let snapshot = UsageSnapshot(
        primary: UsageWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil),
        secondary: nil,
        planType: "plus",
        source: .appServer,
        updatedAt: Date(timeIntervalSince1970: 200)
    )

    #expect(UsageMerger.isStale(snapshot, now: Date(timeIntervalSince1970: 1_101)))
    #expect(!UsageMerger.isStale(snapshot, now: Date(timeIntervalSince1970: 1_099)))
}

@Test func sparseAppServerUpdatePreservesMissingFields() {
    let original = UsageSnapshot(
        primary: UsageWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil),
        secondary: UsageWindow(usedPercent: 60, windowMinutes: 10_080, resetsAt: nil),
        planType: "plus",
        source: .appServer,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let sparse = UsageSnapshot(
        primary: UsageWindow(usedPercent: 11, windowMinutes: 300, resetsAt: nil),
        secondary: nil,
        planType: nil,
        source: .appServer,
        updatedAt: Date(timeIntervalSince1970: 200)
    )

    let merged = UsageMerger.mergeSparse(base: original, update: sparse)
    #expect(merged.primary?.usedPercent == 11)
    #expect(merged.secondary?.usedPercent == 60)
    #expect(merged.planType == "plus")
    #expect(merged.updatedAt == sparse.updatedAt)
}

@Test func notificationStateEmitsEachThresholdOncePerReset() {
    var state = NotificationThresholdState()
    let reset = Date(timeIntervalSince1970: 2_000)

    #expect(state.crossedThresholds(window: .primary, remaining: 19, resetAt: reset) == [20])
    #expect(state.crossedThresholds(window: .primary, remaining: 18, resetAt: reset).isEmpty)
    #expect(state.crossedThresholds(window: .primary, remaining: 9, resetAt: reset) == [10])
    #expect(state.crossedThresholds(window: .primary, remaining: 8, resetAt: Date(timeIntervalSince1970: 3_000)) == [20, 10])
}

@Test func rpcEnvelopeExtractsMatchingResultAndIgnoresNotifications() throws {
    let notification = Data(#"{"method":"account/rateLimits/updated","params":{}}"#.utf8)
    let response = Data(#"{"id":42,"result":{"rateLimits":{"primary":{"usedPercent":8}}}}"#.utf8)

    #expect(try RPCEnvelope.parse(notification).response == nil)
    let parsed = try #require(RPCEnvelope.parse(response).response)
    #expect(parsed.id == 42)
    let result = try #require(parsed.result)
    #expect(String(decoding: result, as: UTF8.self).contains("rateLimits"))
}

@Test func rpcEnvelopeExtractsErrorResponses() throws {
    let input = Data(#"{"id":9,"error":{"code":-32603,"message":"not logged in"}}"#.utf8)
    let parsed = try #require(RPCEnvelope.parse(input).response)
    #expect(parsed.id == 9)
    #expect(parsed.result == nil)
    #expect(parsed.errorMessage == "not logged in")
}

@Test func usageLevelUsesRequestedColorBoundaries() {
    #expect(UsageLevel(remainingPercent: 100) == .high)
    #expect(UsageLevel(remainingPercent: 75) == .high)
    #expect(UsageLevel(remainingPercent: 74) == .good)
    #expect(UsageLevel(remainingPercent: 50) == .good)
    #expect(UsageLevel(remainingPercent: 49) == .medium)
    #expect(UsageLevel(remainingPercent: 30) == .medium)
    #expect(UsageLevel(remainingPercent: 29) == .low)
    #expect(UsageLevel(remainingPercent: 10) == .low)
    #expect(UsageLevel(remainingPercent: 9) == .critical)
    #expect(UsageLevel(remainingPercent: -1) == .critical)
}

@Test func segmentedRingRoundsUpVisibleProgress() {
    #expect(SegmentedRing.activeSegments(remainingPercent: nil, segmentCount: 16) == 0)
    #expect(SegmentedRing.activeSegments(remainingPercent: 0, segmentCount: 16) == 0)
    #expect(SegmentedRing.activeSegments(remainingPercent: 1, segmentCount: 16) == 1)
    #expect(SegmentedRing.activeSegments(remainingPercent: 50, segmentCount: 16) == 8)
    #expect(SegmentedRing.activeSegments(remainingPercent: 84, segmentCount: 16) == 14)
    #expect(SegmentedRing.activeSegments(remainingPercent: 100, segmentCount: 16) == 16)
}
