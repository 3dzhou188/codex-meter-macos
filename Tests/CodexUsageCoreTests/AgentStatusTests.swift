import Foundation
import Testing
@testable import CodexUsageCore

@Test func codexDesktopParserMapsActivityEventsAndIgnoresTokenCount() throws {
    let parser = CodexDesktopSessionParser()
    let file = URL(fileURLWithPath: "/tmp/session-abc.jsonl")

    #expect(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:00Z","type":"event_msg","payload":{"type":"token_count","input_tokens":123}}"#,
        fileURL: file
    ) == nil)

    let reasoning = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:01Z","type":"response_item","payload":{"type":"reasoning"}}"#,
        fileURL: file
    ))
    #expect(reasoning.signal == .thinking)
    #expect(reasoning.sessionID == "session-abc")

    let toolCall = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:02Z","type":"response_item","payload":{"type":"function_call","name":"shell"}}"#,
        fileURL: file
    ))
    #expect(toolCall.signal == .working)

    let toolOutput = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:03Z","type":"response_item","payload":{"type":"function_call_output"}}"#,
        fileURL: file
    ))
    #expect(toolOutput.signal == .toolDone)

    let finalAnswer = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer"}}"#,
        fileURL: file
    ))
    #expect(finalAnswer.signal == .done)

    let taskComplete = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:05Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        fileURL: file
    ))
    #expect(taskComplete.signal == .done)

    let requestInput = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:06Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input"}}"#,
        fileURL: file
    ))
    #expect(requestInput.signal == .attention)

    let failure = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:07Z","type":"event_msg","payload":{"type":"patch_apply_end","success":false}}"#,
        fileURL: file
    ))
    #expect(failure.signal == .blocked)

    let inspectedFailureData = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:07Z","type":"response_item","payload":{"type":"function_call_output","output":{"error":"example data","success":false}}}"#,
        fileURL: file
    ))
    #expect(inspectedFailureData.signal == .toolDone)

    let taskStarted = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:08Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        fileURL: file
    ))
    #expect(taskStarted.signal == .thinking)

    let agentMessage = try #require(try parser.parseLine(
        #"{"timestamp":"2026-06-18T12:00:09Z","type":"event_msg","payload":{"type":"agent_message","phase":"answer"}}"#,
        fileURL: file
    ))
    #expect(agentMessage.signal == .working)
}

@Test func codexHookAdapterNormalizesEventsAndFailureMarkers() throws {
    let adapter = CodexHookAdapter()
    let env = [
        "CODEX_SESSION_ID": "env-session",
        "CODEX_AGENT_NAME": "env-agent",
    ]

    let prompt = try adapter.activity(
        eventName: "UserPromptSubmit",
        payload: ["prompt": "hello"],
        environment: env,
        now: Date(timeIntervalSince1970: 10)
    )
    #expect(prompt.signal == .thinking)
    #expect(prompt.sessionID == "env-session")
    #expect(prompt.agent == "env-agent")

    let toolStart = try adapter.activity(
        eventName: "PreToolUse",
        payload: ["status": "completed", "input": ["error": "example data"]],
        environment: env,
        now: Date(timeIntervalSince1970: 10.5)
    )
    #expect(toolStart.signal == .working)

    let permission = try adapter.activity(
        eventName: "PermissionRequest",
        payload: ["session_id": "payload-session", "tool": "write"],
        environment: env,
        now: Date(timeIntervalSince1970: 11)
    )
    #expect(permission.signal == .permissionRequest)
    #expect(permission.sessionID == "payload-session")

    let failedStop = try adapter.activity(
        eventName: "Stop",
        payload: ["status": "failed", "session_id": "failed-session"],
        environment: [:],
        now: Date(timeIntervalSince1970: 12)
    )
    #expect(failedStop.signal == .blocked)
    #expect(failedStop.agent == "codex-cli")
}

