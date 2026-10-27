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
            return "Uses the OpenAI-compatible endpoint from environment configuration. Source snippets leave this Mac only when you press Generate, and only go to that endpoint."
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

// Text over this limit is flagged and blocks Generate. It is never cut off silently.
let reproIssueLimit = 12000

// The OpenAI-compatible generator reads these from the engine's process environment, so they must be
// set in the shell that starts the engine.
let reproEndpointEnvironmentHelp = "Needs RELAY_MODEL_BASE_URL and RELAY_MODEL_NAME. RELAY_MODEL_API_KEY is optional. Set them in the shell that starts the engine, then restart it."

extension ReproJob {
    // Stand-in for a job the engine acknowledged but has not described yet.
    static func acknowledged(id: String, status: String, demo: Bool) -> ReproJob {
        ReproJob(id: id, status: status, phase: "Waiting for the engine to report progress.", events: [], test_code: "", baseline: nil, verification: nil, error: nil, demo: demo, download_available: false)
    }

    // The same job after an action was accepted. Evidence stays until the next poll replaces it.
    func accepted(status: String, phase: String) -> ReproJob {
        ReproJob(id: id, status: status, phase: phase, events: events, test_code: test_code, baseline: baseline, verification: verification, error: nil, demo: demo, download_available: false)
    }
}

// Repro talks to the engine directly so a 404 (run gone after an engine restart) can be told apart from
// an unreachable engine. EngineClient still owns starting the engine.
enum ReproTransportError: LocalizedError {
    case http(status: Int, message: String)

    var errorDescription: String? {
        if case let .http(_, message) = self { return message }
        return nil
    }
}

private enum ReproTransport {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    static func data(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: EngineClient.shared.base) else {
            throw EngineError.message("Invalid engine request")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw EngineError.message("Invalid engine response") }
        guard (200..<300).contains(response.statusCode) else {
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = value?["detail"] as? String ?? value?["error"] as? String
            throw ReproTransportError.http(status: response.statusCode, message: detail ?? "Engine request failed (\(response.statusCode))")
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> T {
        let raw = try await data(path, method: method, body: body)
        return try JSONDecoder().decode(T.self, from: raw)
    }
}

// True when the engine no longer has the run, which happens after an engine restart.
private func reproRunMissing(_ error: Error) -> Bool {
    guard let transport = error as? ReproTransportError, case let .http(status, _) = transport else { return false }
    return status == 404
}

// True only when no job can exist: the engine answered with a 4xx rejection, or the connection was refused before
// the request was sent. Timeouts, dropped connections, 5xx answers, and unreadable replies may follow an accepted job.
private func reproJobCertainlyNotStarted(_ error: Error) -> Bool {
    if let transport = error as? ReproTransportError, case let .http(status, _) = transport { return (400..<500).contains(status) }
    return (error as? URLError)?.code == .cannotConnectToHost
}

// A symlink is rejected rather than followed, so the folder the engine reads is the one the user sees.
private func reproIsSymbolicLink(_ path: String) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
    return attributes[.type] as? FileAttributeType == .typeSymbolicLink
}

// MARK: - Source snapshot

// Repro copies the Python source it tests into a private temporary folder. The engine is a separate process without
// the folder grant the picker gave Repro, so it only reads that copy. Limits and skip rules match the engine's own
// copy step in relay/repro.py.
enum ReproSnapshotError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

