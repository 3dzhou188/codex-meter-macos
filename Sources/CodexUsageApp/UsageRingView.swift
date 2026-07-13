import AppKit
import CodexUsageCore
import SwiftUI

// The Agent lamp uses a red/yellow/green status-light language inspired by
// Agent Signal Bar: https://github.com/guan-ops/Agent-Signal-Bar
// Rendering is implemented from scratch for Codex Meter's menu bar icon.
enum StatusItemImageFactory {
    private static let usageImageSize = NSSize(width: 76, height: 22)
    private static let agentImageSize = NSSize(width: 34, height: 22)
    private static let combinedImageSize = NSSize(width: 111, height: 22)
    private static let segmentCount = 16

    static func make(
        usage: UsageSnapshot?,
        agent: AgentStatusSnapshot,
        mode: StatusDisplayMode,
        tick: Int
    ) -> NSImage {
        let imageSize = size(for: mode)
        let image = NSImage(size: imageSize, flipped: false) { _ in
            switch mode {
            case .usageAndAgent:
                drawMeter(
                    label: "5h",
                    percent: usage?.fiveHourWindow?.remainingPercent,
                    unlimited: usage?.isFiveHourLimitTemporarilyUnlimited == true,
                    originX: 0
                )
                drawMeter(label: "7d", percent: usage?.sevenDayWindow?.remainingPercent, originX: 39)
                drawAgentLamp(signal: agent.aggregate, originX: 80, tick: tick)
            case .usageOnly:
                drawMeter(
                    label: "5h",
                    percent: usage?.fiveHourWindow?.remainingPercent,
                    unlimited: usage?.isFiveHourLimitTemporarilyUnlimited == true,
                    originX: 0
                )
                drawMeter(label: "7d", percent: usage?.sevenDayWindow?.remainingPercent, originX: 39)
            case .agentOnly:
                drawAgentLamp(signal: agent.aggregate, originX: 3, tick: tick)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func size(for mode: StatusDisplayMode) -> NSSize {
        switch mode {
        case .usageAndAgent: combinedImageSize
        case .usageOnly: usageImageSize
        case .agentOnly: agentImageSize
        }
    }

    private static func drawMeter(
        label: String,
        percent: Int?,
        unlimited: Bool = false,
        originX: CGFloat
    ) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8.3, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        NSString(string: label).draw(at: NSPoint(x: originX, y: 6.6), withAttributes: labelAttributes)

        let center = NSPoint(x: originX + 25.5, y: 11)
        let activeCount = SegmentedRing.activeSegments(
            remainingPercent: unlimited ? 100 : percent,
            segmentCount: segmentCount
        )
        let activeColor = NSColor(UsageLevel(remainingPercent: unlimited ? 100 : (percent ?? 0)))

        for index in 0..<segmentCount {
            let start = 90 - CGFloat(index) * 360 / CGFloat(segmentCount)
            let end = start - 14
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: 8.5, startAngle: start, endAngle: end, clockwise: true)
            path.lineWidth = 2.6
            path.lineCapStyle = .butt
            (index < activeCount ? activeColor : NSColor.secondaryLabelColor.withAlphaComponent(0.25)).setStroke()
            path.stroke()
        }

        let number = unlimited ? "∞" : (percent.map(String.init) ?? "--")
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 6.6, weight: .bold),
            .foregroundColor: NSColor.labelColor,
        ]
        let textSize = NSString(string: number).size(withAttributes: numberAttributes)
        NSString(string: number).draw(
            at: NSPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
            withAttributes: numberAttributes
        )
    }

    private static func drawAgentLamp(signal: AgentSignal, originX: CGFloat, tick: Int) {
        for (index, color) in AgentLampColor.displayOrder.enumerated() {
            let rect = NSRect(x: originX + CGFloat(index) * 9.5, y: 7.4, width: 7.4, height: 7.4)
            let base = NSBezierPath(ovalIn: rect.insetBy(dx: -1.2, dy: -1.2))
            NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
            base.fill()

            let intensity = AgentLampIntensity.value(color: color, signal: signal, tick: tick)
            guard intensity > 0 else {
                NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: rect).fill()
                continue
            }
            NSColor(color).withAlphaComponent(0.28 + 0.72 * intensity).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

extension Color {
    init(_ level: UsageLevel) {
        self.init(nsColor: NSColor(level))
    }
}

private extension NSColor {
    convenience init(_ color: AgentLampColor) {
        switch color {
        case .red: self.init(red: 0.85, green: 0.20, blue: 0.18, alpha: 1)
        case .yellow: self.init(red: 0.94, green: 0.68, blue: 0.12, alpha: 1)
        case .green: self.init(red: 0.12, green: 0.72, blue: 0.30, alpha: 1)
        }
    }

    convenience init(_ level: UsageLevel) {
        switch level {
        case .high: self.init(red: 0.09, green: 0.53, blue: 0.23, alpha: 1)
        case .good: self.init(red: 0.45, green: 0.75, blue: 0.27, alpha: 1)
        case .medium: self.init(red: 0.89, green: 0.70, blue: 0.10, alpha: 1)
        case .low: self.init(red: 0.93, green: 0.49, blue: 0.10, alpha: 1)
        case .critical: self.init(red: 0.85, green: 0.21, blue: 0.21, alpha: 1)
        }
    }
}
