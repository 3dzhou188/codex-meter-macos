import CodexUsageCore
import SwiftUI

struct UsageMenuView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = store.snapshot {
                UsageWindowView(title: "5 小时额度", window: snapshot.primary)
                Divider()
                UsageWindowView(title: "7 天额度", window: snapshot.secondary)
                Divider()
                metadata(snapshot)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("暂无用量数据").font(.headline)
                    Text(store.errorMessage ?? "请确认 Codex 已登录并正在运行，然后点击立即刷新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }

            Divider()
            AgentStatusSection(store: store)

            if let error = store.errorMessage, store.snapshot != nil {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            HStack {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label(store.isRefreshing ? "正在刷新" : "立即刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                Spacer()
                Button("打开 Codex") { store.openCodex() }
            }

            Toggle("开机自动启动", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))

            HStack {
                Text("Codex Meter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { Task { await store.refreshAll() } }
    }

    @ViewBuilder
    private func metadata(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent("套餐", value: snapshot.planType?.uppercased() ?? "未知")
            LabeledContent("数据来源", value: "Codex 实时服务")
            LabeledContent("最后更新", value: snapshot.updatedAt.formatted(date: .omitted, time: .standard))
            if store.isStale {
                Label("数据超过 15 分钟，可能已经过期", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
    }
}

private struct AgentStatusSection: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Codex Agent 状态", systemImage: "trafficlight")
                    .font(.headline)
                Spacer()
                Text(store.agentSnapshot.aggregate.displayName)
                    .font(.headline)
                    .foregroundStyle(color)
            }

            LabeledContent("建议", value: store.agentSnapshot.aggregate.displayState.actionText)
                .font(.caption)
            LabeledContent("最后更新", value: lastUpdatedText)
                .font(.caption)
            Text(store.agentSnapshot.aggregate.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !store.agentSnapshot.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("活跃 session").font(.caption.bold())
                    ForEach(store.agentSnapshot.sessions.prefix(3)) { session in
                        HStack {
                            Text(shortSessionID(session.sessionID))
                                .font(.caption.monospaced())
                            Text(session.signal.displayName)
                                .font(.caption)
                            Spacer()
                            Text(session.updatedAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !store.agentSnapshot.recentEvents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近事件").font(.caption.bold())
                    ForEach(store.agentSnapshot.recentEvents.prefix(3)) { event in
                        HStack {
                            Text(event.signal.displayName)
                                .font(.caption)
                            Text(event.event ?? shortSessionID(event.sessionID))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                }
            }

            Toggle("Codex Desktop 监控", isOn: Binding(
                get: { store.agentMonitoringEnabled },
                set: { store.setAgentMonitoringEnabled($0) }
            ))

            Picker("状态栏显示", selection: Binding(
                get: { store.statusDisplayMode },
                set: { store.setStatusDisplayMode($0) }
            )) {
                ForEach(StatusDisplayMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var color: Color {
        switch store.agentSnapshot.aggregate.displayState {
        case .permission, .blocked:
            return .red
        case .needsReview, .stale:
            return .yellow
        case .paused:
            return .secondary
        case .ready, .active, .completed:
            return .green
        }
    }

    private var lastUpdatedText: String {
        guard let updatedAt = store.agentSnapshot.updatedAt else { return "尚无状态" }
        return updatedAt.formatted(date: .omitted, time: .standard)
    }

    private func shortSessionID(_ id: String) -> String {
        if id.count <= 10 { return id }
        return "\(id.prefix(6))…\(id.suffix(3))"
    }
}

private struct UsageWindowView: View {
    let title: String
    let window: UsageWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(window.map { "\($0.remainingPercent)%" } ?? "--")
                    .font(.title3.bold())
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            ProgressView(value: Double(window?.remainingPercent ?? 0), total: 100)
                .tint(color)
            HStack {
                Text("剩余")
                Spacer()
                Text(resetDescription)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        guard let remaining = window?.remainingPercent else { return .secondary }
        return Color(UsageLevel(remainingPercent: remaining))
    }

    private var resetDescription: String {
        guard let reset = window?.resetsAt else { return "重置时间未知" }
        let relative = reset.formatted(.relative(presentation: .numeric))
        let exact = reset.formatted(date: .abbreviated, time: .shortened)
        return "\(relative)（\(exact)）"
    }
}
