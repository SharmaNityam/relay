import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Repro: native generator for failing-test reproductions. The parent build copies this file to
// main.swift, so the top-level launch code below is the app entrypoint.

// MARK: - Models

enum ReproGenerator: String, CaseIterable, Identifiable {
    case claudeCode = "claude"
    case openAICompatible = "openai"
    case demo = "demo"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code (default)"
        case .openAICompatible: return "OpenAI-compatible endpoint"
        case .demo: return "Demo (prewritten, not AI)"
        }
    }

    var note: String {
        switch self {
        case .claudeCode:
            return "Claude Code writes the test. Source snippets leave this Mac only when you press Generate, and only go to Claude Code."
        case .openAICompatible:
            return "Uses the OpenAI-compatible endpoint configured in engine settings. Source snippets leave this Mac only when you press Generate, and only go to that endpoint."
        case .demo:
            return "A prewritten, deterministic test with a bundled fix. No AI runs and nothing is sent to a model."
        }
    }
}

enum ReproEngineState: Equatable {
    case starting
    case ready
    case offline(String)
}

let reproDemoBadgeText = "Demo: test is prewritten, not AI"

private extension String {
    var reproTrimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

@MainActor
final class ReproModel: ObservableObject {
    @Published var issue = ""
    @Published var repoPath = ""
    @Published var generator: ReproGenerator = .claudeCode
    @Published private(set) var engine: ReproEngineState = .starting
    @Published private(set) var job: ReproJob?
    @Published private(set) var requestInFlight = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    private var pollTask: Task<Void, Never>?

    var isDemo: Bool { generator == .demo }
    var isReady: Bool { engine == .ready }
    var repoMissing: Bool { !isDemo && repoPath.reproTrimmed.isEmpty }
    var issueMissing: Bool { !isDemo && issue.reproTrimmed.isEmpty }
    var jobIdle: Bool { !(job?.active ?? false) && !requestInFlight }

    var generateBlockReason: String? {
        if !isReady { return "Waiting for the local engine to start." }
        if job?.active == true { return "A job is running. Wait for it to finish." }
        if repoMissing { return "Choose a repository to generate a test." }
        if issueMissing { return "Describe the issue to generate a test." }
        return nil
    }

    var canGenerate: Bool { generateBlockReason == nil && !requestInFlight }

    func start() async {
        engine = .starting
        do {
            try await EngineClient.shared.ensureStarted()
            engine = .ready
        } catch {
            engine = .offline(error.localizedDescription)
        }
    }