@Test func agentStatusStorePreservesImportantStatesAndExpiresOldSessions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = directory.appendingPathComponent("agent-status.json")
    let store = AgentStatusStore(stateFileURL: file, sessionTTL: 60, completedTTL: 30)
    let base = Date(timeIntervalSince1970: 1_000)

    try store.apply(AgentActivity(sessionID: "s1", signal: .permissionRequest, updatedAt: base, agent: "codex"))
    try store.apply(AgentActivity(sessionID: "s1", signal: .working, updatedAt: base.addingTimeInterval(1), agent: "codex"))

    var snapshot = try store.readSnapshot(now: base.addingTimeInterval(2))
    #expect(snapshot.aggregate == .permissionRequest)
    #expect(snapshot.sessions.first?.signal == .permissionRequest)

    try store.apply(AgentActivity(sessionID: "s2", signal: .done, updatedAt: base.addingTimeInterval(10), agent: "codex"))
    snapshot = try store.readSnapshot(now: base.addingTimeInterval(20))
    #expect(snapshot.aggregate == .permissionRequest)
    #expect(snapshot.sessions.contains { $0.sessionID == "s2" && $0.signal == .done })

    try store.apply(AgentActivity(sessionID: "s1", signal: .idle, updatedAt: base.addingTimeInterval(21), agent: "codex"))
    snapshot = try store.readSnapshot(now: base.addingTimeInterval(39))
    #expect(snapshot.aggregate == .done)

    snapshot = try store.readSnapshot(now: base.addingTimeInterval(70))
    #expect(snapshot.aggregate == .idle)
    #expect(snapshot.sessions.isEmpty)

    try store.apply(AgentActivity(sessionID: "s3", signal: .working, updatedAt: base.addingTimeInterval(80), agent: "codex"))
    snapshot = try store.readSnapshot(now: base.addingTimeInterval(200))
    #expect(snapshot.aggregate == .idle)
    #expect(snapshot.sessions.isEmpty)

    try store.apply(AgentActivity(sessionID: "s4", signal: .blocked, updatedAt: base.addingTimeInterval(210), agent: "codex"))
    snapshot = try store.readSnapshot(now: base.addingTimeInterval(300))
    #expect(snapshot.aggregate == .idle)
    #expect(snapshot.sessions.isEmpty)
}

@Test func agentLampIntensityMatchesSignalColors() {
    #expect(AgentLampColor.displayOrder == [.red, .yellow, .green])
    #expect(AgentLampIntensity.value(color: .green, signal: .idle, tick: 0) == 1.0)
    #expect(AgentLampIntensity.value(color: .yellow, signal: .attention, tick: 0) == 1.0)
    #expect(AgentLampIntensity.value(color: .yellow, signal: .attention, tick: 1) < 1.0)
    #expect(AgentLampIntensity.value(color: .red, signal: .permissionRequest, tick: 0) == 1.0)
    #expect(AgentLampIntensity.value(color: .red, signal: .permissionRequest, tick: 1) < 0.1)
    #expect(AgentLampIntensity.value(color: .red, signal: .blocked, tick: 0) == 1.0)
    #expect(AgentLampIntensity.value(color: .red, signal: .blocked, tick: 1) == 1.0)
    #expect(AgentLampIntensity.value(color: .yellow, signal: .stale, tick: 0) == 1.0)
    #expect(AgentLampIntensity.value(color: .yellow, signal: .stale, tick: 1) == 1.0)
    #expect(AgentLampIntensity.value(color: .green, signal: .paused, tick: 0) == 0)
}

@Test func agentLampStatesMatchReadmeOverview() {
    func activeColors(for signal: AgentSignal, tick: Int = 0) -> [AgentLampColor] {
        AgentLampColor.displayOrder.filter {
            AgentLampIntensity.value(color: $0, signal: signal, tick: tick) > 0
        }
    }

    #expect(activeColors(for: .idle) == [.green])
    #expect(activeColors(for: .thinking) == [.green])
    #expect(activeColors(for: .working) == [.green])
    #expect(activeColors(for: .done) == [.green])
    #expect(activeColors(for: .attention) == [.yellow])
    #expect(activeColors(for: .stale) == [.yellow])
    #expect(activeColors(for: .permissionRequest) == [.red])
    #expect(activeColors(for: .blocked) == [.red])
    #expect(activeColors(for: .paused).isEmpty)
}

@Test func corruptedAgentStateCacheRecoversAsIdle() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("agent-status.json")
    try Data("not-json".utf8).write(to: file)

    let snapshot = try AgentStatusStore(stateFileURL: file).readSnapshot()
    #expect(snapshot.aggregate == .idle)
    #expect(snapshot.sessions.isEmpty)
}

