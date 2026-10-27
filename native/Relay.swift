import AppKit
import Combine
import Foundation
import SwiftUI

// Relay: menu bar popover as the primary surface, with an expanded native workspace window as a secondary view.
// All data flows through the shared EngineClient; there is no WebKit or HTML.

private let attentionStatuses: Set<String> = ["attention", "needs_attention", "waiting", "blocked"]
private let errorStatuses: Set<String> = ["error", "failed", "failure"]
private let runningStatuses: Set<String> = ["running", "active", "working", "busy"]
private let pollInterval: UInt64 = 5_000_000_000

func needsAttention(_ status: String) -> Bool {
    let value = status.lowercased()
    return attentionStatuses.contains(value) || errorStatuses.contains(value)
}

func statusColor(_ status: String) -> Color {
    let value = status.lowercased()
    if errorStatuses.contains(value) { return .red }
    if attentionStatuses.contains(value) { return .orange }
    switch value {
    case "running", "active", "working", "busy", "ok", "healthy", "up": return .green
    case "idle", "done", "completed", "complete", "finished": return .secondary
    default: return .gray
    }
}

// Round-robins providers so Claude and Codex both appear, then returns the chosen tasks newest first.
func fairRecent(_ sessions: [RelaySession], limit: Int) -> [RelaySession] {
    func priority(_ s: RelaySession) -> Int {
        if runningStatuses.contains(s.status) { return 0 }
        if needsAttention(s.status) { return 1 }
        return 2
    }
    func before(_ a: RelaySession, _ b: RelaySession) -> Bool {
        if priority(a) != priority(b) { return priority(a) < priority(b) }
        return (a.last_event_at ?? "") > (b.last_event_at ?? "")
    }
    let newestFirst = sessions.sorted(by: before)
    var buckets: [String: [RelaySession]] = [:]
    for session in newestFirst { buckets[session.provider, default: []].append(session) }
    let providers = buckets.keys.sorted()
    var picked: [RelaySession] = []
    var round = 0
    while picked.count < limit {
        var added = false
        for provider in providers {
            guard let list = buckets[provider], round < list.count, picked.count < limit else { continue }
            picked.append(list[round])
            added = true
        }
        if !added { break }
        round += 1
    }
    return picked.sorted(by: before)
}

func providerLabel(_ session: RelaySession) -> String {
    session.provider.lowercased().contains("claude") ? "Claude Code" : "Codex"
}

// One list row: the session plus its nesting depth in the parent/child tree.
struct SessionNode: Identifiable {
    let session: RelaySession
    let depth: Int
    var id: String { session.key }
}

