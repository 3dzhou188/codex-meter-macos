import AppKit
import CodexUsageCore
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var agentSnapshot = AgentStatusSnapshot.idle(stateFileURL: AgentStatusStore.defaultStateFileURL())
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var animationTick = 0
    @Published var launchAtLogin = false
    @Published var agentMonitoringEnabled = true
    @Published var statusDisplayMode: StatusDisplayMode = .usageAndAgent

    private let appServer = CodexAppServerClient()
    private let agentStateStore = AgentStatusStore()
    private let agentActivityProvider = CodexDesktopActivityProvider()
    private var appServerSnapshot: UsageSnapshot?
    private var notificationState = NotificationThresholdState()
    private var tasks: [Task<Void, Never>] = []
    private var appliedDesktopActivityKeys = Set<String>()

    var isStale: Bool {
        snapshot.map { UsageMerger.isStale($0) } ?? false
    }

    func start() {
        guard tasks.isEmpty else { return }
        configurePushUpdates()
        configureLaunchAtLogin()
        configureAgentPreferences()
        requestNotificationPermission()

        tasks.append(Task { [weak self] in
            await self?.refreshAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.refreshOnline()
            }
        })

        tasks.append(Task { [weak self] in
            await self?.refreshAgentStatus()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await self?.refreshAgentStatus()
            }
        })

        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { self?.advanceAgentAnimation() }
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        appServer.stop()
    }

    func refreshAll() async {
        await refreshOnline()
        await refreshAgentStatus()
    }

    func refreshOnline() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        applyOnline(await result { try await appServer.fetch() })
        isRefreshing = false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            UserDefaults.standard.set(enabled, forKey: "launchAtLoginDesired")
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorMessage = "无法更改开机启动：\(error.localizedDescription)"
        }
    }

    func openCodex() {
        let applications = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
        guard let path = applications.first(where: FileManager.default.fileExists(atPath:)) else {
            errorMessage = "未找到 ChatGPT 或 Codex 应用"
            return
        }
        if !NSWorkspace.shared.open(URL(fileURLWithPath: path)) {
            errorMessage = "无法打开 \(path)"
        }
    }

    func setAgentMonitoringEnabled(_ enabled: Bool) {
        agentMonitoringEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "agentMonitoringEnabled")
        if enabled {
            Task { await refreshAgentStatus() }
        } else {
            agentSnapshot = AgentStatusSnapshot(
                aggregate: .paused,
                sessions: [],
                recentEvents: agentSnapshot.recentEvents,
                updatedAt: Date(),
                stateFileURL: agentStateStore.stateFileURL
            )
        }
    }

    func setStatusDisplayMode(_ mode: StatusDisplayMode) {
        statusDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "statusDisplayMode")
    }

    private func configurePushUpdates() {
        appServer.setSnapshotHandler { [weak self] snapshot in
            Task { @MainActor in self?.accept(snapshot) }
        }
    }

    private func configureLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let key = "launchAtLoginDesired"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(true, forKey: key)
        }
        if UserDefaults.standard.bool(forKey: key), !launchAtLogin {
            setLaunchAtLogin(true)
        }
    }

    private func configureAgentPreferences() {
        let monitoringKey = "agentMonitoringEnabled"
        if UserDefaults.standard.object(forKey: monitoringKey) == nil {
            UserDefaults.standard.set(true, forKey: monitoringKey)
        }
        agentMonitoringEnabled = UserDefaults.standard.bool(forKey: monitoringKey)

        if let rawMode = UserDefaults.standard.string(forKey: "statusDisplayMode"),
           let mode = StatusDisplayMode(rawValue: rawMode) {
            statusDisplayMode = mode
        } else {
            statusDisplayMode = .usageAndAgent
            UserDefaults.standard.set(statusDisplayMode.rawValue, forKey: "statusDisplayMode")
        }
    }

    private nonisolated func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func applyOnline(_ value: Result<UsageSnapshot, Error>) {
        switch value {
        case .success(let snapshot): accept(snapshot)
        case .failure(let error):
            errorMessage = "实时服务连接失败：\(error.localizedDescription)"
        }
    }

    private func refreshAgentStatus() async {
        guard agentMonitoringEnabled else { return }
        let activities = await Task.detached { [agentActivityProvider] in
            agentActivityProvider.recentActivities()
        }.value

        do {
            let currentActivityKeys = Set(activities.map(activityKey))
            appliedDesktopActivityKeys.formIntersection(currentActivityKeys)
            for activity in activities {
                let key = activityKey(activity)
                guard !appliedDesktopActivityKeys.contains(key) else { continue }
                try agentStateStore.apply(activity)
                appliedDesktopActivityKeys.insert(key)
            }
            agentSnapshot = try agentStateStore.readSnapshot()
        } catch {
            agentSnapshot = AgentStatusSnapshot(
                aggregate: .stale,
                sessions: [],
                recentEvents: agentSnapshot.recentEvents,
                updatedAt: Date(),
                stateFileURL: agentStateStore.stateFileURL
            )
            errorMessage = "Agent 状态读取失败：\(error.localizedDescription)"
        }
    }

    private func activityKey(_ activity: AgentActivity) -> String {
        "\(activity.sessionID)|\(activity.updatedAt.timeIntervalSince1970)|\(activity.signal.rawValue)|\(activity.event ?? "")"
    }

    private func advanceAgentAnimation() {
        animationTick = (animationTick + 1) % 10_000
    }

    private func accept(_ newSnapshot: UsageSnapshot) {
        appServerSnapshot = appServerSnapshot.map {
            UsageMerger.mergeSparse(base: $0, update: newSnapshot)
        } ?? newSnapshot
        snapshot = appServerSnapshot
        if errorMessage?.hasPrefix("实时服务连接失败") == true { errorMessage = nil }
        if let snapshot { notifyIfNeeded(snapshot) }
    }

    private func notifyIfNeeded(_ snapshot: UsageSnapshot) {
        notify(window: snapshot.fiveHourWindow, kind: .primary, name: "5 小时额度")
        notify(window: snapshot.sevenDayWindow, kind: .secondary, name: "7 天额度")
    }

    private func notify(window: UsageWindow?, kind: UsageWindowKind, name: String) {
        guard let window else { return }
        for threshold in notificationState.crossedThresholds(
            window: kind,
            remaining: window.remainingPercent,
            resetAt: window.resetsAt
        ) {
            let identifier = "\(kind)-\(threshold)-\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
            let preferenceKey = "notification.sent.\(identifier)"
            guard !UserDefaults.standard.bool(forKey: preferenceKey) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Codex \(name)不足"
            content.body = "剩余 \(window.remainingPercent)%（已低于 \(threshold)%）"
            content.sound = .default
            deliverNotification(identifier: identifier, preferenceKey: preferenceKey, content: content)
        }
    }

    private nonisolated func deliverNotification(
        identifier: String,
        preferenceKey: String,
        content: UNMutableNotificationContent
    ) {
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        ) { error in
            if error == nil {
                UserDefaults.standard.set(true, forKey: preferenceKey)
            }
        }
    }
}

private func result<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}
