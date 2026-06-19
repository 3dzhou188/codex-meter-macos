import Foundation

public struct AgentActivity: Equatable, Sendable {
    public let sessionID: String
    public let signal: AgentSignal
    public let updatedAt: Date
    public let agent: String
    public let event: String?

    public init(
        sessionID: String,
        signal: AgentSignal,
        updatedAt: Date,
        agent: String = "codex",
        event: String? = nil
    ) {
        self.sessionID = sessionID
        self.signal = signal
        self.updatedAt = updatedAt
        self.agent = agent
        self.event = event
    }
}

private struct AgentStatusDocument: Codable, Sendable {
    var schemaVersion: Int
    var aggregate: AgentSignal
    var updatedAt: Date
    var sessions: [String: AgentSessionRecord]
    var events: [AgentEventRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case aggregate
        case updatedAt = "updated_at"
        case sessions
        case events
    }
}

private struct AgentSessionRecord: Codable, Sendable {
    var sessionID: String
    var signal: AgentSignal
    var updatedAt: Date
    var agent: String
    var lastEvent: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case signal
        case updatedAt = "updated_at"
        case agent
        case lastEvent = "last_event"
    }
}

private struct AgentEventRecord: Codable, Sendable {
    var id: String
    var sessionID: String
    var signal: AgentSignal
    var updatedAt: Date
    var agent: String
    var event: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case signal
        case updatedAt = "updated_at"
        case agent
        case event
    }
}

public final class AgentStatusStore: @unchecked Sendable {
    public let stateFileURL: URL
    public let sessionTTL: TimeInterval
    public let completedTTL: TimeInterval
    public let eventLimit: Int

    private let lock = NSLock()
    private let fileManager: FileManager

    public init(
        stateFileURL: URL = AgentStatusStore.defaultStateFileURL(),
        sessionTTL: TimeInterval = 30 * 60,
        completedTTL: TimeInterval = 30,
        eventLimit: Int = 50,
        fileManager: FileManager = .default
    ) {
        self.stateFileURL = stateFileURL
        self.sessionTTL = sessionTTL
        self.completedTTL = completedTTL
        self.eventLimit = eventLimit
        self.fileManager = fileManager
    }