// Collapses control characters and runs of whitespace so the value fits on one line, e.g. for /rename.
func oneLine(_ value: String) -> String {
    let spaced = value.map { character in
        character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : character
    }
    return String(spaced).split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

@MainActor
final class SessionModel: ObservableObject {
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var demo = false
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    @Published var errorMessage: String?
    @Published var selectedKey: String?
    @Published var search = ""
    @Published var providerFilter = "all"
    @Published var statusFilter = "all"

    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var sessions: [RelaySession] { snapshot?.sessions ?? [] }
    var providers: [ProviderHealth] { snapshot?.providers ?? [] }
    var counts: [String: Int] { snapshot?.counts ?? [:] }
    var providerOptions: [String] { Set(sessions.map(\.provider)).sorted() }
    var statusOptions: [String] { Set(sessions.map(\.status)).sorted() }
    var attentionSessions: [RelaySession] { sessions.filter { needsAttention($0.status) } }
    var activeTasks: [RelaySession] { fairRecent(sessions, limit: 8) }
    var runningSessions: [RelaySession] { sessions.filter { runningStatuses.contains($0.status.lowercased()) } }
    var waitingSessions: [RelaySession] { sessions.filter { attentionStatuses.contains($0.status.lowercased()) } }
    var failedSessions: [RelaySession] { sessions.filter { errorStatuses.contains($0.status.lowercased()) } }
    // Base filter only. It never reads selection, so the derived lists below cannot recurse.
    private var filteredSessions: [RelaySession] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.filter { session in
            (providerFilter == "all" || session.provider == providerFilter)
                && (statusFilter == "all" || session.status == statusFilter)
                && matches(session, query: query)
        }
    }

    // Parents come before their visible children. A child is indented only when its parent is also visible.
    var visibleRows: [SessionNode] {
        let base = filteredSessions
        let visibleKeys = Set(base.map(\.key))
        var children: [String: [RelaySession]] = [:]
        var roots: [RelaySession] = []
        for session in base {
            if let parent = session.parent_key, parent != session.key, visibleKeys.contains(parent) {
                children[parent, default: []].append(session)
            } else {
                roots.append(session)
            }
        }
        var rows: [SessionNode] = []
        var placed = Set<String>()
        func place(_ session: RelaySession, depth: Int) {
            guard placed.insert(session.key).inserted else { return }
            rows.append(SessionNode(session: session, depth: depth))
            for child in children[session.key] ?? [] { place(child, depth: depth + 1) }
        }
        for root in roots { place(root, depth: 0) }
        // Parent cycles leave members unreachable from any root; surface them as top-level rows.
        for session in base { place(session, depth: 0) }
        return rows
    }

    var visibleSessions: [RelaySession] { visibleRows.map(\.session) }

    // The inspector only acts on a selection that is currently visible, so hidden rows cannot be mutated.
    var selectedSession: RelaySession? { visibleSessions.first { $0.key == selectedKey } }

    func session(forKey key: String) -> RelaySession? { sessions.first { $0.key == key } }

    private func matches(_ session: RelaySession, query: String) -> Bool {
        if query.isEmpty { return true }
        let fields = [session.name, session.title, session.task, session.project, session.provider, session.status, session.id]
        return fields.contains { $0.lowercased().contains(query) }
    }

    static func sessionPath(_ session: RelaySession, _ action: String) -> String {
        "/api/sessions/\(EngineClient.component(session.provider))/\(EngineClient.component(session.id))/\(action)"
    }

    // Polling runs as one loop; startPolling is a no-op if it is already running.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
    }

    func refreshNow() {
        Task { await refresh(restart: true) }
    }

    // Results from the previous mode are cleared immediately, before the new fetch.
    func setDemo(_ value: Bool) {
        guard value != demo else { return }
        demo = value
        snapshot = nil
        selectedKey = nil
        errorMessage = nil
        refreshNow()
    }

    func clearFilters() {
        search = ""
        providerFilter = "all"
        statusFilter = "all"
    }

    func reveal(_ key: String) {
        clearFilters()
        selectedKey = key
    }

    // Joins an in-flight refresh unless restart is requested, so overlapping callers share one request.
    func refresh(restart: Bool = false) async {
        if restart {
            refreshTask?.cancel()
            refreshTask = nil
        }
        if let inFlight = refreshTask {
            await inFlight.value
            return
        }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        if refreshTask == task { refreshTask = nil }
    }

    private func performRefresh() async {
        if snapshot == nil { loading = true }
        defer { loading = false }
        do {
            try await EngineClient.shared.ensureStarted()
            let path = demo ? "/api/sessions?demo=1" : "/api/sessions"
            let fresh: SessionSnapshot = try await EngineClient.shared.request(path)
            guard !Task.isCancelled else { return }
            snapshot = fresh
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    func saveName(_ session: RelaySession, name: String) async {
        await mutate {
            _ = try await EngineClient.shared.data(Self.sessionPath(session, "name"), method: "PATCH", body: ["name": name])
        }
    }

    // Only called from an explicit user action after a confirmation alert.
    func syncName(_ session: RelaySession) async {
        await mutate {
            _ = try await EngineClient.shared.data(Self.sessionPath(session, "sync-name"), method: "POST", body: ["name": session.name])
        }
    }

    private func mutate(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await EngineClient.shared.ensureStarted()
            try await work()
            errorMessage = nil
            await refresh(restart: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SessionModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildPopover()
        buildStatusItem()
        model.objectWillChange
            .sink { [weak self] _ in
                // Update the status item after the pending change lands on the main actor.
                Task { @MainActor [weak self] in self?.updateStatusItem() }
            }
            .store(in: &cancellables)
        model.startPolling()
        // One popover after launch so the menu bar surface is discoverable; the workspace window stays closed.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.showPopover()
        }
    }

    // Closing the window keeps the menu bar item alive; the menu bar or a Finder relaunch reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
        } else {
            showPopover()
        }
        return true
    }

    private func showWindow() {
        if window == nil {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            created.title = "Relay"
            created.minSize = NSSize(width: 960, height: 620)
            created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView: RootView(model: model))
            created.center()
            created.setFrameAutosaveName("RelayMainWindow")
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Relay")
        appMenu.addItem(menuItem("Quit Relay", #selector(quitAction), key: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Standard Edit menu. Actions go through the responder chain (nil target) so the focused text field handles them.
        let editRoot = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(responderItem("Undo", Selector(("undo:")), key: "z"))
        editMenu.addItem(responderItem("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(responderItem("Cut", Selector(("cut:")), key: "x"))
        editMenu.addItem(responderItem("Copy", Selector(("copy:")), key: "c"))
        editMenu.addItem(responderItem("Paste", Selector(("paste:")), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(responderItem("Select All", Selector(("selectAll:")), key: "a"))
        editRoot.submenu = editMenu
        mainMenu.addItem(editRoot)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(menuItem("Refresh", #selector(refreshAction), key: "r"))
        viewMenu.addItem(menuItem("Open Repro", #selector(openRepro)))
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(menuItem("Show Relay", #selector(openRelay), key: "0"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    // The popover is built once and observes the shared model, so polling never replaces it.
    private func buildPopover() {
        let actions = PopoverActions(
            openWorkspace: { [weak self] in self?.openRelay() },
            openSession: { [weak self] key in self?.openSession(key) },
            openRepro: { [weak self] in self?.openRepro() },
            quit: { NSApp.terminate(nil) }
        )
        let size = NSSize(width: 390, height: 560)
        let controller = NSViewController()
        controller.view = nativeGlassHost(RelayPopoverView(model: model, actions: actions), size: size)
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = size
        popover.contentViewController = controller
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        updateStatusItem()
    }

    // Updates only the title, symbol, and tooltip. The button action and popover are left in place across polls.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let running = model.runningSessions.count
        let attention = model.attentionSessions.count
        let symbol = attention > 0 ? "exclamationmark.triangle.fill" : "square.stack.3d.up"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Relay")
        button.title = running == 0 && attention == 0 ? "" : " \(running) · \(attention)"
        let summary = "Relay: \(running) running, \(attention) need attention, \(model.sessions.count) sessions"
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.refreshNow()
    }

    private func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    private func openSession(_ key: String) {
        closePopover()
        model.reveal(key)
        showWindow()
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func responderItem(_ title: String, _ action: Selector, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @objc private func openRelay() {
        closePopover()
        showWindow()
    }

    @objc private func openRepro() {
        closePopover()
        openSiblingApp("Repro")
    }

    @objc private func refreshAction() {
        model.refreshNow()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}

struct PopoverActions {
    let openWorkspace: () -> Void
    let openSession: (String) -> Void
    let openRepro: () -> Void
    let quit: () -> Void
}

// Menu bar popover content. It sits on the system glass from nativeGlassHost, so it avoids opaque list backgrounds.
struct RelayPopoverView: View {
    @ObservedObject var model: SessionModel
    let actions: PopoverActions

    private var connection: (label: String, color: Color) {
        if model.demo { return ("Synthetic demo", .indigo) }
        if model.snapshot == nil { return model.errorMessage == nil ? ("Connecting", .gray) : ("Offline", .red) }
        return model.errorMessage == nil ? ("Live", .green) : ("Stale", .orange)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            demoToggle
            summaryPills
            if model.snapshot != nil, let message = model.errorMessage {
                errorBanner(message)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.snapshot == nil {
                        unavailableState
                    } else {
                        if !model.attentionSessions.isEmpty { attentionSection }
                        tasksSection
                        providerSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 2)
            }
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 30, height: 30)
                .fineCard(cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Relay").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(connection.color).frame(width: 7, height: 7)
                    Text(connection.label).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Connection: \(connection.label)")
            }
            Spacer(minLength: 8)
            Button { model.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh sessions")
            .accessibilityLabel("Refresh sessions")
            Menu {
                Button("Open Relay Workspace", action: actions.openWorkspace)
                Button("Open Repro", action: actions.openRepro)
                Divider()
                Button("Quit Relay", action: actions.quit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
    }

    private var demoToggle: some View {
        HStack(spacing: 8) {
            Toggle("Synthetic demo data", isOn: Binding(get: { model.demo }, set: { model.setDemo($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.indigo)
                .help("Show generated sample sessions instead of your real sessions")
            if model.demo {
                Text("SAMPLE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.indigo.opacity(0.15)))
            }
            Spacer()
        }
        .font(.caption)
    }

    private var summaryPills: some View {
        HStack(spacing: 8) {
            pill("Running", model.runningSessions.count, "play.circle.fill", .green)
            pill("Waiting", model.waitingSessions.count, "hourglass", .orange)
            pill("Failed", model.failedSessions.count, "xmark.octagon.fill", .red)
        }
    }

    private func pill(_ title: String, _ count: Int, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title).foregroundStyle(.secondary)
            Text("\(count)").fontWeight(.semibold).monospacedDigit()
        }
        .font(.caption)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") { model.refreshNow() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder private var unavailableState: some View {
        if model.loading {
            ProgressView("Connecting to Relay…")
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Relay engine unavailable").font(.headline)
                Text(model.errorMessage ?? "Relay has not responded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Button("Retry") { model.refreshNow() }
                    .buttonStyle(.bordered)
                    .tint(.cyan)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .fineCard()
        }
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("NEEDS ATTENTION", countText: "\(model.attentionSessions.count)")
            ForEach(Array(model.attentionSessions.prefix(3)), id: \.key) { session in
                TaskCard(session: session, onOpen: { actions.openSession(session.key) })
            }
            if model.attentionSessions.count > 3 {
                Button("View all \(model.attentionSessions.count)", action: actions.openWorkspace)
                    .buttonStyle(.link)
                    .controlSize(.small)
            }
        }
    }

    // Shows shown/total when the popover caps the list.
    private var taskCountText: String {
        let shown = model.activeTasks.count
        let total = model.sessions.count
        return shown < total ? "\(shown)/\(total)" : "\(total)"
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("CURRENT & RECENT WORK", countText: taskCountText)
            if model.sessions.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title3).foregroundStyle(.secondary)
                    Text("No sessions yet").font(.subheadline.weight(.semibold))
                    Text("Claude Code and Codex sessions appear here once discovered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .fineCard()
            } else {
                ForEach(model.activeTasks, id: \.key) { session in
                    TaskCard(session: session, onOpen: { actions.openSession(session.key) })
                }
            }
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("PROVIDERS", countText: nil)
            if model.providers.isEmpty {
                Text("No provider data").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.providers) { provider in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle().fill(statusColor(provider.status)).frame(width: 7, height: 7)
                        Text(provider.id.capitalized).font(.caption.weight(.medium))
                        Spacer()
                        Text(provider.status.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = provider.message {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .fineCard()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: actions.openWorkspace) {
                Label("Workspace", systemImage: "rectangle.split.2x1")
            }
            Button(action: actions.openRepro) {
                Label("Open Repro", systemImage: "wrench.and.screwdriver")
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.cyan)
    }

    private func sectionHeader(_ title: String, countText: String?) -> some View {
        HStack {
            Text(title)
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            if let countText {
                Text(countText).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct TaskCard: View {
    let session: RelaySession
    let onOpen: () -> Void

    private var summary: String { session.task.isEmpty ? session.title : session.task }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: session.provider.lowercased().contains("claude") ? "sparkle" : "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.cyan.opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .help(session.name)
                        Spacer(minLength: 4)
                        StatusChip(status: session.status)
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(providerLabel(session))
                        Text("·")
                        Text(session.project).lineLimit(1).truncationMode(.middle).help(session.project)
                        Spacer(minLength: 4)
                        Text(session.last_activity).lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .fineCard()
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Show in the Relay workspace")
        .accessibilityLabel("\(session.name), \(providerLabel(session)), \(session.status)")
    }
}

struct StatusChip: View {
    let status: String

    var body: some View {
        Text(status.capitalized)
            .font(.caption2.weight(.medium))
            .foregroundStyle(statusColor(status))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(statusColor(status).opacity(0.14)))
    }
}

// Subtle white-opacity surface and hairline border for small cards on top of the glass.
extension View {
    func fineCard(cornerRadius: CGFloat = 12) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.5))
    }
}

struct RootView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        VStack(spacing: 0) {
            if let message = model.errorMessage {
                ErrorBanner(message: message) { model.refreshNow() }
            }
            NavigationSplitView {
                SidebarView(model: model)
            } content: {
                SessionListView(model: model)
            } detail: {
                InspectorView(model: model)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}

struct ErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).lineLimit(2).textSelection(.enabled)
            Spacer()
            Button("Retry", action: retry)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        List {
            Section("Filters") {
                Picker("Provider", selection: $model.providerFilter) {
                    Text("All Providers").tag("all")
                    ForEach(model.providerOptions, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Status", selection: $model.statusFilter) {
                    Text("All Statuses").tag("all")
                    ForEach(model.statusOptions, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Toggle("Demo Data", isOn: Binding(get: { model.demo }, set: { model.setDemo($0) }))
                    .help("Replace live sessions with demo sessions")
            }

            Section("Providers") {
                if model.providers.isEmpty {
                    Text("No provider data").foregroundStyle(.secondary)
                }
                ForEach(model.providers) { provider in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Circle().fill(statusColor(provider.status)).frame(width: 8, height: 8)
                            Text(provider.id.capitalized).fontWeight(.medium)
                            Spacer()
                            Text(provider.status.capitalized).font(.caption).foregroundStyle(.secondary)
                        }
                        if let message = provider.message {
                            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }

            Section("Counts") {
                if model.counts.isEmpty {
                    Text("No counts yet").foregroundStyle(.secondary)
                }
                ForEach(model.counts.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                        Spacer()
                        Text("\(model.counts[key] ?? 0)").monospacedDigit()
                    }
                }
            }

            Section("Actions") {
                Button { model.refreshNow() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button { openSiblingApp("Repro") } label: {
                    Label("Open Repro", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Relay")
        .navigationSplitViewColumnWidth(min: 200, ideal: 220)
    }
}

struct SessionListView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        Group {
            if model.snapshot == nil && model.loading {
                ProgressView("Loading sessions…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.snapshot == nil {
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Sessions unavailable",
                    detail: model.errorMessage ?? "Relay has not loaded sessions yet.",
                    actionTitle: "Retry",
                    action: { model.refreshNow() }
                )
            } else if model.sessions.isEmpty {
                EmptyStateView(
                    symbol: "tray",
                    title: "No sessions yet",
                    detail: "Sessions from Claude Code and Codex will appear here once they are discovered."
                )
            } else if model.visibleSessions.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No matching sessions",
                    detail: "Adjust the search or filters to see more sessions.",
                    actionTitle: "Clear Filters",
                    action: { model.clearFilters() }
                )
            } else {
                List(selection: $model.selectedKey) {
                    ForEach(model.visibleRows) { node in
                        SessionRow(session: node.session, depth: node.depth).tag(node.session.key)
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $model.search, prompt: "Search sessions")
        .navigationTitle("Sessions")
        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refreshNow() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh sessions (⌘R)")
            }
        }
    }
}

struct SessionRow: View {
    let session: RelaySession
    // Depth is nonzero only when the parent row is visible in the same list.
    let depth: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            Circle()
                .fill(statusColor(session.status))
                .frame(width: 9, height: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(session.status.capitalized)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor(session.status))
                }
                Text(session.task.isEmpty ? session.title : session.task)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(session.provider.capitalized)
                    Text("·")
                    Text(session.project).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(session.last_activity).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(depth > 0 ? "Child session, \(session.name), \(session.status)" : "\(session.name), \(session.status)")
    }
}

struct InspectorView: View {
    @ObservedObject var model: SessionModel

    var body: some View {
        Group {
            if let session = model.selectedSession {
                // Keyed by session so the draft alias resets when the selection changes.
                SessionDetail(session: session, model: model).id(session.key)
            } else {
                EmptyStateView(
                    symbol: "sidebar.right",
                    title: "No session selected",
                    detail: "Choose a session to edit its alias, copy its resume command, and review its provenance."
                )
            }
        }
        .navigationTitle("Inspector")
        .navigationSplitViewColumnWidth(min: 300, ideal: 340)
    }
}

struct SessionDetail: View {
    let session: RelaySession
    @ObservedObject var model: SessionModel
    @State private var draft: String
    // The last saved alias the draft was synced to. Used to tell an untouched draft from an edited one.
    @State private var syncedAlias: String
    @State private var copiedNote: String?

    init(session: RelaySession, model: SessionModel) {
        self.session = session
        _model = ObservedObject(wrappedValue: model)
        _draft = State(initialValue: session.alias ?? "")
        _syncedAlias = State(initialValue: session.alias ?? "")
    }

    private var isCodex: Bool { session.provider.lowercased().contains("codex") }
    private var isClaude: Bool { session.provider.lowercased().contains("claude") }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isDirty: Bool { trimmedDraft != (session.alias ?? "") }

    private var resumeCommand: String {
        if isClaude { return "claude --resume \(shellQuoted(session.id))" }
        if isCodex { return "codex resume \(shellQuoted(session.id))" }
        return session.id
    }

    var body: some View {
        Form {
            Section {
                TextField("Local alias", text: $draft, prompt: Text(session.suggested_name ?? "Automatic name"))
                    .onSubmit { save() }
                HStack {
                    Button("Save Alias") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!isDirty || model.busy)
                    Button("Use Suggested") { draft = session.suggested_name ?? "" }
                        .disabled(session.suggested_name == nil || model.busy)
                    if model.busy {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Empty aliases show the suggested name. Saving an empty alias clears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Name")
            }

            Section {
                Button("Copy Resume Command") { copy(resumeCommand, note: "Copied resume command") }
                Button("Copy Session ID") { copy(session.id, note: "Copied session ID") }
                if isClaude {
                    Button("Copy /rename Command") { copy("/rename \(oneLine(session.name))", note: "Copied /rename command") }
                }
                if let copiedNote {
                    Label(copiedNote, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if isCodex {
                    Button("Sync Name to Codex…") { confirmSync() }
                        .disabled(model.demo || model.busy || session.name.isEmpty)
                    Text("Manual only. Relay never syncs names automatically. Demo sessions cannot be synced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Resume & Sync")
            }

            Section {
                LabeledContent("Role", value: session.role)
                LabeledContent("Model", value: session.model ?? "—")
                LabeledContent("Status") {
                    Text("\(session.status) · \(session.status_source)")
                        .foregroundStyle(statusColor(session.status))
                }
                LabeledContent("Last activity", value: session.last_activity)
                LabeledContent("Last event", value: session.last_event_at ?? "—")
                LabeledContent("Tokens", value: session.tokens.map { $0.formatted() } ?? "—")
                LabeledContent("Project", value: session.project)
                LabeledContent("Directory", value: session.cwd)
                LabeledContent("Parent") {
                    if let key = session.parent_key, let parent = model.session(forKey: key) {
                        // Reveal clears filters so the parent is visible and selectable.
                        Button(parent.name) { model.reveal(parent.key) }
                            .buttonStyle(.link)
                            .help("Show parent session")
                            .accessibilityLabel("Show parent: \(parent.name)")
                    } else {
                        Text(session.parent_key ?? "None")
                    }
                }
            } header: {
                Text("Provenance")
            }

            Section {
                LabeledContent("Key", value: session.key)
                LabeledContent("Provider", value: session.provider)
            } header: {
                Text("Identity")
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
        .onChange(of: session.alias) { newAlias in
            // Follow an external alias change only when the draft was still untouched; unsaved edits survive polling.
            let saved = newAlias ?? ""
            if trimmedDraft == syncedAlias { draft = saved }
            syncedAlias = saved
        }
    }

    private func save() {
        guard isDirty, !model.busy else { return }
        let name = trimmedDraft
        Task { await model.saveName(session, name: name) }
    }

    // Copies, then shows a short confirmation. A newer copy keeps its own note visible.
    private func copy(_ value: String, note: String) {
        copyNative(value)
        copiedNote = note
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedNote == note { copiedNote = nil }
        }
    }

    // Explicit confirmation is required; nothing syncs on its own.
    private func confirmSync() {
        let alert = NSAlert()
        alert.messageText = "Sync name to Codex?"
        alert.informativeText = "This writes \"\(session.name)\" to the Codex session \(session.id). Nothing else changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sync Name")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let target = session
        Task { await model.syncName(target) }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

let application = NSApplication.shared
// Top-level code runs on the main thread, so the main-actor delegate is created here.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
