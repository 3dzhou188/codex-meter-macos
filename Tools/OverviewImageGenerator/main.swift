import AppKit
import Foundation

private let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs/codex-meter-overview.png")
private let canvasSize = NSSize(width: 1662, height: 946)
private let segmentCount = 16

private enum UsageLevel {
    case high
    case good
    case medium
    case low
    case critical

    init(remainingPercent: Int) {
        switch remainingPercent {
        case 75...: self = .high
        case 50..<75: self = .good
        case 30..<50: self = .medium
        case 10..<30: self = .low
        default: self = .critical
        }
    }
}

private enum AgentColor: CaseIterable {
    case red
    case yellow
    case green
}

private enum AgentState {
    case ready
    case thinking
    case working
    case done
    case attention
    case permission
    case blocked
    case stale
    case paused

    var active: AgentColor? {
        switch self {
        case .ready, .thinking, .working, .done: .green
        case .attention, .stale: .yellow
        case .permission, .blocked: .red
        case .paused: nil
        }
    }

    var pulse: Bool {
        switch self {
        case .thinking, .working, .attention, .permission: true
        case .ready, .done, .blocked, .stale, .paused: false
        }
    }
}

private extension NSColor {
    static let ink = NSColor(red: 0.02, green: 0.06, blue: 0.15, alpha: 1)
    static let mutedInk = NSColor(red: 0.31, green: 0.36, blue: 0.44, alpha: 1)
    static let panelStroke = NSColor(red: 0.88, green: 0.82, blue: 0.72, alpha: 1)
    static let panelFill = NSColor(red: 1.0, green: 0.995, blue: 0.975, alpha: 1)
    static let chromeFill = NSColor(red: 0.955, green: 0.958, blue: 0.965, alpha: 1)
    static let dormantSegment = NSColor.secondaryLabelColor.withAlphaComponent(0.25)

    convenience init(_ level: UsageLevel) {
        switch level {
        case .high: self.init(red: 0.09, green: 0.53, blue: 0.23, alpha: 1)
        case .good: self.init(red: 0.45, green: 0.75, blue: 0.27, alpha: 1)
        case .medium: self.init(red: 0.89, green: 0.70, blue: 0.10, alpha: 1)
        case .low: self.init(red: 0.93, green: 0.49, blue: 0.10, alpha: 1)
        case .critical: self.init(red: 0.85, green: 0.21, blue: 0.21, alpha: 1)
        }
    }

    convenience init(_ agentColor: AgentColor) {
        switch agentColor {
        case .red: self.init(red: 0.85, green: 0.20, blue: 0.18, alpha: 1)
        case .yellow: self.init(red: 0.94, green: 0.68, blue: 0.12, alpha: 1)
        case .green: self.init(red: 0.12, green: 0.72, blue: 0.30, alpha: 1)
        }
    }
}

private func paragraph(_ alignment: NSTextAlignment = .left) -> NSMutableParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = .byWordWrapping
    return style
}

private func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor = .ink,
    alignment: NSTextAlignment = .left
) {
    NSString(string: text).draw(
        in: rect,
        withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph(alignment),
        ]
    )
}

private func drawRoundedPanel(_ rect: NSRect, radius: CGFloat = 28) {
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.set()
    NSColor.panelFill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSColor.panelStroke.withAlphaComponent(0.70).setStroke()
    let stroke = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    stroke.lineWidth = 1.2
    stroke.stroke()
}

private func activeSegments(remainingPercent: Int?) -> Int {
    guard let remainingPercent else { return 0 }
    let clamped = min(100, max(0, remainingPercent))
    guard clamped > 0 else { return 0 }
    return Int(ceil(Double(clamped) / 100 * Double(segmentCount)))
}

private func drawUsageRing(
    center: NSPoint,
    radius: CGFloat,
    percent: Int?,
    lineWidth: CGFloat,
    label: String,
    unlimited: Bool = false,
    numberFontSize: CGFloat = 48,
    labelFontSize: CGFloat = 24
) {
    let displayPercent = unlimited ? 100 : percent
    let activeCount = activeSegments(remainingPercent: displayPercent)
    let activeColor = NSColor(UsageLevel(remainingPercent: unlimited ? 100 : (percent ?? 0)))

    for index in 0..<segmentCount {
        let start = 90 - CGFloat(index) * 360 / CGFloat(segmentCount)
        let end = start - 14
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        path.lineWidth = lineWidth
        path.lineCapStyle = .butt
        (index < activeCount ? activeColor : NSColor.dormantSegment).setStroke()
        path.stroke()
    }

    let number = unlimited ? "∞" : (percent.map(String.init) ?? "--")
    drawText(
        number,
        in: NSRect(x: center.x - 72, y: center.y - 17, width: 144, height: 62),
        font: .monospacedDigitSystemFont(ofSize: numberFontSize, weight: .bold),
        color: activeColor,
        alignment: .center
    )
    drawText(
        label,
        in: NSRect(x: center.x - 92, y: center.y - 52, width: 184, height: 34),
        font: .systemFont(ofSize: labelFontSize, weight: .semibold),
        color: .mutedInk,
        alignment: .center
    )
}