    func generate() async {
        guard canGenerate else { return }
        requestInFlight = true
        errorMessage = nil
        notice = nil
        defer { requestInFlight = false }
        var body: [String: String] = ["provider": generator.rawValue]
        if !isDemo {
            body["repo_path"] = repoPath.reproTrimmed
            body["issue"] = issue.reproTrimmed
        }
        do {
            let acknowledgement: JobAcknowledgement = try await EngineClient.shared.request("/api/repro", method: "POST", body: body)
            let created: ReproJob = try await EngineClient.shared.request("/api/repro/\(acknowledgement.id)")
            adopt(created)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func verify() async {
        await runAction("verify")
    }

    func demoFix() async {
        await runAction("demo-fix")
    }

    func downloadEvidence() async {
        guard let current = job, current.download_available, !current.active else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "repro-\(current.id).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestInFlight = true
        defer { requestInFlight = false }
        do {
            let archive = try await EngineClient.shared.data("/api/repro/\(current.id)/download")
            try archive.write(to: url, options: .atomic)
            notice = "Saved evidence to \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyTest() {
        guard let current = job else { return }
        copyNative(current.test_code)
        notice = "Copied the generated test."
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the root of the Python repository to reproduce against."
        if panel.runModal() == .OK, let url = panel.url {
            repoPath = url.path
        }
    }

    func dismissMessages() {
        errorMessage = nil
        notice = nil
    }

    private func runAction(_ suffix: String) async {
        guard let current = job, jobIdle else { return }
        requestInFlight = true
        errorMessage = nil
        defer { requestInFlight = false }
        do {
            let _: JobAcknowledgement = try await EngineClient.shared.request("/api/repro/\(current.id)/\(suffix)", method: "POST", body: [:])
            let fresh: ReproJob = try await EngineClient.shared.request("/api/repro/\(current.id)")
            guard job?.id == current.id else { return }
            adopt(fresh)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Replaces the visible job and owns the single poll loop for it. Any previous loop is cancelled,
    // and responses for a job that is no longer current are ignored.
    private func adopt(_ fresh: ReproJob) {
        pollTask?.cancel()
        pollTask = nil
        job = fresh
        errorMessage = nil
        guard fresh.active else { return }
        let id = fresh.id
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.job?.id == id else { return }
                do {
                    let latest: ReproJob = try await EngineClient.shared.request("/api/repro/\(id)")
                    guard self.job?.id == id else { return }
                    self.job = latest
                    self.errorMessage = nil
                    if !latest.active { return }
                } catch {
                    guard self.job?.id == id else { return }
                    self.errorMessage = "Lost contact with the engine. Retrying… (\(error.localizedDescription))"
                }
            }
        }
    }
}

// MARK: - App delegate and window

@MainActor
final class ReproAppDelegate: NSObject, NSApplicationDelegate {
    let model = ReproModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "flask", accessibilityDescription: "Repro")
        item.button?.toolTip = "Repro — regression test workspace"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 370, height: 360)
        let controller = NSViewController()
        controller.view = nativeGlassHost(ReproQuickView(model: model) { [weak self] in
            self?.popover?.performClose(nil)
            self?.showWindow()
        }, size: popover.contentSize)
        popover.contentViewController = controller
        self.popover = popover
        Task { await model.start() }
        togglePopover()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    // Closing the window keeps the app in the Dock; clicking the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    private func showWindow() {
        if window == nil { makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Repro"
        window.contentMinSize = NSSize(width: 880, height: 600)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: ReproRootView(model: model))
        self.window = window
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Repro")
        appMenu.addItem(withTitle: "About Repro", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Repro", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Repro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu

        return mainMenu
    }
}

struct ReproQuickView: View {
    @ObservedObject var model: ReproModel
    let openWorkspace: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "flask.fill").font(.title2).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Repro").font(.title3.weight(.semibold))
                    Text("Catch it. Fix it. Prove it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Open Relay") { openSiblingApp("Relay") }
                    Button("Quit Repro") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 24)
                .accessibilityLabel("Repro actions")
            }
            Divider().opacity(0.5)
            if let job = model.job {
                VStack(alignment: .leading, spacing: 8) {
                    Label(job.status.capitalized, systemImage: job.status == "verified" ? "checkmark.seal.fill" : "waveform.path")
                        .font(.headline).foregroundStyle(job.status == "verified" ? .green : .indigo)
                    Text(job.demo ? "Prewritten demo test" : "Generated regression test").font(.callout)
                    Text(job.error ?? job.phase).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            } else {
                Text("Turn a bug report into a failing test.")
                    .font(.headline)
                Text("Review the test, fix your source, then verify the identical test in Docker.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: openWorkspace) {
                HStack { Text("Open Workspace"); Spacer(); Image(systemName: "arrow.up.right") }
                    .padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).tint(.indigo)
            Label(model.isReady ? "Local engine connected" : "Connecting to local engine", systemImage: "circle.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 370, height: 360)
    }
}

// MARK: - Root layout

struct ReproRootView: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(spacing: 0) {
            EngineStatusBar(model: model)
            HSplitView {
                GeneratorPanel(model: model)
                    .frame(minWidth: 340, idealWidth: 400, maxWidth: 480)
                InspectorPanel(model: model)
                    .frame(minWidth: 460, maxWidth: .infinity)
            }
        }
        .frame(minWidth: 880, minHeight: 600)
    }
}