// One private copy of the selected source, plus the picker grant that makes the original readable. Dropping the last
// reference deletes the copy and ends the grant, so a replaced or failed snapshot cleans up after itself.
final class NativeSourceSnapshot: @unchecked Sendable {
    private static let maxFiles = 100
    private static let maxFileBytes = 1_000_000
    private static let maxTotalBytes = 2_000_000
    private static let maxEntries = 2000
    private static let excludedNames: Set<String> = [".git", ".venv", "venv", "node_modules", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"]

    let originalURL: URL
    let stagingURL: URL
    private let holdsScope: Bool
    // Set when the engine may have started a job from this copy. The copy then stays until the daily prune.
    private(set) var keptForPrune = false

    var sourceName: String { originalURL.lastPathComponent }

    private init(originalURL: URL, stagingURL: URL, holdsScope: Bool) {
        self.originalURL = originalURL
        self.stagingURL = stagingURL
        self.holdsScope = holdsScope
    }

    deinit {
        if !keptForPrune { try? FileManager.default.removeItem(at: stagingURL) }
        if holdsScope { originalURL.stopAccessingSecurityScopedResource() }
    }

    func keepForPrune() { keptForPrune = true }

    // Freezes the folder and makes the first copy. The walk runs off the main actor so the window stays responsive.
    static func make(from originalURL: URL, keeping current: URL?) async throws -> NativeSourceSnapshot {
        try await Task.detached(priority: .userInitiated) {
            let staging = try makeStagingDirectory(keeping: current)
            let snapshot = NativeSourceSnapshot(originalURL: originalURL, stagingURL: staging, holdsScope: originalURL.startAccessingSecurityScopedResource())
            // A failed copy releases this snapshot on the way out, and its deinit removes the partial folder.
            try snapshot.refresh()
            return snapshot
        }.value
    }

    // Replaces the copy with a fresh read of the same original folder. Verify uses this so the engine's fingerprint
    // check sees edits made since Generate. The path field is never read here.
    func refresh() throws {
        let fm = FileManager.default
        do {
            for item in try fm.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil, options: []) {
                try fm.removeItem(at: item)
            }
        } catch {
            throw ReproSnapshotError.message("Repro could not clear its private source copy. Try again.")
        }
        try copySources()
    }

    // Symbolic links are never followed or copied, and a symbolic link as the root is refused, as in the engine.
    private func copySources() throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let root = try? originalURL.resourceValues(forKeys: Set(keys))
        guard root?.isSymbolicLink != true else {
            throw ReproSnapshotError.message("Symbolic links are not accepted. Use the real folder path instead.")
        }
        guard root?.isDirectory == true else {
            throw ReproSnapshotError.message("Repro cannot open \(sourceName). Choose the folder again with Choose….")
        }
        var pending: [(url: URL, relative: [String])] = [(originalURL, [])]
        var entries = 0
        var files = 0
        var total = 0
        while let folder = pending.popLast() {
            let items: [URL]
            do {
                items = try fm.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: keys, options: [])
            } catch {
                throw ReproSnapshotError.message("Repro could not read a folder inside \(sourceName). Check that it is readable, then try again.")
            }
            for item in items {
                entries += 1
                guard entries <= Self.maxEntries else {
                    throw ReproSnapshotError.message("\(sourceName) has more than \(Self.maxEntries) entries. Point Repro at the package folder instead.")
                }
                let name = item.lastPathComponent
                guard !name.hasPrefix("."), !Self.excludedNames.contains(name) else { continue }
                let values = try? item.resourceValues(forKeys: Set(keys))
                guard values?.isSymbolicLink != true else { continue }
                if values?.isDirectory == true {
                    pending.append((item, folder.relative + [name]))
                    continue
                }
                guard values?.isRegularFile == true, item.pathExtension == "py" else { continue }
                // Files over the size limit are skipped, as in the engine. Too many files or bytes stop the copy.
                let size = values?.fileSize ?? 0
                guard size <= Self.maxFileBytes else { continue }
                files += 1
                total += size
                guard files <= Self.maxFiles, total <= Self.maxTotalBytes else {
                    throw ReproSnapshotError.message("\(sourceName) has more Python source than Repro can copy (100 files or 2 MB). Point Repro at the package folder instead.")
                }
                do {
                    let directory = folder.relative.reduce(stagingURL) { $0.appendingPathComponent($1, isDirectory: true) }
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                    try fm.copyItem(at: item, to: directory.appendingPathComponent(name))
                } catch {
                    throw ReproSnapshotError.message("Repro could not copy \(name). Check that it is readable, then try again.")
                }
            }
        }
        guard files > 0 else {
            throw ReproSnapshotError.message("\(sourceName) has no Python source files Repro can copy.")
        }
    }

    // A new folder for one copy, inside the app's temporary folder and outside Documents. Only this user can read it.
    private static func makeStagingDirectory(keeping current: URL?) throws -> URL {
        let fm = FileManager.default
        let privateMode: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        let parent = fm.temporaryDirectory.appendingPathComponent("Repro-Sources", isDirectory: true)
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: privateMode)
            pruneStale(in: parent, keeping: current)
            let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: privateMode)
            return directory
        } catch {
            throw ReproSnapshotError.message("Repro could not create a private folder for the source copy. Check free disk space, then try again.")
        }
    }

    // Removes copies a day old or more, such as ones left behind by a crash. The copy this app still holds is kept.
    private static func pruneStale(in parent: URL, keeping current: URL?) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        let items = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        for item in items where item.path != current?.path {
            let modified = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: item) }
        }
    }
}