private func makeStatusItemImage() -> NSImage {
    let size = NSSize(width: 111, height: 22)
    let image = NSImage(size: size, flipped: false) { _ in
        drawStatusMeter(label: "5h", percent: nil, unlimited: true, originX: 0)
        drawStatusMeter(label: "7d", percent: 79, unlimited: false, originX: 39)
        drawStatusLamp(state: .working, originX: 80)
        return true
    }
    image.isTemplate = false
    return image
}

private func drawStatusMeter(label: String, percent: Int?, unlimited: Bool, originX: CGFloat) {
    let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 8.3, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
    ]
    NSString(string: label).draw(at: NSPoint(x: originX, y: 6.6), withAttributes: labelAttributes)

    let center = NSPoint(x: originX + 25.5, y: 11)
    let activeCount = activeSegments(remainingPercent: unlimited ? 100 : percent)
    let activeColor = NSColor(UsageLevel(remainingPercent: unlimited ? 100 : (percent ?? 0)))

    for index in 0..<segmentCount {
        let start = 90 - CGFloat(index) * 360 / CGFloat(segmentCount)
        let end = start - 14
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: 8.5, startAngle: start, endAngle: end, clockwise: true)
        path.lineWidth = 2.6
        path.lineCapStyle = .butt
        (index < activeCount ? activeColor : NSColor.dormantSegment).setStroke()
        path.stroke()
    }

    let number = unlimited ? "∞" : (percent.map(String.init) ?? "--")
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 6.6, weight: .bold),
        .foregroundColor: NSColor.labelColor,
    ]
    let size = NSString(string: number).size(withAttributes: attributes)
    NSString(string: number).draw(
        at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
        withAttributes: attributes
    )
}

private func drawStatusLamp(state: AgentState, originX: CGFloat) {
    for (index, color) in AgentColor.allCases.enumerated() {
        let rect = NSRect(x: originX + CGFloat(index) * 9.5, y: 7.4, width: 7.4, height: 7.4)
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -1.2, dy: -1.2)).fill()
        guard state.active == color else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: rect).fill()
            continue
        }
        NSColor(color).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

private func drawAgentLamp(center: NSPoint, state: AgentState, scale: CGFloat = 1) {
    for (index, color) in AgentColor.allCases.enumerated() {
        let x = center.x - 38 * scale + CGFloat(index) * 38 * scale
        let rect = NSRect(x: x, y: center.y - 11 * scale, width: 22 * scale, height: 22 * scale)
        NSColor.secondaryLabelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -3 * scale, dy: -3 * scale)).fill()
        guard state.active == color else {
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: rect).fill()
            continue
        }
        if state.pulse {
            NSColor(color).withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -10 * scale, dy: -10 * scale)).fill()
            NSColor(color).withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: -5 * scale, dy: -5 * scale)).fill()
        }
        NSColor(color).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

private func drawAgentStateCard(_ rect: NSRect, state: AgentState, title: String) {
    NSColor.white.withAlphaComponent(0.84).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
    NSColor.panelStroke.withAlphaComponent(0.70).setStroke()
    let outline = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
    outline.lineWidth = 1
    outline.stroke()
    drawAgentLamp(center: NSPoint(x: rect.midX + 8, y: rect.maxY - 50), state: state, scale: 1.15)
    drawText(
        title,
        in: NSRect(x: rect.minX + 10, y: rect.minY + 10, width: rect.width - 20, height: 48),
        font: .systemFont(ofSize: 19, weight: .medium),
        alignment: .center
    )
}