@Test func agentStatusClearsPermissionAndBlockedAfterExplicitProgress() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("agent-status.json")
    let store = AgentStatusStore(stateFileURL: file, sessionTTL: 60, completedTTL: 30)
    let base = Date(timeIntervalSince1970: 2_000)

    try store.apply(AgentActivity(sessionID: "s1", signal: .permissionRequest, updatedAt: base, agent: "codex"))
    try store.apply(AgentActivity(sessionID: "s1", signal: .working, updatedAt: base.addingTimeInterval(1), agent: "codex"))
    #expect(try store.readSnapshot(now: base.addingTimeInterval(2)).aggregate == .permissionRequest)

    try store.apply(AgentActivity(sessionID: "s1", signal: .toolDone, updatedAt: base.addingTimeInterval(3), agent: "codex"))
    #expect(try store.readSnapshot(now: base.addingTimeInterval(4)).aggregate == .toolDone)

    try store.apply(AgentActivity(sessionID: "s2", signal: .blocked, updatedAt: base.addingTimeInterval(5), agent: "codex"))
    try store.apply(AgentActivity(sessionID: "s2", signal: .done, updatedAt: base.addingTimeInterval(6), agent: "codex"))
    let snapshot = try store.readSnapshot(now: base.addingTimeInterval(7))
    #expect(snapshot.aggregate == .toolDone)
    #expect(snapshot.sessions.first { $0.sessionID == "s2" }?.signal == .done)
}

@Test func expiredSessionDoesNotOverrideFreshActivity() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("agent-status.json")
    let store = AgentStatusStore(stateFileURL: file, sessionTTL: 60, completedTTL: 30)
    let base = Date(timeIntervalSince1970: 3_000)

    try store.apply(AgentActivity(sessionID: "old", signal: .working, updatedAt: base, agent: "codex"))
    var snapshot = try store.readSnapshot(now: base.addingTimeInterval(90))
    #expect(snapshot.aggregate == .idle)

    try store.apply(AgentActivity(sessionID: "fresh", signal: .toolDone, updatedAt: base.addingTimeInterval(91), agent: "codex"))
    snapshot = try store.readSnapshot(now: base.addingTimeInterval(92))
    #expect(snapshot.aggregate == .toolDone)
}

@Test func expiredSessionAcceptsNewerActivityForSameSession() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("agent-status.json")
    let store = AgentStatusStore(stateFileURL: file, sessionTTL: 60, completedTTL: 30)
    let base = Date(timeIntervalSince1970: 4_000)

    try store.apply(AgentActivity(sessionID: "same", signal: .working, updatedAt: base, agent: "codex"))
    var snapshot = try store.readSnapshot(now: base.addingTimeInterval(90))
    #expect(snapshot.aggregate == .idle)

    try store.apply(AgentActivity(sessionID: "same", signal: .thinking, updatedAt: base.addingTimeInterval(91), agent: "codex"))
    snapshot = try store.readSnapshot(now: base.addingTimeInterval(92))
    #expect(snapshot.aggregate == .thinking)
    #expect(snapshot.sessions.first?.signal == .thinking)
}

@Test func agentStatusStoreIgnoresDuplicateActivities() throws {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("agent-status.json")
    let store = AgentStatusStore(stateFileURL: file)
    let activity = AgentActivity(
        sessionID: "same",
        signal: .working,
        updatedAt: Date(timeIntervalSince1970: 5_000),
        agent: "codex",
        event: "tool"
    )

    try store.apply(activity)
    try store.apply(activity)

    let snapshot = try store.readSnapshot(now: Date(timeIntervalSince1970: 5_001))
    #expect(snapshot.recentEvents.count == 1)
}

@Test func desktopActivityProviderOnlyReturnsCurrentActivityWindow() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("session.jsonl")
    let contents = [
        #"{"timestamp":"1970-01-01T01:06:40Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"1970-01-01T01:23:10Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ].joined(separator: "\n")
    try Data(contents.utf8).write(to: file)

    let provider = CodexDesktopActivityProvider(
        sessionsDirectory: directory,
        activityLookback: 60
    )
    let activities = provider.recentActivities(now: Date(timeIntervalSince1970: 5_000))

    #expect(activities.count == 1)
    #expect(activities.first?.updatedAt == Date(timeIntervalSince1970: 4_990))
}