struct EngineStatusBar: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        if model.engine != .ready {
            HStack(spacing: 10) {
                if model.engine == .starting {
                    ProgressView().controlSize(.small)
                    Text("Starting the local engine…")
                } else {
                    Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.red)
                    Text(offlineMessage).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("Retry") { Task { await model.start() } }
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var offlineMessage: String {
        if case let .offline(message) = model.engine { return message }
        return ""
    }
}

// MARK: - Left panel: inputs

struct GeneratorPanel: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repro").font(.largeTitle.weight(.bold))
                    Text("Reproduce a bug as a failing pytest test before you fix it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                PanelCard(title: "Issue", symbol: "text.bubble") {
                    IssueEditor(model: model)
                }
                PanelCard(title: "Repository", symbol: "folder") {
                    RepositoryField(model: model)
                }
                PanelCard(title: "Generator", symbol: "cpu") {
                    GeneratorChooser(model: model)
                }
                GenerateControls(model: model)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct IssueEditor: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        TextEditor(text: $model.issue)
            .font(.body)
            .frame(minHeight: 150)
            .overlay(alignment: .topLeading) {
                if model.issue.isEmpty {
                    Text("Describe the bug, e.g. \"checkout ignores expired discount codes\".")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct RepositoryField: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Path to a Python repository", text: $model.repoPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(model.isDemo)
                Button {
                    model.chooseRepository()
                } label: {
                    Label("Choose…", systemImage: "folder.badge.plus")
                }
                .disabled(model.isDemo)
            }
            Text(model.isDemo ? "Demo does not use a repository." : "Python and pytest projects only. Repro reads this folder and never writes to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct GeneratorChooser: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Generator", selection: $model.generator) {
                ForEach(ReproGenerator.allCases) { generator in
                    Text(generator.label).tag(generator)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(model.generator.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Docker is required. There is no host fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.isDemo {
                StatusPill(text: reproDemoBadgeText, color: .purple)
            }
        }
    }
}

struct GenerateControls: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await model.generate() }
            } label: {
                HStack(spacing: 6) {
                    if model.requestInFlight {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(model.isDemo ? "Run Demo Test" : "Generate Test")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.canGenerate)
            .keyboardShortcut(.return, modifiers: .command)

            if let reason = model.generateBlockReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                openSiblingApp("Relay")
            } label: {
                Label("Open Relay", systemImage: "arrow.up.forward.app")
            }
        }
    }
}

// MARK: - Right panel: inspector

struct InspectorPanel: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MessageBar(model: model)
            if let job = model.job {
                JobDetail(model: model, job: job)
            } else {
                EmptyInspector(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

struct MessageBar: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        if let text = model.errorMessage ?? model.notice {
            let isError = model.errorMessage != nil
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isError ? "exclamationmark.octagon.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? Color.red : Color.green)
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    model.dismissMessages()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
    }
}

struct EmptyInspector: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: model.requestInFlight ? "hourglass" : "flask")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(model.requestInFlight ? "Starting job…" : "No reproduction yet")
                .font(.title3.weight(.semibold))
            Text("Describe the issue, choose a repository and generator, then press Generate. Progress and results appear here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            if model.requestInFlight {
                ProgressView().controlSize(.small)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JobDetail: View {
    @ObservedObject var model: ReproModel
    let job: ReproJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                JobHeader(job: job)
                ProgressTimeline(job: job)
                if let error = job.error, !error.isEmpty {
                    ErrorCard(message: error)
                }
                ActionCard(model: model, job: job)
                TestCodeCard(model: model, job: job)
                EvidenceCard(title: "Baseline", symbol: "1.circle", evidence: job.baseline, pending: "Waiting for the baseline run.")
                EvidenceCard(title: "Verification", symbol: "2.circle", evidence: job.verification, pending: "Not verified yet.")
                EventsCard(events: job.events)
            }
            .padding(16)
        }
    }
}

struct JobHeader: View {
    let job: ReproJob

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reproduction").font(.title2.weight(.bold))
                Text("Job \(String(job.id.prefix(8)))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if job.demo {
                StatusPill(text: reproDemoBadgeText, color: .purple)
            }
            StatusPill(text: job.status, color: reproStatusColor(job.status))
        }
    }
}

struct ProgressTimeline: View {
    let job: ReproJob

    private let stages = ["Generate", "Baseline", "Review", "Verify"]

    // Index of the stage the backend phase string points at.
    private var reached: Int {
        if job.status == "verified" { return 4 }
        if job.status == "reproduced" { return 2 }
        let phase = job.phase.lowercased()
        if phase.contains("verif") { return 3 }
        if phase.contains("review") { return 2 }
        if phase.contains("baseline") { return 1 }
        return 0
    }

    var body: some View {
        PanelCard(title: "Progress", symbol: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(stages.indices, id: \.self) { index in
                        StageNode(label: stages[index], state: state(for: index))
                        if index < stages.count - 1 {
                            Rectangle()
                                .fill(index < reached ? Color.green.opacity(0.5) : Color.secondary.opacity(0.25))
                                .frame(height: 2)
                                .padding(.top, 8)
                        }
                    }
                }
                Text("Phase: \(job.phase)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func state(for index: Int) -> StageState {
        if job.active {
            if index < reached { return .done }
            return index == reached ? .current : .pending
        }
        if index < reached { return .done }
        if index == reached && job.status == "reproduced" { return .review }
        return .pending
    }
}

enum StageState: Equatable {
    case done
    case current
    case review
    case pending
}

struct StageNode: View {
    let label: String
    let state: StageState

