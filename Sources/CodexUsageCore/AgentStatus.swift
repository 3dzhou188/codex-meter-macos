import Foundation

// Codex Agent status vocabulary and display priority are inspired by
// Agent Signal Bar: https://github.com/guan-ops/Agent-Signal-Bar
// This is a Codex-only reimplementation for Codex Meter; no Agent Signal Bar
// source files or assets are bundled.
public enum AgentDisplayState: String, Codable, CaseIterable, Sendable {
    case ready
    case active
    case completed
    case needsReview = "needs_review"
    case permission
    case blocked
    case stale
    case paused

    public var priority: Int {
        switch self {
        case .paused: 100
        case .blocked: 90
        case .permission: 80
        case .needsReview: 70
        case .stale: 60
        case .active: 50
        case .completed: 40
        case .ready: 0
        }
    }

    public var actionText: String {
        switch self {
        case .ready, .active, .completed: "不用处理"
        case .needsReview: "有空看一眼"
        case .permission, .blocked: "马上处理"
        case .stale: "确认状态"
        case .paused: "监控已暂停"
        }
    }
}

public enum AgentSignal: String, Codable, CaseIterable, Sendable {
    case idle
    case thinking
    case working
    case toolDone = "tool_done"
    case done
    case attention
    case permissionRequest = "permission_request"
    case blocked
    case stale
    case paused

    public static func normalized(_ rawValue: String) -> AgentSignal? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "idle", "ready", "session_start", "sessionstart":
            return .idle
        case "thinking", "reasoning":
            return .thinking
        case "working", "active", "pre_tool_use", "pretooluse", "tool_use", "tooluse":
            return .working
        case "tool_done", "post_tool_use", "posttooluse":
            return .toolDone
        case "done", "completed", "complete", "stop", "task_complete", "final_answer":
            return .done
        case "attention", "notification", "needs_review", "review":
            return .attention
        case "permission", "permission_request", "permissionrequest":
            return .permissionRequest
        case "blocked", "failure", "failed", "error", "exception", "max_tokens":
            return .blocked
        case "stale":
            return .stale
        case "paused", "pause", "off":
            return .paused
        default:
            return nil
        }
    }

    public var displayState: AgentDisplayState {
        switch self {
        case .idle:
            return .ready
        case .thinking, .working, .toolDone:
            return .active
        case .done:
            return .completed
        case .attention:
            return .needsReview
        case .permissionRequest:
            return .permission
        case .blocked:
            return .blocked
        case .stale:
            return .stale
        case .paused:
            return .paused
        }
    }

    public var aggregateSignal: AgentSignal {
        switch displayState {
        case .ready: .idle
        case .active: self
        case .completed: .done
        case .needsReview: .attention
        case .permission: .permissionRequest
        case .blocked: .blocked
        case .stale: .stale
        case .paused: .paused
        }
    }

    public var displayName: String {
        switch self {
        case .idle: "空闲"
        case .thinking: "思考中"
        case .working: "工作中"
        case .toolDone: "步骤完成"
        case .done: "已完成"
        case .attention: "需要查看"
        case .permissionRequest: "等待授权"
        case .blocked: "阻塞/失败"
        case .stale: "状态不可用"
        case .paused: "已暂停"
        }
    }

    public var summary: String {
        switch self {
        case .idle: "Codex 当前空闲。"
        case .thinking: "Codex 已收到任务，正在思考。"
        case .working: "Codex 正在读写文件、运行工具或测试。"
        case .toolDone: "一个工具步骤已完成，工作流仍可能继续。"
        case .done: "Codex 任务已完成。"
        case .attention: "Codex 需要你查看或继续。"
        case .permissionRequest: "Codex 正在等待授权。"
        case .blocked: "Codex 遇到失败、阻塞或无法继续。"
        case .stale: "Agent 状态数据暂时无法读取。"
        case .paused: "Codex Agent 状态监控已暂停。"
        }
    }
}

public struct AgentSessionStatus: Identifiable, Equatable, Sendable {
    public var id: String { sessionID }
    public let sessionID: String
    public let signal: AgentSignal
    public let updatedAt: Date
    public let agent: String
    public let lastEvent: String?

    public init(
        sessionID: String,
        signal: AgentSignal,
        updatedAt: Date,
        agent: String = "codex",
        lastEvent: String? = nil
    ) {
        self.sessionID = sessionID
        self.signal = signal
        self.updatedAt = updatedAt
        self.agent = agent
        self.lastEvent = lastEvent
    }
}

public struct AgentStatusEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let signal: AgentSignal
    public let updatedAt: Date
    public let agent: String
    public let event: String?

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        signal: AgentSignal,
        updatedAt: Date,
        agent: String = "codex",
        event: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.signal = signal
        self.updatedAt = updatedAt
        self.agent = agent
        self.event = event
    }
}

public struct AgentStatusSnapshot: Equatable, Sendable {
    public let aggregate: AgentSignal
    public let sessions: [AgentSessionStatus]
    public let recentEvents: [AgentStatusEvent]
    public let updatedAt: Date?
    public let stateFileURL: URL

    public init(
        aggregate: AgentSignal,
        sessions: [AgentSessionStatus],
        recentEvents: [AgentStatusEvent] = [],
        updatedAt: Date?,
        stateFileURL: URL
    ) {
        self.aggregate = aggregate
        self.sessions = sessions
        self.recentEvents = recentEvents
        self.updatedAt = updatedAt
        self.stateFileURL = stateFileURL
    }

    public static func idle(stateFileURL: URL) -> AgentStatusSnapshot {
        AgentStatusSnapshot(aggregate: .idle, sessions: [], updatedAt: nil, stateFileURL: stateFileURL)
    }
}

public enum AgentLampColor: Sendable, CaseIterable, Equatable {
    case red
    case yellow
    case green

    public static let displayOrder: [AgentLampColor] = [.red, .yellow, .green]
}

public enum AgentLampIntensity {
    public static func value(color: AgentLampColor, signal: AgentSignal, tick: Int) -> Double {
        let slowBlink = tick % 2 == 0 ? 1.0 : 0.28
        let fastBlink = tick % 2 == 0 ? 1.0 : 0.08

        switch signal {
        case .idle, .done:
            return color == .green ? 1.0 : 0
        case .thinking:
            return color == .green ? fastBlink : 0
        case .working, .toolDone:
            return color == .green ? slowBlink : 0
        case .attention:
            return color == .yellow ? slowBlink : 0
        case .stale:
            return color == .yellow ? 1.0 : 0
        case .permissionRequest:
            return color == .red ? fastBlink : 0
        case .blocked:
            return color == .red ? 1.0 : 0
        case .paused:
            return 0
        }
    }
}