// MARK: - Test runner

// The engine sets docker_available only when Docker answers and relay-repro:local exists, so it is the runner readiness.
struct ReproHealth: Decodable {
    let docker_available: Bool
}

enum ReproRunnerError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

// Builds relay-repro:local from the fixed scripts/Dockerfile.repro. It runs only when the parent presses Prepare Runner or
// Rebuild Runner, never at launch or Generate. The build uses Docker's cache and deletes no images. No host tests run here.
enum ReproRunnerBuild {
    static let imageTag = "relay-repro:local"
    static let timeout: TimeInterval = 120
    private static let outputLimit = 8_192
    private static let dockerfileLimit = 16_384

    // Keeps only the newest output, so a chatty build cannot grow memory. It is read to pick a message and never shown or logged.
    private final class BoundedOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var tail = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            tail.append(chunk)
            if tail.count > ReproRunnerBuild.outputLimit { tail.removeFirst(tail.count - ReproRunnerBuild.outputLimit) }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: tail, as: UTF8.self).lowercased()
        }
    }

    // Blocking. Call it from Task.detached so the window stays responsive. Throws a short message the UI can show.
    static func run() throws {
        guard let docker = dockerExecutable() else {
            throw ReproRunnerError.message("Docker was not found. Install Docker Desktop, start it, then press Prepare Runner again.")
        }
        let context = try makePrivateContext(with: try dockerfileContents())
        defer { try? FileManager.default.removeItem(at: context) }

        let output = BoundedOutput()
        let pipe = Pipe()
        // The pipe is drained as output arrives, so a full pipe can never stall the build.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { output.append(chunk) }
        }
        let process = Process()
        process.executableURL = docker
        process.arguments = ["build", "--tag", imageTag, "--file", context.appendingPathComponent("Dockerfile.repro").path, context.path]
        process.currentDirectoryURL = context
        process.environment = buildEnvironment()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw ReproRunnerError.message("Docker could not start the build. Start Docker Desktop then retry.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                process.terminate()
                pipe.fileHandleForReading.readabilityHandler = nil
                throw ReproRunnerError.message("Runner build timed out after 2 minutes. Start Docker Desktop, make sure the network is available, then retry.")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            let text = output.text
            if text.contains("cannot connect to the docker daemon") || text.contains("docker desktop") || text.contains("is the docker daemon running") {
                throw ReproRunnerError.message("Start Docker Desktop then retry.")
            }
            throw ReproRunnerError.message("Runner build failed; retry with network available.")
        }
    }

    // The CLI is found at fixed locations only. A GUI launch has no shell PATH, so nothing is searched.
    static func dockerExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".docker/bin/docker"),
            URL(fileURLWithPath: "/usr/local/bin/docker"),
            URL(fileURLWithPath: "/opt/homebrew/bin/docker"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // The Dockerfile bundled in the app first, then the repository copy for development builds.
    private static func dockerfileContents() throws -> Data {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Dockerfile.repro"))
        }
        if let file = Bundle.main.url(forResource: "backend-path", withExtension: "txt"),
           let raw = try? String(contentsOf: file, encoding: .utf8) {
            let root = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            candidates.append(root.appendingPathComponent("scripts/Dockerfile.repro"))
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            guard let data = try? Data(contentsOf: candidate), data.count <= dockerfileLimit else {
                throw ReproRunnerError.message("The runner Dockerfile could not be read. Reinstall the complete app bundle.")
            }
            return data
        }
        throw ReproRunnerError.message("The runner Dockerfile is missing from this app. Reinstall the complete app bundle.")
    }

    // A new folder holding only the Dockerfile, so the build sends Docker nothing else. The caller deletes it.
    private static func makePrivateContext(with dockerfile: Data) throws -> URL {
        let fm = FileManager.default
        let context = fm.temporaryDirectory.appendingPathComponent("Repro-Runner-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: context, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try dockerfile.write(to: context.appendingPathComponent("Dockerfile.repro"), options: .atomic)
        } catch {
            try? fm.removeItem(at: context)
            throw ReproRunnerError.message("Repro could not prepare the runner build folder. Check free disk space, then try again.")
        }
        return context
    }

    // A small environment: the PATH matches the engine's so credential helpers resolve, and only Docker settings are passed through.
    private static func buildEnvironment() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = ProcessInfo.processInfo.environment
        var env = [
            "PATH": home + "/.local/bin:" + home + "/.docker/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home,
        ]
        for key in ["DOCKER_CONFIG", "DOCKER_CONTEXT", "DOCKER_HOST"] {
            if let value = inherited[key] { env[key] = value }
        }
        return env
    }
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
    // The frozen copy the current real job tests against. A new accepted job replaces it, which deletes the old copy.
    @Published private(set) var snapshot: NativeSourceSnapshot?
    @Published private(set) var preparingSource = false
    // Whether the engine can run tests: Docker answers and relay-repro:local exists. Nil until a check succeeds, and Generate waits for true.
    @Published private(set) var runnerReady: Bool?
    @Published private(set) var setupBusy = false
    @Published private(set) var setupMessage: String?
    // The picker's URL carries the folder grant. A typed path has no grant and is used as typed.
    private var pickedRepositoryURL: URL?
    // The single poll loop for the tracked job. Starting a new loop cancels the previous one.
    private var pollTask: Task<Void, Never>?

    var isDemo: Bool { generator == .demo }
    var isOffline: Bool { if case .offline = engine { return true }; return false }
    var jobActive: Bool { job?.active ?? false }
    var jobIdle: Bool { !jobActive && !requestInFlight }

    var issueCharacterCount: Int { issue.reproTrimmed.count }
    var issueOverLimit: Bool { !isDemo && issueCharacterCount > reproIssueLimit }

    // The repository path as sent to the engine: whitespace trimmed and "~" expanded.
    var resolvedRepoPath: String { NSString(string: repoPath.reproTrimmed).expandingTildeInPath }

    // The folder to copy from, frozen when Generate is pressed. The picker's URL is used only if it still matches the path field.
    private var repositoryOriginURL: URL {
        let typed = URL(fileURLWithPath: resolvedRepoPath).standardizedFileURL
        if let picked = pickedRepositoryURL, picked.standardizedFileURL.path == typed.path { return picked }
        return typed
    }

    // Why the typed repository cannot be used, or nil when it can.
    var repoProblem: String? {
        guard !isDemo else { return nil }
        let path = resolvedRepoPath
        if path.isEmpty { return "Choose or type the path to a Python repository." }
        if reproIsSymbolicLink(path) { return "Symbolic links are not accepted. Use the real folder path instead." }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return "No folder exists at that path. Check the spelling, or pick the folder with Choose…."
        }
        guard isDirectory.boolValue else { return "That path is a file. Choose the repository folder instead." }
        return nil
    }

    var issueProblem: String? {
        guard !isDemo else { return nil }
        if issueCharacterCount == 0 { return "Describe the issue to generate a test." }
        if issueOverLimit {
            return "The issue is \(issueCharacterCount - reproIssueLimit) characters over the \(reproIssueLimit)-character limit. Shorten it; Repro never cuts text off silently."
        }
        return nil
    }

    var generateBlockReason: String? {
        switch engine {
        case .starting: return "Waiting for the local engine to start."
        case .offline: return "The local engine is offline. Use Retry Now above to reconnect."
        case .ready: break
        }
        if jobActive { return "A job is running. Wait for it to finish." }
        if setupBusy { return "Runner setup is running. Wait for it to finish." }
        if runnerReady == nil { return "Checking the test runner." }
        if runnerReady == false { return "The test runner is not ready. Prepare Runner in the Test runner card first." }
        return repoProblem ?? issueProblem
    }

    var canGenerate: Bool { generateBlockReason == nil && !requestInFlight }

    func start() async {
        engine = .starting
        do {
            try await EngineClient.shared.ensureStarted()
            engine = .ready
        } catch {
            engine = .offline(error.localizedDescription)
            runnerReady = nil
            return
        }
        await checkRunner()
    }

    // Reads docker_available from the engine. If the engine cannot answer, readiness is unknown and the engine goes offline,
    // so Retry Now is the way back. It is never reported as a missing runner.
    func checkRunner() async {
        do {
            runnerReady = try await ReproTransport.decode(ReproHealth.self, "/api/health").docker_available
        } catch {
            runnerReady = nil
            engine = .offline("Could not read the runner status. \(error.localizedDescription)")
        }
    }

    // Check Again reconnects and reads the status. It never starts a build.
    func checkAgain() {
        Task { await start() }
    }

    // Prepare Runner and Rebuild Runner. Only these buttons build the image. Launch and Generate never do.
    func buildRunner() async {
        guard !setupBusy, !jobActive else { return }
        setupBusy = true
        setupMessage = "Building the runner image. The first build can take a few minutes."
        defer { setupBusy = false }
        do {
            try await Task.detached(priority: .userInitiated) { try ReproRunnerBuild.run() }.value
        } catch {
            setupMessage = error.localizedDescription
            return
        }
        setupMessage = "Runner built. Checking it now."
        await start()
        setupMessage = runnerReady == true
            ? "Runner ready. Generate can run tests."
            : "Runner built, but it is not ready yet. Check that Docker Desktop is running, then press Check Again."
    }

    // Retry Now. Without an active job this is a plain engine start. With one, it restarts the single poll
    // loop for that same job, so Retry never creates a new run.
    func retryEngine() {
        guard jobActive else {
            Task { await start() }
            return
        }
        engine = .starting
        startPolling(reconnecting: true)
    }

    func generate() async {
        guard canGenerate else { return }
        requestInFlight = true
        errorMessage = nil
        notice = nil
        defer { requestInFlight = false; preparingSource = false }
        var body: [String: String] = ["provider": generator.rawValue]
        // Real runs test a private copy of the folder, so the engine never needs the picker's grant. The copy is kept
        // only if the engine accepts the job. A failure before the request is sent releases it and deletes it. A failure
        // after the request may have started the engine's copy step, so the copy is kept until the daily prune.
        var copy: NativeSourceSnapshot?
        if !isDemo {
            preparingSource = true
            do {
                let prepared = try await NativeSourceSnapshot.make(from: repositoryOriginURL, keeping: snapshot?.stagingURL)
                copy = prepared
                body["repo_path"] = prepared.stagingURL.path
            } catch {
                errorMessage = "Could not prepare the source: \(error.localizedDescription) Check the folder, then press Generate again."
                return
            }
            preparingSource = false
            body["issue"] = issue.reproTrimmed
        }
        let acknowledgement: JobAcknowledgement
        do {
            acknowledgement = try await ReproTransport.decode(JobAcknowledgement.self, "/api/repro", method: "POST", body: body)
        } catch {
            if reproJobCertainlyNotStarted(error) {
                errorMessage = "Could not start the reproduction: \(error.localizedDescription) Check the engine status above, then press Generate again."
            } else {
                copy?.keepForPrune()
                errorMessage = "Could not confirm whether the run started; check connection before generating again. If it did start, it may still be using the model."
            }
            return
        }
        // The engine has accepted the job. Keep its ID even if the next GET fails, and let polling own it so
        // Generate stays disabled until the job finishes.
        job = ReproJob.acknowledged(id: acknowledgement.id, status: acknowledgement.status, demo: isDemo)
        // The new copy replaces the previous job's copy, which is deleted when it is released. Demo runs have none.
        snapshot = copy
        startPolling(reconnecting: false)
    }

    func verify() async {
        guard jobIdle, let source = snapshot else { return }
        await runAction("verify", refreshing: source)
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
        // Cancelling the panel returns before any state changes, so no control stays disabled.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestInFlight = true
        defer { requestInFlight = false }
        let archive: Data
        do {
            archive = try await ReproTransport.data("/api/repro/\(current.id)/download")
        } catch {
            if reproRunMissing(error) { runUnavailable() } else { errorMessage = "Could not fetch the evidence: \(error.localizedDescription) Check the engine status above, then try again." }
            return
        }
        do {
            try archive.write(to: url, options: .atomic)
            errorMessage = nil
            notice = "Saved evidence to \(url.lastPathComponent)."
        } catch {
            errorMessage = "Could not save to \(url.path): \(error.localizedDescription) Choose a folder you can write to, then try again."
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
            pickedRepositoryURL = url
        }
    }

    func dismissMessages() {
        errorMessage = nil
        notice = nil
    }

    private func runAction(_ suffix: String, refreshing source: NativeSourceSnapshot? = nil) async {
        guard let current = job, jobIdle else { return }
        requestInFlight = true
        errorMessage = nil
        defer { requestInFlight = false; preparingSource = false }
        if let source {
            // Re-read the same frozen folder so the engine's fingerprint check sees the edits made since Generate.
            preparingSource = true
            do {
                try await Task.detached(priority: .userInitiated) { try source.refresh() }.value
            } catch {
                errorMessage = "Could not refresh the source copy: \(error.localizedDescription) Check the folder, then press Verify again."
                return
            }
            preparingSource = false
        }
        do {
            let acknowledgement = try await ReproTransport.decode(JobAcknowledgement.self, "/api/repro/\(current.id)/\(suffix)", method: "POST", body: [:])
            guard job?.id == current.id else { return }
            // Accepted means the job is running. Poll from here, even if the first GET fails.
            job = current.accepted(status: acknowledgement.status, phase: "Accepted \(suffix); waiting for progress.")
            startPolling(reconnecting: false)
        } catch {
            if reproRunMissing(error) {
                runUnavailable()
            } else if reproJobCertainlyNotStarted(error) {
                errorMessage = error.localizedDescription
            } else {
                // The action may have started before the connection failed. Poll the known job instead of posting again.
                // The error stays until a fetched result replaces the job or the user dismisses it.
                errorMessage = "Could not confirm whether the action started: \(error.localizedDescription) Checking run status now; wait for the run to finish before trying again."
                startPolling(reconnecting: true)
            }
        }
    }

    // Starts the single poll loop for the tracked job and cancels any earlier one. The first fetch runs
    // immediately. A failed fetch moves the engine offline and backs off 1, 2, 4, then 8 seconds. A
    // successful fetch restores ready. The loop ends when the job finishes or the engine no longer has it.
    private func startPolling(reconnecting: Bool) {
        pollTask?.cancel()
        guard let id = job?.id else { return }
        pollTask = Task { [weak self] in
            var reconnect = reconnecting
            var backoff: UInt64 = 1
            while !Task.isCancelled {
                guard let self, self.job?.id == id else { return }
                var pause: UInt64 = 1
                do {
                    if reconnect { try await EngineClient.shared.ensureStarted() }
                    let latest = try await ReproTransport.decode(ReproJob.self, "/api/repro/\(id)")
                    guard !Task.isCancelled, self.job?.id == id else { return }
                    self.job = latest
                    self.engine = .ready
                    reconnect = false
                    backoff = 1
                    if !latest.active { return }
                } catch {
                    guard !Task.isCancelled, self.job?.id == id else { return }
                    if reproRunMissing(error) {
                        self.runUnavailable()
                        return
                    }
                    reconnect = true
                    pause = backoff
                    backoff = min(backoff * 2, 8)
                    self.engine = .offline("Lost contact with the engine: \(error.localizedDescription) Retrying in \(pause)s.")
                }
                try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
            }
        }
    }

    // The engine no longer knows this run, usually because it restarted. Drop the run instead of polling it
    // forever or showing a status the engine never confirmed. Generate is available again.
    private func runUnavailable() {
        pollTask?.cancel()
        job = nil
        engine = .ready
        errorMessage = "Run unavailable after engine restart; start a new reproduction."
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
        popover.contentSize = NSSize(width: 370, height: 400)
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
        else {
            // Menu commands can arrive while another app is frontmost; activating lets the panel take focus.
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Same as Relay: an accessory app's popover can show without becoming key, so make it key explicitly.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // The app runs with the accessory activation policy, so it has no Dock icon. Closing the window keeps it
    // running in the menu bar. The menu bar panel, Window > Show Workspace, or launching the app again reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
        } else if popover?.isShown != true {
            togglePopover()
        }
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

    @objc private func showWorkspace() {
        showWindow()
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
        windowMenu.addItem(.separator())
        // Shift-Command-Space opens the menu bar panel from the keyboard, so it can be used without the status item.
        let panelItem = NSMenuItem(title: "Show Menu Bar Panel", action: #selector(togglePopover), keyEquivalent: " ")
        panelItem.keyEquivalentModifierMask = [.command, .shift]
        panelItem.target = self
        windowMenu.addItem(panelItem)
        let workspaceItem = NSMenuItem(title: "Show Workspace", action: #selector(showWorkspace), keyEquivalent: "")
        workspaceItem.target = self
        windowMenu.addItem(workspaceItem)
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
            engineStatus
            if model.runnerReady == false {
                Label("Test runner needs setup. Open Workspace to prepare it.", systemImage: "shippingbox")
                    .font(.caption).foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if let job = model.job {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.isOffline ? "\(job.status.capitalized) (last known)" : job.status.capitalized, systemImage: job.status == "verified" ? "checkmark.seal.fill" : "waveform.path")
                        .font(.headline).foregroundStyle(job.status == "verified" ? .green : .indigo)
                    Text(job.demo ? "Prewritten demo test" : "Generated regression test").font(.callout)
                    Text(job.error ?? job.phase).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                Text("No reproduction yet.")
                    .font(.headline)
                Text("Turn a bug report into a failing test, fix your source, then verify it in Docker.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: openWorkspace) {
                HStack { Text("Open Workspace"); Spacer(); Image(systemName: "arrow.up.right") }
                    .padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).tint(.indigo)
        }
        .padding(22)
        .frame(width: 370, height: 400)
    }

    // Live engine state. Offline shows the reason and a Retry Now control.
    @ViewBuilder private var engineStatus: some View {
        switch model.engine {
        case .starting:
            Label("Connecting to the local engine…", systemImage: "circle.dotted")
                .font(.caption).foregroundStyle(.secondary)
        case .ready:
            Label("Local engine connected", systemImage: "circle.fill")
                .font(.caption).foregroundStyle(.green)
        case let .offline(message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Local engine offline", systemImage: "bolt.horizontal.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.red)
                Text(message).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Button("Retry Now") { model.retryEngine() }.controlSize(.small)
            }
        }
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
                    Text(model.jobActive ? "Reconnecting to the local engine…" : "Starting the local engine…")
                } else {
                    Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.jobActive ? "Engine offline. Your job is still tracked." : "Engine offline.")
                            .font(.callout.weight(.semibold))
                        Text(offlineMessage).font(.caption).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Retry Now") { model.retryEngine() }
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
                PanelCard(title: "Test runner", symbol: "shippingbox") {
                    RunnerCard(model: model)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                GenerateControls(model: model).padding(16)
            }
            .background(.bar)
        }
    }
}