    public static func defaultStateFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["CODEX_METER_AGENT_STATE_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Codex Meter/agent-status.json")
    }

    public func readSnapshot(now: Date = Date()) throws -> AgentStatusSnapshot {
        try lock.withLock {
            guard var document = try loadDocumentIfPresent() else {
                return .idle(stateFileURL: stateFileURL)
            }
            document = pruned(document, now: now)
            return snapshot(from: document, now: now)
        }
    }

    public func apply(_ activity: AgentActivity) throws {
        try lock.withLock {
            var document = try loadDocumentIfPresent() ?? emptyDocument(now: activity.updatedAt)
            document = pruned(document, now: activity.updatedAt)

            if activity.signal == .paused {
                document.sessions.removeAll()
                document.aggregate = .paused
            } else if activity.signal == .idle {
                document.sessions.removeValue(forKey: activity.sessionID)
                document.aggregate = aggregateSignal(for: Array(document.sessions.values))
            } else {
                let incomingRecord = AgentSessionRecord(
                    sessionID: activity.sessionID,
                    signal: activity.signal,
                    updatedAt: activity.updatedAt,
                    agent: activity.agent,
                    lastEvent: activity.event
                )
                if shouldAccept(incoming: incomingRecord, existing: document.sessions[activity.sessionID]) {
                    document.sessions[activity.sessionID] = incomingRecord
                }
                document.aggregate = aggregateSignal(for: Array(document.sessions.values))
            }

            document.updatedAt = activity.updatedAt
            document.events.insert(
                AgentEventRecord(
                    id: UUID().uuidString,
                    sessionID: activity.sessionID,
                    signal: activity.signal,
                    updatedAt: activity.updatedAt,
                    agent: activity.agent,
                    event: activity.event
                ),
                at: 0
            )
            if document.events.count > eventLimit {
                document.events.removeSubrange(eventLimit..<document.events.count)
            }
            try save(document)
        }
    }

    public func clear(now: Date = Date()) throws {
        try lock.withLock {
            try save(emptyDocument(now: now))
        }
    }

    private func shouldAccept(incoming: AgentSessionRecord, existing: AgentSessionRecord?) -> Bool {
        guard let existing else { return true }
        if incoming.updatedAt < existing.updatedAt { return false }

        if existing.signal.displayState == .blocked || existing.signal.displayState == .paused {
            return incoming.signal.displayState == existing.signal.displayState
                || incoming.signal.displayState.priority > existing.signal.displayState.priority
        }

        if existing.signal.displayState == .permission {
            return incoming.signal == .toolDone
                || incoming.signal == .done
                || incoming.signal.displayState == .permission
                || incoming.signal.displayState == .blocked
                || incoming.signal.displayState == .paused
        }

        if existing.signal.displayState == .needsReview {
            return incoming.signal == .thinking
                || incoming.signal == .toolDone
                || incoming.signal == .done
                || incoming.signal.displayState.priority >= existing.signal.displayState.priority
        }

        return true
    }

    private func pruned(_ document: AgentStatusDocument, now: Date) -> AgentStatusDocument {
        var copy = document
        copy.sessions = Dictionary(uniqueKeysWithValues: document.sessions.compactMap { key, record in
            let age = now.timeIntervalSince(record.updatedAt)
            if record.signal == .done, age > completedTTL {
                return nil
            }
            if record.signal != .paused, age > sessionTTL {
                var stale = record
                stale.signal = .stale
                return (key, stale)
            }
            if record.signal == .idle {
                return nil
            }
            return (key, record)
        })
        if copy.aggregate == .paused || (copy.aggregate == .stale && copy.sessions.isEmpty) {
            return copy
        } else {
            copy.aggregate = aggregateSignal(for: Array(copy.sessions.values))
        }
        return copy
    }

    private func aggregateSignal(for sessions: [AgentSessionRecord]) -> AgentSignal {
        let nonStaleSessions = sessions.filter { $0.signal != .stale }
        if !nonStaleSessions.isEmpty {
            return nonStaleSessions
                .map(\.signal)
                .max { $0.displayState.priority < $1.displayState.priority }?
                .aggregateSignal ?? .idle
        }
        return sessions
            .map(\.signal)
            .max { $0.displayState.priority < $1.displayState.priority }?
            .aggregateSignal ?? .idle
    }

    private func snapshot(from document: AgentStatusDocument, now: Date) -> AgentStatusSnapshot {
        let sessions = document.sessions.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .map {
                AgentSessionStatus(
                    sessionID: $0.sessionID,
                    signal: $0.signal,
                    updatedAt: $0.updatedAt,
                    agent: $0.agent,
                    lastEvent: $0.lastEvent
                )
            }
        let events = document.events.map {
            AgentStatusEvent(
                id: $0.id,
                sessionID: $0.sessionID,
                signal: $0.signal,
                updatedAt: $0.updatedAt,
                agent: $0.agent,
                event: $0.event
            )
        }
        return AgentStatusSnapshot(
            aggregate: document.aggregate.aggregateSignal,
            sessions: sessions,
            recentEvents: events,
            updatedAt: document.updatedAt,
            stateFileURL: stateFileURL
        )
    }

    private func emptyDocument(now: Date) -> AgentStatusDocument {
        AgentStatusDocument(schemaVersion: 1, aggregate: .idle, updatedAt: now, sessions: [:], events: [])
    }

    private func loadDocumentIfPresent() throws -> AgentStatusDocument? {
        guard fileManager.fileExists(atPath: stateFileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: stateFileURL)
            return try Self.decoder.decode(AgentStatusDocument.self, from: data)
        } catch {
            return AgentStatusDocument(schemaVersion: 1, aggregate: .stale, updatedAt: Date(), sessions: [:], events: [])
        }
    }

    private func save(_ document: AgentStatusDocument) throws {
        try fileManager.createDirectory(
            at: stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(document)
        try data.write(to: stateFileURL, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            let value = try container.decode(String.self)
            if let date = iso8601Date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601String(from: date))
        }
        return encoder
    }()
}

private func iso8601Date(from value: String) -> Date? {
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? plain.date(from: value)
}

private func iso8601String(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}
