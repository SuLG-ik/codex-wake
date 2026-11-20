import AppKit

struct RunningCommand: Decodable {
    let relay: String
    let threadId: String
    let turnId: String
    let itemId: String
    let processId: String
    let command: String
    let cwd: String
    let detached: Bool

    var arguments: [String] { [relay, threadId, turnId, itemId, processId] }
}

final class BackgroundMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let node: URL
    private let bridge: String
    private let socket: String
    private var launcherMonitor: Timer?
    private var launcherPID: Int32?

    init(node: String, bridge: String, socket: String, launcherPID: Int32?) {
        self.node = URL(fileURLWithPath: node)
        self.bridge = bridge
        self.socket = socket
        self.launcherPID = launcherPID
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        status.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex Background")
        status.button?.toolTip = "Codex Background"
        menu.delegate = self
        status.menu = menu
        if let launcherPID {
            launcherMonitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                if kill(launcherPID, 0) != 0 { NSApplication.shared.terminate(nil) }
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let loading = NSMenuItem(title: "Reading commands…", action: nil, keyEquivalent: "")
        menu.addItem(loading)
        request(["list"]) { [weak self] result in
            guard let self else { return }
            menu.removeAllItems()
            switch result {
            case .success(let data):
                let commands = (try? JSONDecoder().decode([RunningCommand].self, from: data)) ?? []
                if commands.isEmpty {
                    menu.addItem(NSMenuItem(title: "No running Codex commands", action: nil, keyEquivalent: ""))
                }
                for command in commands {
                    let preview = command.command.split(whereSeparator: \.isNewline).first ?? ""
                    let label = command.detached ? "In background" : "Move to background"
                    let item = NSMenuItem(title: "\(label)  ·  \(preview.prefix(66))",
                                          action: command.detached ? nil : #selector(detach(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.toolTip = command.cwd + "\n" + command.command
                    item.representedObject = command.arguments
                    menu.addItem(item)
                }
            case .failure:
                menu.addItem(NSMenuItem(title: "Waiting for Codex Desktop", action: nil, keyEquivalent: ""))
            }
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit Codex Background", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quit.target = NSApplication.shared
            menu.addItem(quit)
        }
    }

    @objc private func detach(_ sender: NSMenuItem) {
        guard let arguments = sender.representedObject as? [String] else { return }
        request(["detach"] + arguments) { result in
            if case .failure(let error) = result {
                let alert = NSAlert()
                alert.messageText = "Could not move the command to the background"
                alert.informativeText = error.localizedDescription
                NSApplication.shared.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func request(_ arguments: [String], done: @escaping (Result<Data, Error>) -> Void) {
        let node = self.node
        let prefix = [bridge, "control", socket]
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = node
            process.arguments = prefix + arguments
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            let result = Result {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    throw NSError(domain: "Codex Background", code: Int(process.terminationStatus),
                                  userInfo: [NSLocalizedDescriptionKey: message])
                }
                return data
            }
            DispatchQueue.main.async { done(result) }
        }
    }
}

let args = CommandLine.arguments
guard args.count == 5 else { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = BackgroundMenu(node: args[1], bridge: args[2], socket: args[3], launcherPID: Int32(args[4]))
app.delegate = delegate
app.run()
