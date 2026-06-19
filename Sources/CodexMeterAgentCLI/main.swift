import CodexUsageCore
import Foundation

@main
struct CodexMeterAgentCLI {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("codex-meter-agent: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "status"
        if !arguments.isEmpty { arguments.removeFirst() }

        let store = AgentStatusStore()
        switch command {
        case "status":
            let snapshot = try store.readSnapshot()
            printSnapshot(snapshot, asJSON: arguments.contains("--json"))
        case "reset", "clear":
            try store.clear()
            if arguments.contains("--json") {
                print(#"{"ok":true,"aggregate":"idle"}"#)
            } else {
                print("idle")
            }
        case "codex-hook", "hook":
            let eventName = arguments.first
            let payload = try readJSONPayload()
            let activity = try CodexHookAdapter().activity(eventName: eventName, payload: payload)
            try store.apply(activity)
            printActivity(activity, asJSON: arguments.contains("--json"))
        default:
            guard let signal = AgentSignal.normalized(command) else {
                throw CLIError.unknownCommand(command)
            }
            let parsed = parseOptions(arguments)
            let activity = AgentActivity(
                sessionID: parsed["session"] ?? parsed["session-id"] ?? parsed["session_id"] ?? "manual",
                signal: signal,
                updatedAt: Date(),
                agent: parsed["agent"] ?? "codex-cli",
                event: parsed["event"] ?? command
            )
            try store.apply(activity)
            printActivity(activity, asJSON: arguments.contains("--json"))
        }
    }

    private static func readJSONPayload() throws -> [String: Any] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw CLIError.invalidJSON
        }
        return dictionary
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    result[key] = arguments[index + 1]
                    index += 2
                } else {
                    result[key] = "true"
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return result
    }

    private static func printSnapshot(_ snapshot: AgentStatusSnapshot, asJSON: Bool) {
        if asJSON {
            let sessions = snapshot.sessions.map {
                #"{"session_id":"\#(escape($0.sessionID))","agent":"\#(escape($0.agent))","signal":"\#($0.signal.rawValue)","updated_at":\#($0.updatedAt.timeIntervalSince1970)}"#
            }.joined(separator: ",")
            print(#"{"aggregate":"\#(snapshot.aggregate.rawValue)","updated_at":\#(snapshot.updatedAt?.timeIntervalSince1970 ?? 0),"sessions":[\#(sessions)]}"#)
        } else {
            print(snapshot.aggregate.rawValue)
        }
    }

    private static func printActivity(_ activity: AgentActivity, asJSON: Bool) {
        if asJSON {
            print(#"{"ok":true,"session_id":"\#(escape(activity.sessionID))","agent":"\#(escape(activity.agent))","signal":"\#(activity.signal.rawValue)"}"#)
        } else {
            print(activity.signal.rawValue)
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\"#, with: #"\\"#)
            .replacingOccurrences(of: #"""#, with: #"\""#)
    }
}

private enum CLIError: LocalizedError {
    case unknownCommand(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "未知命令或信号：\(command)"
        case .invalidJSON:
            return "stdin 不是 JSON object"
        }
    }
}
