import Foundation

// Codex Desktop session monitoring follows the same local-first idea as
// Agent Signal Bar (https://github.com/guan-ops/Agent-Signal-Bar), but is
// reimplemented here for Codex Meter and limited to Codex activity events.
public final class CodexDesktopSessionParser: Sendable {
    public init() {}

    public func parseLine(_ line: String, fileURL: URL, now: Date = Date()) throws -> AgentActivity? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let raw = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        guard let object = raw as? [String: Any] else { return nil }

        let payload = object["payload"] as? [String: Any] ?? object
        let topLevelType = value(for: ["type"], in: object)
        let payloadType = value(for: ["type", "event"], in: payload)
        if payloadType == "token_count" {
            return nil
        }

        let timestamp = date(from: object["timestamp"] ?? object["time"] ?? payload["timestamp"]) ?? now
        let sessionID = stringValue(
            firstValue(
                for: ["session_id", "sessionId", "thread_id", "threadId", "conversation_id", "conversationId"],
                in: [payload, object]
            )
        ) ?? fileURL.deletingPathExtension().lastPathComponent
        let eventName = eventDescription(object: object, payload: payload)
        let signal = signal(from: object, payload: payload, topLevelType: topLevelType, payloadType: payloadType)
        guard let signal else { return nil }
        return AgentActivity(
            sessionID: sessionID,
            signal: signal,
            updatedAt: timestamp,
            agent: "codex-desktop",
            event: eventName
        )
    }

    private func signal(
        from object: [String: Any],
        payload: [String: Any],
        topLevelType: String?,
        payloadType: String?
    ) -> AgentSignal? {
        if containsFailureMarker(object) || containsFailureMarker(payload) {
            return .blocked
        }

        if topLevelType == "event_msg" {
            switch payloadType {
            case "task_complete", "final_answer", "turn_aborted", "stop":
                return .done
            case "user_message", "task_started", "turn_started":
                return .thinking
            case "agent_message":
                return value(for: ["phase", "status"], in: payload) == "final_answer" ? .done : .working
            case "mcp_tool_call_end", "patch_apply_end":
                return .toolDone
            default:
                return nil
            }
        }

        if topLevelType == "response_item" {
            switch payloadType {
            case "reasoning":
                return .thinking
            case "function_call", "custom_tool_call", "tool_search_call":
                if value(for: ["name", "tool_name", "tool"], in: payload) == "request_user_input" {
                    return .attention
                }
                return .working
            case "function_call_output", "custom_tool_call_output", "tool_search_output":
                return .toolDone
            case "message":
                if value(for: ["role"], in: payload) == "user" {
                    return nil
                }
                if value(for: ["phase", "status"], in: payload) == "final_answer" {
                    return .done
                }
                return .working
            default:
                return nil
            }
        }

        if let normalized = AgentSignal.normalized(payloadType ?? topLevelType ?? "") {
            return normalized
        }
        if let event = value(for: ["event", "name"], in: payload), let normalized = AgentSignal.normalized(event) {
            return normalized
        }
        return nil
    }

    private func eventDescription(object: [String: Any], payload: [String: Any]) -> String? {
        if let topLevelType = value(for: ["type"], in: object),
           let payloadType = value(for: ["type"], in: payload) {
            if topLevelType == "response_item",
               let toolName = value(for: ["name", "tool_name", "tool"], in: payload) {
                return "\(payloadType): \(toolName)"
            }
            return payloadType
        }
        return value(for: ["event", "name"], in: object)
    }
}

public struct CodexDesktopActivityProvider: Sendable {
    public let sessionsDirectory: URL
    public let maxFiles: Int
    public let tailBytes: Int
    public let parser: CodexDesktopSessionParser

    public init(
        sessionsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions"),
        maxFiles: Int = 20,
        tailBytes: Int = 128 * 1024,
        parser: CodexDesktopSessionParser = CodexDesktopSessionParser()
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.maxFiles = maxFiles
        self.tailBytes = tailBytes
        self.parser = parser
    }

