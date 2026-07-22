import AppKit
import ServiceManagement
import WebKit

let ctlPath = Bundle.main.path(forResource: "dev-screen-ctl", ofType: nil) ?? ""   // bundled in Contents/Resources

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var reachable = false
    var netActive = false                      // is the Tailscale network up? (shown before a machine is picked)
    var dimmed = false                         // best-effort: is the dev screen currently blacked out?
    var guideWindow: NSWindow?
    var sharing: Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSharing" } }

    // Selected dev machine (persisted to ~/.config/dev-screen/config, which dev-screen-ctl also reads).
    var devUser = "", devIP = "", devHost = ""
    var configured: Bool { !devUser.isEmpty && !devIP.isEmpty }
    var machineLabel: String { devHost.isEmpty ? (devIP.isEmpty ? "Dev Mac" : devIP) : devHost }
    var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dev-screen/config")
    }

    func loadConfig() {
        devUser = ""; devIP = ""; devHost = ""
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let val = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "DEV_USER": devUser = val
            case "DEV_IP":   devIP = val
            case "DEV_HOST": devHost = val
            default: break
            }
        }
    }

    func saveConfig() {
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "DEV_USER=\(devUser)\nDEV_IP=\(devIP)\nDEV_HOST=\(devHost)\n"
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self          // repopulated on each open
        statusItem.menu = menu
        loadConfig()
        applyIcon()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func applyIcon() {
        guard let button = statusItem.button else { return }
        if let img = NSImage(systemSymbolName: "display", accessibilityDescription: "Dev Screen") {
            img.isTemplate = true; button.image = img; button.title = ""
        } else { button.image = nil; button.title = "🖥" }
    }

    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh(); populate(menu) }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let headerTitle: String
        if !configured           { headerTitle = netActive ? "🟢 Tailscale network active" : "○ Tailscale network inactive" }
        else if sharing          { headerTitle = "🟢 \(machineLabel): connected" }
        else if reachable        { headerTitle = "🟢 \(machineLabel): online" }
        else                     { headerTitle = "○ \(machineLabel): offline" }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header)
        menu.addItem(.separator())

        if sharing {
            add(menu, "Stop Screen Share", #selector(stopShare))
        } else {
            add(menu, "Connect (Screen Share)", #selector(connect))
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let dm = add(sub, configured ? "Dev Machine: \(machineLabel)…" : "Dev Machine: not set…", #selector(changeMachine))
        dm.target = self
        sub.addItem(.separator())
        if dimmed { add(sub, "Restore Brightness", #selector(restore)) }
        else      { add(sub, "Black Out Screen", #selector(black)) }
        sub.addItem(.separator())
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self; login.state = loginEnabled ? .on : .off; sub.addItem(login)
        let gd = NSMenuItem(title: "Guide", action: #selector(openGuide), keyEquivalent: ""); gd.target = self; sub.addItem(gd)
        settings.submenu = sub
        menu.addItem(settings)

        menu.addItem(.separator())
        add(menu, "Quit", #selector(quitApp))
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item); return item
    }

    func refresh() {
        if configured {
            run(["status"]) { [weak self] out in
                let ok = out.trimmingCharacters(in: .whitespacesAndNewlines) == "reachable"
                DispatchQueue.main.async { self?.reachable = ok }
            }
        } else {                                                    // no machine yet — just show whether the tailnet is up
            run(["net"]) { [weak self] out in
                let up = out.trimmingCharacters(in: .whitespacesAndNewlines) == "active"
                DispatchQueue.main.async { self?.netActive = up }
            }
        }
    }

    @objc func connect() {                                                    // first run walks you through picking a machine
        if !configured { runSetup(thenConnect: true); return }
        connectNow()
    }
    func connectNow() {                                                       // connect + black out by default
        run(["connect"]) { _ in }
        dimmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.run(["black"]) { _ in } }  // wait for connect to wake the screen
    }

    @objc func changeMachine() { runSetup(thenConnect: false) }

    // Fetch tailnet peers off the main thread, then present the picker.
    func runSetup(thenConnect: Bool) {
        run(["machines"]) { [weak self] out in
            DispatchQueue.main.async { self?.presentSetup(out, thenConnect: thenConnect) }
        }
    }

    func presentSetup(_ raw: String, thenConnect: Bool) {
        let machines: [(ip: String, host: String)] = raw.split(separator: "\n").compactMap { line in
            let c = line.split(separator: "\t")
            return c.count >= 2 ? (String(c[0]), String(c[1])) : nil
        }
        let alert = NSAlert()
        alert.messageText = "Choose your dev machine"
        alert.informativeText = "Pick a Mac from your Tailscale network, then enter the login username it uses (for Screen Sharing / SSH). No password needed — SSH uses your key, and macOS prompts for the screen-share login itself."

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 66))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 36, width: 320, height: 26))
        if machines.isEmpty {
            popup.addItem(withTitle: "No Tailscale machines found"); popup.isEnabled = false
        } else {
            for m in machines { popup.addItem(withTitle: "\(m.host) — \(m.ip)") }
            if let i = machines.firstIndex(where: { $0.ip == devIP }) { popup.selectItem(at: i) }
        }
        let label = NSTextField(labelWithString: "Username:")
        label.frame = NSRect(x: 0, y: 4, width: 70, height: 20)
        let field = NSTextField(frame: NSRect(x: 74, y: 0, width: 246, height: 24))
        field.stringValue = devUser                                 // blank on first run — the login name usually differs from this Mac's
        field.placeholderString = "login username on that Mac"
        box.addSubview(popup); box.addSubview(label); box.addSubview(field)
        alert.accessoryView = box
        alert.addButton(withTitle: thenConnect ? "Save & Connect" : "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !machines.isEmpty else { return }
        let i = popup.indexOfSelectedItem
        if i >= 0 && i < machines.count { devIP = machines[i].ip; devHost = machines[i].host }
        let u = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { devUser = u }
        saveConfig()
        refresh()
        if thenConnect && configured { connectNow() }
    }
    @objc func stopShare() {                                                  // close the share + lock + black out the dev
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.ScreenSharing" }?.terminate()
        run(["lock"]) { _ in }
        run(["black"]) { _ in }
        dimmed = true
    }
    @objc func black()   { run(["black"]) { _ in }; dimmed = true }
    @objc func restore() { run(["restore"]) { _ in }; dimmed = false }
    @objc func lock()    { run(["lock"]) { _ in } }

    @objc func toggleLogin() {
        do { if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { NSSound.beep() }
    }

    @objc func openGuide() {
        if let w = guideWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let p = Bundle.main.path(forResource: "GUIDE", ofType: "html") else { return }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "Dev Screen — Guide"; win.center(); win.isReleasedWhenClosed = false
        let web = WKWebView(frame: win.contentView!.bounds); web.autoresizingMask = [.width, .height]
        let u = URL(fileURLWithPath: p); web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent())
        win.contentView!.addSubview(web); win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        guideWindow = win
    }

    @objc func quitApp() { NSApplication.shared.terminate(nil) }   // one-shot actions; nothing to tear down

    func run(_ args: [String], done: @escaping (String) -> Void) {
        DispatchQueue.global().async {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = [ctlPath] + args
            let outPipe = Pipe(); p.standardOutput = outPipe; p.standardError = Pipe()
            do { try p.run() } catch { done(""); return }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            done(String(data: data, encoding: .utf8) ?? "")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