    var body: some View {
        VStack(spacing: 4) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .current:
                    ProgressView().controlSize(.small)
                case .review:
                    Image(systemName: "eye.circle.fill").foregroundStyle(.orange)
                case .pending:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                }
            }
            .frame(height: 18)
            Text(label)
                .font(.caption.weight(state == .pending ? .regular : .semibold))
                .foregroundStyle(state == .pending ? Color.secondary : Color.primary)
        }
        .frame(width: 72)
    }
}

struct ActionCard: View {
    @ObservedObject var model: ReproModel
    let job: ReproJob

    var body: some View {
        PanelCard(title: "Next step", symbol: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 10) {
                if job.active {
                    Text("Running. This view updates every second.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if job.status == "reproduced" && !job.active {
                    if job.demo {
                        Text("Demo only: the prewritten test and its fix are bundled with Repro. Applying the fix verifies the demo, not your repository.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { await model.demoFix() }
                        } label: {
                            Label("Apply Demo Fix & Verify", systemImage: "bandage")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.requestInFlight)
                    } else {
                        Text("Review the generated oracle before trusting this result. The model wrote the assertion; the test failing on the current code only shows it disagrees with that code.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Fix the bug in your repository, then verify. Repro does not edit the source.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await model.verify() }
                        } label: {
                            Label("Verify After Source Fix", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.requestInFlight)
                    }
                }
                if job.download_available && !job.active {
                    Button {
                        Task { await model.downloadEvidence() }
                    } label: {
                        Label("Download Evidence (.zip)", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.requestInFlight)
                }
            }
        }
    }
}

struct TestCodeCard: View {
    @ObservedObject var model: ReproModel
    let job: ReproJob

    var body: some View {
        PanelCard(title: job.demo ? "Prewritten demo test" : "Generated test", symbol: "doc.text") {
            VStack(alignment: .trailing, spacing: 8) {
                ScrollView([.horizontal, .vertical]) {
                    Text(job.test_code.isEmpty ? "No test code yet." : job.test_code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 120, maxHeight: 320)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Button {
                    model.copyTest()
                } label: {
                    Label("Copy Test", systemImage: "doc.on.doc")
                }
                .disabled(job.test_code.isEmpty)
            }
        }
    }
}

struct EvidenceCard: View {
    let title: String
    let symbol: String
    let evidence: ReproEvidence?
    let pending: String

    var body: some View {
        PanelCard(title: title, symbol: symbol) {
            if let evidence = evidence {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        StatusPill(text: evidence.outcome ?? "unknown", color: .secondary)
                        if let code = evidence.exit_code {
                            Text("exit \(code)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let summary = evidence.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text(pending)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ErrorCard: View {
    let message: String

    // Short, specific next step for the failures users hit most often.
    private var hint: String? {
        let lower = message.lowercased()
        if lower.contains("docker") {
            return "Start Docker Desktop, confirm `docker info` works, then generate again. Repro has no host fallback."
        }
        if lower.contains("pytest") {
            return "Repro runs Python tests with pytest. Make sure the repository has a Python environment with pytest installed."
        }
        if lower.contains("endpoint") || lower.contains("api key") || lower.contains("auth") {
            return "Check the OpenAI-compatible endpoint and credentials in engine settings, then generate again."
        }
        if lower.contains("claude") {
            return "Check that Claude Code is installed and signed in, then generate again."
        }
        return nil
    }

    var body: some View {
        PanelCard(title: "Error", symbol: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = hint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button {
                    copyNative(message)
                } label: {
                    Label("Copy Error", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

struct EventsCard: View {
    let events: [ReproEvent]

    var body: some View {
        PanelCard(title: "Event timeline", symbol: "list.bullet.indent") {
            if events.isEmpty {
                Text("No events yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(event.type.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 84, alignment: .leading)
                            Text(event.message)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Small shared views

struct PanelCard<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.replacingOccurrences(of: "_", with: " ").uppercased())
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

func reproStatusColor(_ status: String) -> Color {
    switch status.lowercased() {
    case "reproduced", "passed", "verified", "done", "completed", "success":
        return .green
    case "queued", "running", "pending", "not_reproduced":
        return .orange
    case "failed", "error", "errored":
        return .red
    default:
        return .secondary
    }
}

let application = NSApplication.shared
// Top-level code runs on the main thread, so it is safe to create the main-actor delegate here.
let reproDelegate = MainActor.assumeIsolated { ReproAppDelegate() }
application.setActivationPolicy(.accessory)
application.delegate = reproDelegate
application.run()