    public func recentActivities(now: Date = Date()) -> [AgentActivity] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxFiles)
            .flatMap { readActivities(fileURL: $0.url, now: now) }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    private func readActivities(fileURL: URL, now: Date) -> [AgentActivity] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > UInt64(tailBytes) {
            try? handle.seek(toOffset: size - UInt64(tailBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { try? parser.parseLine(String($0), fileURL: fileURL, now: now) }
    }
}

public struct CodexHookAdapter: Sendable {
    public init() {}

    public func activity(
        eventName: String?,
        payload: [String: Any],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) throws -> AgentActivity {
        let signal = chooseSignal(eventName: eventName, payload: payload)
        return AgentActivity(
            sessionID: sessionID(payload: payload, environment: environment),
            signal: signal,
            updatedAt: date(from: payload["timestamp"] ?? payload["time"]) ?? now,
            agent: agentName(payload: payload, environment: environment),
            event: eventName ?? stringValue(payload["event"]) ?? stringValue(payload["hook_event_name"])
        )
    }

    public func chooseSignal(eventName: String?, payload: [String: Any]) -> AgentSignal {
        if containsFailureMarker(payload) {
            return .blocked
        }
        if let explicit = firstValue(for: ["signal", "status", "state"], in: [payload]),
           let normalized = AgentSignal.normalized(String(describing: explicit)) {
            return normalized
        }
        if let eventName, let normalized = AgentSignal.normalized(eventName) {
            return normalized
        }
        switch normalizeEventName(eventName ?? stringValue(payload["event"]) ?? stringValue(payload["hook_event_name"]) ?? "") {
        case "sessionstart", "session_start":
            return .idle
        case "userpromptsubmit", "user_prompt_submit":
            return .thinking
        case "pretooluse", "pre_tool_use":
            return .working
        case "posttooluse", "post_tool_use":
            return .toolDone
        case "permissionrequest", "permission_request":
            return .permissionRequest
        case "stop":
            return .done
        default:
            return .attention
        }
    }

    public func sessionID(payload: [String: Any], environment: [String: String]) -> String {
        stringValue(firstValue(
            for: ["session_id", "sessionId", "thread_id", "threadId", "conversation_id", "conversationId"],
            in: [payload]
        )) ?? environment["CODEX_SESSION_ID"] ?? environment["SESSION_ID"] ?? "codex-cli"
    }

    public func agentName(payload: [String: Any], environment: [String: String]) -> String {
        stringValue(firstValue(for: ["agent", "agent_name", "agentName"], in: [payload]))
            ?? environment["CODEX_AGENT_NAME"]
            ?? "codex-cli"
    }
}

private func normalizeEventName(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
        .lowercased()
}

private func value(for keys: [String], in dictionary: [String: Any]) -> String? {
    stringValue(firstValue(for: keys, in: [dictionary]))?.lowercased()
}

private func firstValue(for keys: [String], in dictionaries: [[String: Any]]) -> Any? {
    for dictionary in dictionaries {
        for key in keys {
            if let value = dictionary[key] {
                return value
            }
        }
    }
    return nil
}

private func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String where !value.isEmpty:
        return value
    case let value as NSNumber:
        return value.stringValue
    default:
        return nil
    }
}

private func date(from value: Any?) -> Date? {
    if let timestamp = value as? Double {
        return Date(timeIntervalSince1970: timestamp)
    }
    if let timestamp = value as? Int {
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
    guard let string = value as? String else { return nil }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? plain.date(from: string)
}

private func containsFailureMarker(_ dictionary: [String: Any]) -> Bool {
    for (key, value) in dictionary {
        let normalizedKey = normalizeEventName(key)
        if ["error", "failure", "exception"].contains(normalizedKey) {
            if let bool = value as? Bool {
                if bool { return true }
            } else if stringValue(value) != nil || value is [String: Any] || value is [Any] {
                return true
            }
        }
        if ["status", "state", "result"].contains(normalizedKey),
           let text = stringValue(value)?.lowercased(),
           ["failed", "failure", "error", "blocked"].contains(text) {
            return true
        }
        if normalizedKey == "success", let bool = value as? Bool, !bool {
            return true
        }
        if ["exit_status", "exitstatus", "exit_code", "exitcode"].contains(normalizedKey) {
            if let number = value as? NSNumber, number.intValue != 0 {
                return true
            }
            if let text = stringValue(value), text != "0" {
                return true
            }
        }
        if let nested = value as? [String: Any], containsFailureMarker(nested) {
            return true
        }
    }
    return false
}
