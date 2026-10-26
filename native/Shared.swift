import Foundation
import AppKit
import SwiftUI

struct RelaySession: Decodable, Identifiable {
    let provider: String
    let id: String
    let key: String
    let title: String
    let display_name: String?
    let suggested_name: String?
    let task: String
    let project: String
    let cwd: String
    let parent_key: String?
    let role: String
    let model: String?
    let status: String
    let status_source: String
    let last_event_at: String?
    let last_activity: String
    let tokens: Int?
    var name: String { display_name ?? suggested_name ?? title }
    var identity: String { key }
}
struct ProviderHealth: Decodable, Identifiable {
    let id: String
    let status: String
    let message: String?
}
struct SessionSnapshot: Decodable {
    let sessions: [RelaySession]
    let providers: [ProviderHealth]
    let counts: [String: Int]
    let total: Int
}
struct ReproEvidence: Decodable {
    let outcome: String?
    let summary: String?
    let exit_code: Int?
}
struct ReproEvent: Decodable {
    let type: String
    let message: String
}
struct ReproJob: Decodable, Identifiable {
    let id: String
    let status: String
    let phase: String
    let events: [ReproEvent]
    let test_code: String
    let baseline: ReproEvidence?
    let verification: ReproEvidence?
    let error: String?
    let demo: Bool
    let download_available: Bool
    var active: Bool { ["queued", "running"].contains(status) }
}
struct JobAcknowledgement: Decodable {
    let id: String
    let status: String
}

enum EngineError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

// A local background engine is shared by both native clients. No HTML or WebKit.
final class EngineClient {
    static let shared = EngineClient()
    let base = URL(string: "http://127.0.0.1:9778")!
    private let session: URLSession
    private var process: Process?
    private var starting: Task<Void, Error>?
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        session = URLSession(configuration: config)
    }
    func ensureStarted() async throws {
        if (try? await data("/api/health")) != nil { return }
        if let starting { return try await starting.value }
        let task = Task<Void, Error> {
            guard let file = Bundle.main.url(forResource: "backend-path", withExtension: "txt"),
                  let raw = try? String(contentsOf: file, encoding: .utf8) else {
                throw EngineError.message("Engine location is missing. Rebuild the app from its checkout.")
            }
            let root = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let executable = root + "/.venv/bin/relay"
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw EngineError.message("Local engine is unavailable. Run uv sync in the checkout, then retry.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["serve", "--port", "9778"]
            process.currentDirectoryURL = URL(fileURLWithPath: root)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // GUI launches do not inherit a shell PATH; include installed tool locations.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            try process.run()
            self.process = process
            for _ in 0..<30 {
                if (try? await self.data("/api/health")) != nil { return }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw EngineError.message("The local engine did not start. Check the checkout and retry.")
        }
        starting = task
        defer { starting = nil }
        try await task.value
    }
    func data(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base) else { throw EngineError.message("Invalid engine request") }
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
            throw EngineError.message(value?["detail"] as? String ?? value?["error"] as? String ?? "Engine request failed (\(response.statusCode))")
        }
        return data
    }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil) async throws -> T {
        try await JSONDecoder().decode(T.self, from: data(path, method: method, body: body))
    }
    static func component(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

func copyNative(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

func openSiblingApp(_ name: String) {
    let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(name + ".app")
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
}

// Real system Liquid Glass on macOS 26+, native vibrancy on older supported Macs.
func nativeGlassHost<Content: View>(_ content: Content, size: NSSize) -> NSView {
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(origin: .zero, size: size)
    host.autoresizingMask = [.width, .height]
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: host.frame)
        glass.style = .regular
        glass.cornerRadius = 22
        glass.contentView = host
        return glass
    }
    let glass = NSVisualEffectView(frame: host.frame)
    glass.material = .popover
    glass.blendingMode = .behindWindow
    glass.state = .active
    glass.wantsLayer = true
    glass.layer?.cornerRadius = 18
    glass.addSubview(host)
    return glass
}