// Runner readiness and the explicit setup actions. Generate waits for this to read ready, so no model credit is spent on a
// run Docker cannot execute.
struct RunnerCard: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine
            if model.runnerReady == false && !model.setupBusy {
                Text("Docker Desktop must be running. Prepare Runner builds the bundled public Python and pytest image. The initial download requires network access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                if model.runnerReady == true {
                    Button {
                        Task { await model.buildRunner() }
                    } label: {
                        Label("Rebuild Runner", systemImage: "hammer")
                    }
                    .disabled(model.setupBusy || model.jobActive)
                } else {
                    Button {
                        Task { await model.buildRunner() }
                    } label: {
                        Label("Prepare Runner", systemImage: "shippingbox")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(model.setupBusy || model.jobActive)
                }
                Button("Check Again") { model.checkAgain() }
                    .disabled(model.setupBusy)
            }
            if let message = model.setupMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if model.setupBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Building the runner image…").font(.callout)
            }
        } else {
            switch model.runnerReady {
            case true?:
                Label("Ready", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
            case false?:
                Label("Needs setup", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            case nil:
                Label("Checking…", systemImage: "circle.dotted")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct IssueEditor: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $model.issue)
                .font(.body)
                .frame(height: 120)
                .overlay(alignment: .topLeading) {
                    if model.issue.isEmpty {
                        Text("Describe the bug, e.g. \"checkout ignores expired discount codes\".")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            if !model.isDemo {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if model.issueOverLimit, let problem = model.issueProblem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text("\(model.issueCharacterCount) of \(reproIssueLimit) characters")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.issueOverLimit ? Color.red : Color.secondary)
                }
            }
        }
    }
}

