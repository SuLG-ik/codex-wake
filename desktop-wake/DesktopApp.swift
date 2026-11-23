import AppKit
import UniformTypeIdentifiers

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
    private var desktopDriver: Process?
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
        if let url = desktop?.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.openApplication(at: url, configuration: configuration, completionHandler: nil)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.invalidate()
        if let desktopDriver, desktopDriver.isRunning { desktopDriver.terminate() }
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
        guard let desktopBundle = Bundle(url: desktopURL),
              let executable = desktopBundle.executableURL,
              let bundleID = desktopBundle.bundleIdentifier else {
            throw LauncherError(description: "ChatGPT Desktop has no executable.")
        }
        let driver = Process()
        driver.executableURL = node
        driver.arguments = [
            runtime.appendingPathComponent("desktop-wake/desktop-driver.mjs").path,
            executable.path,
            sessionPath,
        ]
        driver.environment = ProcessInfo.processInfo.environment.merging([
            "CODEX_CLI_PATH": runtime.appendingPathComponent("desktop-wake/codex").path,
            "CODEX_APP_SERVER_FORCE_CLI": "1",
            "CODEX_WAKE_BINARY": runtime.appendingPathComponent("codex").path,
            "CODEX_WAKE_NODE": node.path,
            "CODEX_WAKE_SOCKET": sessionPath,
        ]) { _, bundledValue in bundledValue }
        driver.terminationHandler = { [weak self] process in
            let failed = process.terminationStatus != 0
            DispatchQueue.main.async {
                if failed {
                    self?.fail(LauncherError(description: "ChatGPT Desktop closed unexpectedly."))
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
        desktopDriver = driver
        try driver.run()
        monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated }) {
                self.desktop = application
                timer.invalidate()
            }
        }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let shortcut = NSMenuItem(title: "Create Finder Alias…", action: #selector(saveAlias), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)
        return menu
    }

    @objc private func saveAlias() {
        let panel = NSSavePanel()
        panel.title = "Create Codex Wake Finder Alias"
        panel.allowedContentTypes = [.aliasFile]
        panel.nameFieldStringValue = "Codex Wake.alias"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try createFinderAlias(at: destination)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
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

private func createFinderAlias(at destination: URL) throws {
    let files = FileManager.default
    let target = Bundle.main.bundleURL
    guard target.pathExtension == "app", destination.pathExtension.lowercased() == "alias" else {
        throw LauncherError(description: "Choose a destination ending in .alias.")
    }
    let options: URL.BookmarkCreationOptions = [.suitableForBookmarkFile, .withoutImplicitSecurityScope]
    let bookmark = try target.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
    let temporary = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: destination.deletingLastPathComponent(), create: true)
    defer { try? files.removeItem(at: temporary) }
    var alias = temporary.appendingPathComponent("Codex Wake.alias")
    try URL.writeBookmarkData(bookmark, to: alias)
    var properties = URLResourceValues()
    properties.hasHiddenExtension = true
    try alias.setResourceValues(properties)
    let resolved = try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting])
    guard resolved.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path else {
        throw LauncherError(description: "Finder alias resolved to a different application.")
    }
    try files.moveItem(at: alias, to: destination)
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--create-alias" {
    do {
        try createFinderAlias(at: URL(fileURLWithPath: arguments[2]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = DesktopApp()
app.delegate = delegate
app.run()
