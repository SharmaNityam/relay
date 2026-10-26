import AppKit
import WebKit
import Foundation

private let relayBaseURL = URL(string: "http://127.0.0.1:9778")!

final class RelayApp: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var webView: WKWebView?
    private var backend: Process?
    private var pollTimer: Timer?
    private var sessions: [[String: Any]] = []
    private var snapshotCounts: [String: Int] = [:]
    private var lastError = ""
    private var backendPath: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        backendPath = readBackendPath()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "R • —"
        statusItem.button?.toolTip = "Relay — local agent session monitor"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(showMenu(_:))
        showDashboard()
        ensureBackendAndPoll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        if let process = backend, process.isRunning {
            process.terminate()
            backend = nil
        }
    }

    private func readBackendPath() -> URL? {
        guard let resource = Bundle.main.url(forResource: "backend-path", withExtension: "txt"),
              let raw = try? String(contentsOf: resource, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func showDashboard() {
        if window == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.allowsBackForwardNavigationGestures = false
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Relay — Session command center"
            window.minSize = NSSize(width: 740, height: 520)
            window.center()
            window.contentView = view
            self.window = window
            self.webView = view
            view.load(URLRequest(url: relayBaseURL))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showMenu(_ sender: Any?) {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Relay · \(sessions.count) sessions", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem(title: lastError.isEmpty ? "Local service connected" : "Local service unavailable", action: nil, keyEquivalent: "").also { item in
            item.isEnabled = false
        })
        menu.addItem(.separator())
        let needsAttention = sessions.filter { status(of: $0) == "waiting" || status(of: $0) == "failed" }
        let attentionHeader = NSMenuItem(title: "Needs attention · \(needsAttention.count)", action: nil, keyEquivalent: "")
        attentionHeader.isEnabled = false
        menu.addItem(attentionHeader)
        if needsAttention.isEmpty {
            let empty = NSMenuItem(title: "Nothing waiting for attention", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for session in needsAttention.prefix(5) { menu.addItem(sessionMenuItem(session)) }
        }
        menu.addItem(.separator())
        let recentHeader = NSMenuItem(title: "Recent sessions", action: nil, keyEquivalent: "")
        recentHeader.isEnabled = false
        menu.addItem(recentHeader)
        let recent = sessions.sorted { timestamp(of: $0) > timestamp(of: $1) }.prefix(6)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No session metadata available", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for session in recent { menu.addItem(sessionMenuItem(session)) }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Relay Dashboard", action: #selector(openDashboard(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh now", action: #selector(refreshNow(_:)), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Quit Relay", action: #selector(quit(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func sessionMenuItem(_ session: [String: Any]) -> NSMenuItem {
        let name = clean(session["alias"] as? String ?? session["display_name"] as? String ?? session["suggested_name"] as? String ?? session["title"] as? String ?? "Untitled session", limit: 62)
        let project = clean(session["project"] as? String ?? "Unknown project", limit: 30)
        let provider = clean(session["provider"] as? String ?? "unknown", limit: 14)
        let item = NSMenuItem(title: "\(name) · \(project)  [\(status(of: session))]", action: #selector(openSession(_:)), keyEquivalent: "")
        item.representedObject = session["key"] as? String ?? "\(provider):\(session["id"] as? String ?? "")"
        item.toolTip = "\(provider) · \(clean(session["last_activity"] as? String ?? "No observed activity", limit: 120))"
        item.target = self
        return item
    }

    private func ensureBackendAndPoll() {
        getJSON(path: "/api/health") { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.lastError = ""
                    self.beginPolling()
                case .failure:
                    self.launchBackendIfAvailable()
                    self.schedulePoll(after: 1.5)
                }
            }
        }
    }

    private func launchBackendIfAvailable() {
        guard backend == nil, let path = backendPath else {
            if backendPath == nil { lastError = "Backend path missing from app bundle" }
            return
        }
        let executable = path.appendingPathComponent(".venv/bin/relay")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            lastError = "Backend executable unavailable"
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve", "--port", "9778"]
        process.currentDirectoryURL = path
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.backend = nil
                self.lastError = "Local service stopped"
                self.updateMenuBar()
            }
        }
        do {
            try process.run()
            backend = process
            lastError = "Starting local service…"
        } catch {
            lastError = "Could not start local service"
        }
    }

    private func beginPolling() {
        pollTimer?.invalidate()
        fetchSnapshot()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.fetchSnapshot() }
    }

    private func schedulePoll(after delay: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.ensureBackendAndPoll() }
    }

    private func fetchSnapshot() {
        getJSON(path: "/api/sessions") { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let object):
                    let wasUnavailable = !self.lastError.isEmpty
                    self.sessions = object["sessions"] as? [[String: Any]] ?? []
                    self.snapshotCounts = object["counts"] as? [String: Int] ?? [:]
                    self.lastError = ""
                    if wasUnavailable { self.webView?.load(URLRequest(url: relayBaseURL)) }
                case .failure:
                    self.lastError = "Local service unavailable"
                }
                self.updateMenuBar()
            }
        }
    }

    private func getJSON(path: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var request = URLRequest(url: relayBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.timeoutInterval = 2.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(NSError(domain: "Relay", code: 1)))
                return
            }
            completion(.success(object))
        }.resume()
    }

    private func updateMenuBar() {
        let attention = sessions.filter { status(of: $0) == "waiting" || status(of: $0) == "failed" }.count
        statusItem.button?.title = "R • \(sessions.count)"
        statusItem.button?.toolTip = attention > 0 ? "Relay · \(sessions.count) sessions · \(attention) need attention" : "Relay · \(sessions.count) sessions"
    }

    private func status(of session: [String: Any]) -> String {
        let value = (session["status"] as? String ?? "unknown").lowercased()
        return ["running", "waiting", "completed", "failed", "interrupted", "stale", "unknown"].contains(value) ? value : "unknown"
    }

    private func timestamp(of session: [String: Any]) -> Date {
        guard let value = session["last_event_at"] as? String else { return .distantPast }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? .distantPast
    }

    private func clean(_ value: String, limit: Int) -> String {
        let sanitized = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        return String(sanitized.prefix(limit))
    }

    @objc private func openDashboard(_ sender: Any?) { showDashboard() }
    @objc private func refreshNow(_ sender: Any?) { fetchSnapshot() }
    @objc private func openSession(_ sender: NSMenuItem) { showDashboard() }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}

extension NSMenuItem {
    @discardableResult
    func also(_ configure: (NSMenuItem) -> Void) -> NSMenuItem {
        configure(self)
        return self
    }
}

let application = NSApplication.shared
let delegate = RelayApp()
application.delegate = delegate
application.run()