struct RepositoryField: View {
    @ObservedObject var model: ReproModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Path to a Python repository, e.g. ~/code/app", text: $model.repoPath)
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
            if model.isDemo {
                Text("Demo does not use a repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let problem = model.repoProblem, !model.repoPath.reproTrimmed.isEmpty {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Python and pytest projects only. Repro reads this folder and never writes to it. A leading ~ is expanded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            if model.generator == .openAICompatible {
                Text(reproEndpointEnvironmentHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    Text(model.preparingSource ? "Preparing source…" : model.isDemo ? "Run Demo Test" : "Generate Test")
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
            Text(model.preparingSource ? "Preparing source…" : model.requestInFlight ? "Starting job…" : "No reproduction yet")
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
                if !job.demo, let snapshot = model.snapshot {
                    Text("Tested against a frozen copy of \(snapshot.sourceName), taken when you pressed Generate. Verify re-reads that folder, not the path field. Only Python files are copied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        if job.verification != nil { return 3 }
        if job.baseline != nil { return 2 }
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
        if index == reached && job.status == "error" { return .failed }
        if index == reached && job.status == "reproduced" { return .review }
        return .pending
    }
}

enum StageState: Equatable {
    case done
    case failed
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
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
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
                    Text("Running. Progress refreshes automatically while the engine is reachable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !job.active && (job.status == "reproduced" ||
                    (job.status == "error" && job.baseline?.outcome == "assertion_failure")) {
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
                            Label(model.preparingSource ? "Preparing source…" : "Verify After Source Fix", systemImage: "checkmark.circle")
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
            return "Check RELAY_MODEL_BASE_URL, RELAY_MODEL_NAME and RELAY_MODEL_API_KEY in the engine's environment configuration, restart the engine, then generate again."
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

