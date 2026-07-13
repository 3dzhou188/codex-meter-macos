import Foundation

public enum UsageSource: String, Codable, CaseIterable, Sendable {
    case appServer
}

public enum UsageLevel: Equatable, Sendable {
    case high
    case good
    case medium
    case low
    case critical

    public init(remainingPercent: Int) {
        switch remainingPercent {
        case 75...: self = .high
        case 50..<75: self = .good
        case 30..<50: self = .medium
        case 10..<30: self = .low
        default: self = .critical
        }
    }
}

public enum SegmentedRing {
    public static func activeSegments(remainingPercent: Int?, segmentCount: Int) -> Int {
        guard let remainingPercent, segmentCount > 0 else { return 0 }
        let clamped = min(100, max(0, remainingPercent))
        guard clamped > 0 else { return 0 }
        return Int(ceil(Double(clamped) / 100 * Double(segmentCount)))
    }
}

public struct UsageWindow: Equatable, Sendable {
    public let usedPercent: Int
    public let windowMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Int, windowMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int {
        min(100, max(0, 100 - usedPercent))
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let planType: String?
    public let source: UsageSource
    public let updatedAt: Date

    public init(
        primary: UsageWindow?,
        secondary: UsageWindow?,
        planType: String?,
        source: UsageSource,
        updatedAt: Date
    ) {
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.source = source
        self.updatedAt = updatedAt
    }

    public var hasUsage: Bool { primary != nil || secondary != nil }

    public var fiveHourWindow: UsageWindow? {
        window(exactMinutes: 300) ?? fallbackPrimaryWindow(excludingMinutes: 10_080)
    }

    public var sevenDayWindow: UsageWindow? {
        window(exactMinutes: 10_080) ?? fallbackSecondaryWindow()
    }

    public var isFiveHourLimitTemporarilyUnlimited: Bool {
        fiveHourWindow == nil && sevenDayWindow != nil
    }

    private var windows: [UsageWindow] {
        [primary, secondary].compactMap { $0 }
    }

    private func window(exactMinutes minutes: Int) -> UsageWindow? {
        windows.first { $0.windowMinutes == minutes }
    }

    private func fallbackPrimaryWindow(excludingMinutes minutes: Int) -> UsageWindow? {
        guard let primary, primary.windowMinutes != minutes else { return nil }
        return primary.windowMinutes == nil ? primary : nil
    }

    private func fallbackSecondaryWindow() -> UsageWindow? {
        guard let secondary, secondary.windowMinutes == nil else { return nil }
        return secondary
    }
}

public enum UsageMerger {
    public static func mergeSparse(base: UsageSnapshot, update: UsageSnapshot) -> UsageSnapshot {
        UsageSnapshot(
            primary: update.primary ?? base.primary,
            secondary: update.secondary ?? base.secondary,
            planType: update.planType ?? base.planType,
            source: update.source,
            updatedAt: update.updatedAt
        )
    }

    public static func isStale(_ snapshot: UsageSnapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.updatedAt) > 15 * 60
    }
}
