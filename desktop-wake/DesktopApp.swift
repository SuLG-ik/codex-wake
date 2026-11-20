import AppKit

private struct RuntimePackage: Decodable {
    let version: String
}

private struct LauncherError: LocalizedError {
    let description: String
    var showsDownloads = false
    var errorDescription: String? { description }
}

final class DesktopApp: NSObject, NSApplicationDelegate {
    private let workspace = NSWorkspace.shared
    private let files = FileManager.default
    private var desktop: NSRunningApplication?
    private var menu: Process?
    private var sessionDirectory: URL?
    private var monitor: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let resources = Bundle.main.resourceURL else {
                throw LauncherError(description: "The application bundle is incomplete. Extract Codex Wake.app again.")
            }
            let runtime = resources.appendingPathComponent("runtime", isDirectory: true)
            let desktopPath = ProcessInfo.processInfo.environment["CODEX_WAKE_APP"] ?? "/Applications/ChatGPT.app"
            let desktopURL = URL(fileURLWithPath: desktopPath, isDirectory: true)
            guard let desktopBundle = Bundle(url: desktopURL), let desktopID = desktopBundle.bundleIdentifier else {
                throw LauncherError(description: "Install ChatGPT Desktop in Applications, then open Codex Wake again.")
            }
            try checkVersion(runtime: runtime, desktopURL: desktopURL)
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: desktopID).first(where: { !$0.isTerminated }) {
                askToQuit(running, runtime: runtime, resources: resources, desktopURL: desktopURL)
            } else {
                try launch(runtime: runtime, resources: resources, desktopURL: desktopURL)
            }
        } catch {
            fail(error)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        desktop?.activate(options: [.activateIgnoringOtherApps])
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        if let menu, menu.isRunning { menu.terminate() }
        if let sessionDirectory { try? files.removeItem(at: sessionDirectory) }
    }

    private func checkVersion(runtime: URL, desktopURL: URL) throws {
        let manifest = desktopURL.appendingPathComponent("Contents/Resources/codex-cli/codex-package.json")
        let bundled = try JSONDecoder().decode(RuntimePackage.self, from: Data(contentsOf: manifest))
        let expected = try String(contentsOf: runtime.appendingPathComponent("version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard expected == "codex-cli \(bundled.version)" else {
            throw LauncherError(description: "ChatGPT Desktop bundles Codex \(bundled.version). This Codex Wake build requires \(expected).", showsDownloads: true)
        }
    }

    private func askToQuit(_ running: NSRunningApplication, runtime: URL, resources: URL, desktopURL: URL) {
        let alert = NSAlert()
        alert.messageText = "ChatGPT Desktop is already open"
        alert.informativeText = "Quit it to start a session with Codex Wake. Save any work in progress first."
        alert.addButton(withTitle: "Quit ChatGPT and Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return
        }
        guard running.isTerminated || running.terminate() else {
            fail(LauncherError(description: "Quit ChatGPT Desktop, then open Codex Wake again."))
            return
        }
        let deadline = Date().addingTimeInterval(20)
        monitor = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if running.isTerminated {
                timer.invalidate()
                do { try self.launch(runtime: runtime, resources: resources, desktopURL: desktopURL) }
                catch { self.fail(error) }
            } else if Date() >= deadline {
                timer.invalidate()
                self.fail(LauncherError(description: "ChatGPT Desktop is still open. Quit it, then open Codex Wake again."))
            }
        }
    }

    private func launch(runtime: URL, resources: URL, desktopURL: URL) throws {
        var template = Array("/tmp/cxwake.XXXXXX".utf8CString)
        guard let session = mkdtemp(&template) else {
            throw LauncherError(description: "Could not create a private runtime directory.")
        }
        let sessionPath = String(cString: session)
        sessionDirectory = URL(fileURLWithPath: sessionPath, isDirectory: true)
        let node = resources.appendingPathComponent("node/bin/node")
        let bridge = runtime.appendingPathComponent("desktop-wake/bridge.mjs")

        let menu = Process()
        menu.executableURL = runtime.appendingPathComponent("BackgroundMenu")
        menu.arguments = [node.path, bridge.path, sessionPath, String(ProcessInfo.processInfo.processIdentifier)]
        try menu.run()
        self.menu = menu

        let config = NSWorkspace.OpenConfiguration()
        config.environment = ProcessInfo.processInfo.environment.merging([
            "CODEX_CLI_PATH": runtime.appendingPathComponent("desktop-wake/codex").path,
            "CODEX_APP_SERVER_FORCE_CLI": "1",
            "CODEX_WAKE_BINARY": runtime.appendingPathComponent("codex").path,
            "CODEX_WAKE_NODE": node.path,
            "CODEX_WAKE_SOCKET": sessionPath,
        ]) { _, bundledValue in bundledValue }
        workspace.openApplication(at: desktopURL, configuration: config) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let application {
                    self.desktop = application
                    self.monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                        if application.isTerminated { timer.invalidate(); NSApp.terminate(nil) }
                    }
                } else {
                    self.fail(error ?? LauncherError(description: "ChatGPT Desktop could not be opened."))
                }
            }
        }
    }

    private func fail(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Codex Wake could not start"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        if (error as? LauncherError)?.showsDownloads == true {
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "https://github.com/SuLG-ik/codex-wake/releases") {
                workspace.open(url)
            }
        } else {
            alert.runModal()
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = DesktopApp()
app.delegate = delegate
app.run()
