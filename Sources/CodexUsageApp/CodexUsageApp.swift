import AppKit
import Combine
import CodexUsageCore
import SwiftUI

@main
struct CodexUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: 119)
        statusItem = item
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 680)
        popover.contentViewController = NSHostingController(rootView: UsageMenuView(store: store))

        Publishers.CombineLatest4(
            store.$snapshot,
            store.$agentSnapshot,
            store.$statusDisplayMode,
            store.$animationTick
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] usage, agent, mode, tick in
                self?.updateStatusImage(usage: usage, agent: agent, mode: mode, tick: tick)
            }
            .store(in: &cancellables)

        updateStatusImage(
            usage: nil,
            agent: store.agentSnapshot,
            mode: store.statusDisplayMode,
            tick: store.animationTick
        )
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusImage(
        usage: UsageSnapshot?,
        agent: AgentStatusSnapshot,
        mode: StatusDisplayMode,
        tick: Int
    ) {
        guard let button = statusItem?.button else { return }
        let image = StatusItemImageFactory.make(usage: usage, agent: agent, mode: mode, tick: tick)
        statusItem?.length = image.size.width + 8
        button.image = image
        let description = "Codex 5 小时：\(usage?.primary?.remainingPercent.description ?? "--")%，7 天：\(usage?.secondary?.remainingPercent.description ?? "--")%，Agent：\(agent.aggregate.displayName)"
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }
}
