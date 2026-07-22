import AppKit
import ServiceManagement
import WebKit

let ctlPath = Bundle.main.path(forResource: "dev-screen-ctl", ofType: nil) ?? ""   // bundled in Contents/Resources

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var reachable = false
    var guideWindow: NSWindow?
    var sharing: Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.ScreenSharing" } }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self          // repopulated on each open
        statusItem.menu = menu
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
        let header = NSMenuItem(title: reachable ? "🟢 Dev Mac: reachable" : "○ Dev Mac: unreachable",
                                action: nil, keyEquivalent: "")
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
        add(sub, "Black Out Screen", #selector(black))
        add(sub, "Restore Brightness", #selector(restore))
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
        run(["status"]) { [weak self] out in
            let ok = out.trimmingCharacters(in: .whitespacesAndNewlines) == "reachable"
            DispatchQueue.main.async { self?.reachable = ok }
        }
    }

    @objc func connect() {                                                    // connect + black out by default
        run(["connect"]) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.run(["black"]) { _ in } }  // wait for connect to wake the screen
    }
    @objc func stopShare() {                                                  // close the share + lock + black out the dev
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.ScreenSharing" }?.terminate()
        run(["lock"]) { _ in }
        run(["black"]) { _ in }
    }
    @objc func black()   { run(["black"]) { _ in } }
    @objc func restore() { run(["restore"]) { _ in } }
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