let image = NSImage(size: canvasSize, flipped: false) { _ in
    NSColor(red: 0.985, green: 0.972, blue: 0.935, alpha: 1).setFill()
    NSRect(origin: .zero, size: canvasSize).fill()

    drawText(
        "Codex Meter",
        in: NSRect(x: 0, y: 795, width: canvasSize.width, height: 110),
        font: .systemFont(ofSize: 88, weight: .heavy),
        alignment: .center
    )
    drawText(
        "Accurate menu bar rendering + usage states / 真实状态栏样式 + 额度状态",
        in: NSRect(x: 0, y: 750, width: canvasSize.width, height: 44),
        font: .systemFont(ofSize: 30, weight: .semibold),
        color: .mutedInk,
        alignment: .center
    )

    let menuRect = NSRect(x: 232, y: 650, width: 1198, height: 66)
    NSColor.chromeFill.setFill()
    NSBezierPath(roundedRect: menuRect, xRadius: 18, yRadius: 18).fill()
    NSColor.panelStroke.withAlphaComponent(0.65).setStroke()
    let menuOutline = NSBezierPath(roundedRect: menuRect, xRadius: 18, yRadius: 18)
    menuOutline.lineWidth = 1.2
    menuOutline.stroke()
    let trafficColors = [
        NSColor(red: 0.96, green: 0.34, blue: 0.29, alpha: 1),
        NSColor(red: 0.98, green: 0.74, blue: 0.23, alpha: 1),
        NSColor(red: 0.28, green: 0.80, blue: 0.36, alpha: 1),
    ]
    for (index, color) in trafficColors.enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: menuRect.minX + 28 + CGFloat(index) * 24, y: menuRect.midY - 7, width: 14, height: 14)).fill()
    }
    drawText(
        "Status bar icon · exact 16-segment geometry, enlarged",
        in: NSRect(x: menuRect.minX + 120, y: menuRect.minY + 20, width: 560, height: 28),
        font: .systemFont(ofSize: 21, weight: .medium),
        color: .mutedInk
    )
    makeStatusItemImage().draw(
        in: NSRect(x: menuRect.maxX - 420, y: menuRect.minY, width: 333, height: 66),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    let usagePanel = NSRect(x: 42, y: 58, width: 760, height: 550)
    let agentPanel = NSRect(x: 860, y: 58, width: 760, height: 550)
    drawRoundedPanel(usagePanel)
    drawRoundedPanel(agentPanel)

    drawText(
        "Usage Quota / 额度",
        in: NSRect(x: usagePanel.minX, y: usagePanel.maxY - 74, width: usagePanel.width, height: 48),
        font: .systemFont(ofSize: 36, weight: .bold),
        alignment: .center
    )
    drawText(
        "16 segments · starts at 12 o'clock · fills clockwise",
        in: NSRect(x: usagePanel.minX, y: usagePanel.maxY - 110, width: usagePanel.width, height: 30),
        font: .systemFont(ofSize: 20, weight: .medium),
        color: .mutedInk,
        alignment: .center
    )

    drawUsageRing(center: NSPoint(x: usagePanel.minX + 170, y: usagePanel.minY + 322), radius: 82, percent: nil, lineWidth: 24, label: "5h 暂无限制", unlimited: true)
    drawUsageRing(center: NSPoint(x: usagePanel.minX + 380, y: usagePanel.minY + 322), radius: 82, percent: 79, lineWidth: 24, label: "7d 真实周额度")
    drawUsageRing(center: NSPoint(x: usagePanel.minX + 590, y: usagePanel.minY + 322), radius: 82, percent: 42, lineWidth: 24, label: "30-50%")
    drawUsageRing(center: NSPoint(x: usagePanel.minX + 270, y: usagePanel.minY + 130), radius: 76, percent: 18, lineWidth: 22, label: "10-30%", numberFontSize: 44, labelFontSize: 22)
    drawUsageRing(center: NSPoint(x: usagePanel.minX + 500, y: usagePanel.minY + 130), radius: 76, percent: 6, lineWidth: 22, label: "<10%", numberFontSize: 44, labelFontSize: 22)

    drawText(
        "Codex Agent Status / Agent 状态",
        in: NSRect(x: agentPanel.minX, y: agentPanel.maxY - 74, width: agentPanel.width, height: 48),
        font: .systemFont(ofSize: 36, weight: .bold),
        alignment: .center
    )
    let states: [(AgentState, String)] = [
        (.ready, "Ready / 空闲"),
        (.thinking, "Thinking / 思考中"),
        (.working, "Working / 工作中"),
        (.done, "Done / 已完成"),
        (.attention, "Attention / 需要查看"),
        (.stale, "Stale / 状态不可信"),
        (.permission, "Permission / 等待授权"),
        (.blocked, "Blocked / 阻塞/失败"),
        (.paused, "Paused / 已暂停"),
    ]
    let cardW: CGFloat = 210
    let cardH: CGFloat = 128
    for (index, entry) in states.enumerated() {
        let col = index % 3
        let row = index / 3
        let x = agentPanel.minX + 42 + CGFloat(col) * 238
        let y = agentPanel.maxY - 234 - CGFloat(row) * 152
        drawAgentStateCard(NSRect(x: x, y: y, width: cardW, height: cardH), state: entry.0, title: entry.1)
    }

    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    throw NSError(domain: "OverviewImageGenerator", code: 1)
}
try png.write(to: outputURL)
print(outputURL.path)
