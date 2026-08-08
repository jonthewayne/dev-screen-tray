import AppKit
import ServiceManagement
import WebKit

let ctlPath = Bundle.main.path(forResource: "dev-screen-ctl", ofType: nil) ?? ""   // bundled in Contents/Resources

struct CommandResult {
    let output: String
    let status: Int32

    var succeeded: Bool { status == 0 }
    var wasCancelled: Bool { status == -2 }
}

struct LocalViewerProbeCompletion {
    let minimumProbeSequence: UInt
    let handler: (Int?) -> Void
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let localAutoSleepKey = "sleepLocalDisplayAfterLastViewerDisconnects"
    static let localLockedWakeAutoSleepKey = "sleepLocalDisplayAfterLockOrScreenSaver"
    static let localLockedWakeDelay: TimeInterval = 5

    var statusItem: NSStatusItem!
    var statusTimer: Timer?
    var blackoutTimer: Timer?
    var localViewerTimer: Timer?
    var localLockedWakeTimer: DispatchWorkItem?
    var blackoutCheckInFlight = false
    var localViewerCheckInFlight = false
    var localViewerProbeSequence: UInt = 0
    var localViewerProbeCompletions: [LocalViewerProbeCompletion] = []
    var localViewerFailureCount = 0
    var localDisplaySleepInFlight = false
    var blackoutPolicy = BlackoutPolicy()
    var localDisplayPolicy = LocalDisplayPolicy()
    var localLockedWakePolicy = LocalLockedWakePolicy()
    var blackoutGeneration: UInt = 0
    var localLockedWakeGeneration: UInt = 0
    var connectPending = false
    var disconnectPending = false
    var disconnectFallback: DispatchWorkItem?
    var previousBrightness: Double?
    let displayCommandQueue = DispatchQueue(label: "io.govtrack.devscreen.display-commands")
    var reachable = false
    var netActive = false                      // is the Tailscale network up? (shown before a machine is picked)
    var dimmed = false                         // last verified/requested state of the dev Mac's physical display
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
        if UserDefaults.standard.object(forKey: Self.localAutoSleepKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.localAutoSleepKey)
        }
        if UserDefaults.standard.object(forKey: Self.localLockedWakeAutoSleepKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.localLockedWakeAutoSleepKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self          // repopulated on each open
        statusItem.menu = menu
        loadConfig()
        applyIcon()
        refresh()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(screenSharingTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(localScreensDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(localScreensDidSleep(_:)),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(
            self,
            selector: #selector(localScreenDidLock(_:)),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(localScreenDidUnlock(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(localScreenSaverDidStart(_:)),
            name: Notification.Name("com.apple.screensaver.didstart"),
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(localScreenSaverDidStop(_:)),
            name: Notification.Name("com.apple.screensaver.didstop"),
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        stopBlackoutMonitor()
        stopLocalViewerMonitor()
        cancelLocalLockedWakeSleep()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func applyIcon() {
        guard let button = statusItem.button else { return }
        if let img = NSImage(systemSymbolName: "display", accessibilityDescription: "Dev Screen") {
            img.isTemplate = true; button.image = img; button.title = ""
        } else { button.image = nil; button.title = "🖥" }
    }

    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var localAutoSleepEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.localAutoSleepKey)
    }
    var localLockedWakeAutoSleepEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.localLockedWakeAutoSleepKey)
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh(); populate(menu) }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let headerTitle: String
        // 🟢 green = connected (live session) · ○ = everything else (no yellow)
        if !configured           { headerTitle = netActive ? "○ Tailscale network active" : "○ Tailscale network inactive" }
        else if sharing          { headerTitle = "🟢 \(machineLabel): online, connected" }
        else if reachable        { headerTitle = "○ \(machineLabel): online, not connected" }
        else                     { headerTitle = "○ \(machineLabel): offline" }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false; menu.addItem(header)
        menu.addItem(.separator())

        if sharing {
            add(menu, "Stop Screen Share", #selector(stopShare))
        } else {
            let connectItem = add(menu, "Connect (Screen Share)", #selector(connect))
            connectItem.isEnabled = !connectPending && !disconnectPending
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        addSectionHeader(sub, "DEV MAC")
        let dm = add(sub, configured ? "Dev Machine: \(machineLabel)…" : "Dev Machine: not set…", #selector(changeMachine))
        dm.target = self
        dm.isEnabled = !connectPending && !disconnectPending && !sharing && !blackoutPolicy.sessionActive
        if dimmed { add(sub, "Restore Brightness", #selector(restore)) }
        else      { add(sub, "Black Out Screen", #selector(black)) }
        sub.addItem(.separator())

        addSectionHeader(sub, "THIS MAC")
        let viewerTitle = localDisplayPolicy.viewerCount == 1
            ? "Incoming Screen Sharing: 1 Viewer"
            : "Incoming Screen Sharing: \(localDisplayPolicy.viewerCount) Viewers"
        addDisabled(sub, viewerTitle)
        let autoSleep = add(sub, "Sleep Display After Last Viewer Disconnects", #selector(toggleLocalAutoSleep))
        autoSleep.state = localAutoSleepEnabled ? .on : .off
        let lockedWakeAutoSleep = add(
            sub,
            "Sleep Display 5 Seconds After Lock / Screen Saver",
            #selector(toggleLocalLockedWakeAutoSleep)
        )
        lockedWakeAutoSleep.state = localLockedWakeAutoSleepEnabled ? .on : .off
        add(sub, "Sleep This Display Now", #selector(sleepLocalDisplay))
        sub.addItem(.separator())

        addSectionHeader(sub, "GENERAL")
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

    func addSectionHeader(_ menu: NSMenu, _ title: String) {
        addDisabled(menu, title)
    }

    func addDisabled(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func refresh() {
        checkLocalViewers()
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

    func checkLocalViewers(
        requiringFreshResult: Bool = false,
        then completion: ((Int?) -> Void)? = nil
    ) {
        if let completion {
            let minimumProbeSequence: UInt
            if localViewerCheckInFlight {
                minimumProbeSequence = requiringFreshResult
                    ? localViewerProbeSequence &+ 1
                    : localViewerProbeSequence
            } else {
                minimumProbeSequence = localViewerProbeSequence &+ 1
            }
            localViewerProbeCompletions.append(LocalViewerProbeCompletion(
                minimumProbeSequence: minimumProbeSequence,
                handler: completion
            ))
        }
        guard !localViewerCheckInFlight else { return }
        startLocalViewerProbe()
    }

    func startLocalViewerProbe() {
        localViewerCheckInFlight = true
        localViewerProbeSequence &+= 1
        let probeSequence = localViewerProbeSequence
        runCommand(["local-viewers"]) { [weak self] result in
            let count = result.succeeded
                ? Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.localViewerCheckInFlight = false
                let completions = self.localViewerProbeCompletions
                    .filter { $0.minimumProbeSequence <= probeSequence }
                self.localViewerProbeCompletions.removeAll {
                    $0.minimumProbeSequence <= probeSequence
                }
                guard let count else {
                    self.localViewerFailureCount += 1
                    if self.localViewerFailureCount >= 3 {
                        self.localViewerFailureCount = 0
                        self.localDisplayPolicy = LocalDisplayPolicy()
                        self.stopLocalViewerMonitor()
                    }
                    completions.forEach { $0.handler(nil) }
                    self.startPendingLocalViewerProbeIfNeeded()
                    return
                }
                self.localViewerFailureCount = 0

                if self.observeLocalViewerCount(count) {
                    self.requestLocalDisplaySleep()
                }
                completions.forEach { $0.handler(count) }
                self.startPendingLocalViewerProbeIfNeeded()
            }
        }
    }

    func startPendingLocalViewerProbeIfNeeded() {
        guard !localViewerCheckInFlight, !localViewerProbeCompletions.isEmpty else { return }
        startLocalViewerProbe()
    }

    @discardableResult
    func observeLocalViewerCount(_ count: Int) -> Bool {
        let shouldSleep = localDisplayPolicy.observe(
            viewerCount: count,
            autoSleepEnabled: localAutoSleepEnabled
        )
        if localDisplayPolicy.shouldPollFrequently {
            startLocalViewerMonitor()
        } else {
            stopLocalViewerMonitor()
        }
        return shouldSleep
    }

    func startLocalViewerMonitor() {
        guard localViewerTimer == nil else { return }
        localViewerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkLocalViewers()
        }
        localViewerTimer?.tolerance = 0.25
    }

    func stopLocalViewerMonitor() {
        localViewerTimer?.invalidate()
        localViewerTimer = nil
    }

    @objc func sleepLocalDisplay() {
        requestLocalDisplaySleep()
    }

    func requestLocalDisplaySleep(
        onlyIf shouldStart: (() -> Bool)? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !localDisplaySleepInFlight else {
            completion?(false)
            return
        }
        localDisplaySleepInFlight = true
        runCommand(["local-sleep"], shouldStart: shouldStart) { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.localDisplaySleepInFlight = false
                if !result.succeeded && !result.wasCancelled { NSSound.beep() }
                completion?(result.succeeded)
            }
        }
    }

    @objc func toggleLocalAutoSleep() {
        let enabled = !localAutoSleepEnabled
        UserDefaults.standard.set(enabled, forKey: Self.localAutoSleepKey)
    }

    @objc func toggleLocalLockedWakeAutoSleep() {
        let enabled = !localLockedWakeAutoSleepEnabled
        UserDefaults.standard.set(enabled, forKey: Self.localLockedWakeAutoSleepKey)
        updateLocalLockedWakeSleepTimer(restarting: enabled)
    }

    @objc func localScreensDidWake(_ notification: Notification) {
        localLockedWakePolicy.screensDidWake()
        updateLocalLockedWakeSleepTimer(restarting: true)
    }

    @objc func localScreensDidSleep(_ notification: Notification) {
        localLockedWakePolicy.screensDidSleep()
        cancelLocalLockedWakeSleep()
    }

    @objc func localScreenDidLock(_ notification: Notification) {
        localLockedWakePolicy.screenDidLock()
        updateLocalLockedWakeSleepTimer(restarting: true)
    }

    @objc func localScreenDidUnlock(_ notification: Notification) {
        localLockedWakePolicy.screenDidUnlock()
        cancelLocalLockedWakeSleep()
    }

    @objc func localScreenSaverDidStart(_ notification: Notification) {
        localLockedWakePolicy.screenSaverDidStart()
        updateLocalLockedWakeSleepTimer(restarting: true)
    }

    @objc func localScreenSaverDidStop(_ notification: Notification) {
        localLockedWakePolicy.screenSaverDidStop()
        updateLocalLockedWakeSleepTimer(restarting: true)
    }

    func updateLocalLockedWakeSleepTimer(restarting: Bool = false) {
        guard localLockedWakeAutoSleepEnabled, localLockedWakePolicy.shouldSleepDisplay else {
            cancelLocalLockedWakeSleep()
            return
        }
        if restarting { cancelLocalLockedWakeSleep() }
        guard localLockedWakeTimer == nil else { return }

        localLockedWakeGeneration &+= 1
        let generation = localLockedWakeGeneration
        let work = DispatchWorkItem { [weak self] in
            self?.lockedWakeSleepTimerDidFire(generation: generation)
        }
        localLockedWakeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.localLockedWakeDelay, execute: work)
    }

    func cancelLocalLockedWakeSleep() {
        localLockedWakeGeneration &+= 1
        localLockedWakeTimer?.cancel()
        localLockedWakeTimer = nil
    }

    func canStartLocalLockedWakeSleep(generation: UInt) -> Bool {
        generation == localLockedWakeGeneration &&
            localLockedWakeAutoSleepEnabled &&
            localLockedWakePolicy.shouldSleepDisplay
    }

    func lockedWakeSleepTimerDidFire(generation: UInt) {
        guard canStartLocalLockedWakeSleep(generation: generation) else { return }
        localLockedWakeTimer = nil

        // Require a probe started after this timer fired before sleeping a display under a new viewer.
        checkLocalViewers(requiringFreshResult: true) { [weak self] viewerCount in
            guard
                let self
            else { return }
            switch LocalLockedWakeAction.nextAction(
                generationIsCurrent: generation == self.localLockedWakeGeneration,
                autoSleepEnabled: self.localLockedWakeAutoSleepEnabled,
                shouldSleepDisplay: self.localLockedWakePolicy.shouldSleepDisplay,
                viewerCount: viewerCount
            ) {
            case .cancel, .waitForViewerDisconnect:
                return
            case .sleepDisplay:
                self.requestLocalDisplaySleep(onlyIf: { [weak self] in
                    self?.canStartLocalLockedWakeSleep(generation: generation) ?? false
                })
            }
        }
    }

    @objc func connect() {                                                    // first run walks you through picking a machine
        if !configured { runSetup(thenConnect: true); return }
        connectNow()
    }
    func connectNow() {                                                       // connect + black out by default
        let generation = advanceBlackoutGeneration()
        previousBrightness = nil
        blackoutPolicy.disconnect()
        stopBlackoutMonitor()
        connectPending = true
        runCommand(["connect"]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.blackoutGeneration else { return }
                guard result.succeeded else {
                    self.connectPending = false
                    NSSound.beep()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, generation == self.blackoutGeneration else { return }
                    self.connectPending = false
                    guard self.sharing else {
                        NSSound.beep()
                        return
                    }
                    self.blackoutPolicy.connect()
                    self.enableBlackout(generation: generation)
                }                                                             // wait for Screen Sharing to wake the display
            }
        }
    }

    @objc func changeMachine() {
        guard !connectPending, !disconnectPending, !sharing, !blackoutPolicy.sessionActive else {
            NSSound.beep()
            return
        }
        runSetup(thenConnect: false)
    }

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
    @objc func stopShare() {
        endSharingSession(terminateLocalApp: true)
    }

    @objc func black() {
        let generation = advanceBlackoutGeneration()
        if sharing {
            if blackoutPolicy.sessionActive {
                blackoutPolicy.black()
            } else {
                blackoutPolicy.connect()
            }
            enableBlackout(generation: generation)
        } else {
            runDisplay(["black"]) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, generation == self.blackoutGeneration else { return }
                    self.dimmed = result.succeeded
                    if !result.succeeded { NSSound.beep() }
                }
            }
        }
    }

    @objc func restore() {
        let generation = advanceBlackoutGeneration()
        blackoutPolicy.restore()
        stopBlackoutMonitor()
        let value = previousBrightness ?? 1
        runDisplay(["restore", String(format: "%.6f", value)]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.blackoutGeneration else { return }
                if result.succeeded {
                    self.dimmed = false
                } else {
                    NSSound.beep()
                }
            }
        }
    }
    @objc func lock()    { run(["lock"]) { _ in } }

    @discardableResult
    func advanceBlackoutGeneration() -> UInt {
        blackoutGeneration &+= 1
        return blackoutGeneration
    }

    func enableBlackout(generation: UInt) {
        guard generation == blackoutGeneration, blackoutPolicy.shouldMonitor else { return }

        if previousBrightness == nil {
            readBrightness { [weak self] value in
                guard
                    let self,
                    generation == self.blackoutGeneration,
                    self.blackoutPolicy.shouldMonitor
                else { return }
                if let value, value > 0.01 {
                    self.previousBrightness = value
                }
                self.blackDisplayAndStartMonitor(generation: generation)
            }
        } else {
            blackDisplayAndStartMonitor(generation: generation)
        }
    }

    func blackDisplayAndStartMonitor(generation: UInt) {
        guard generation == blackoutGeneration, blackoutPolicy.shouldMonitor else { return }
        runDisplay(["black"]) { [weak self] result in
            DispatchQueue.main.async {
                guard
                    let self,
                    generation == self.blackoutGeneration,
                    self.blackoutPolicy.shouldMonitor
                else { return }
                self.dimmed = result.succeeded
                self.startBlackoutMonitor()
                if !result.succeeded { NSSound.beep() }
            }
        }
    }

    func startBlackoutMonitor() {
        stopBlackoutMonitor()
        guard blackoutPolicy.shouldMonitor else { return }
        blackoutTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkBlackout()
        }
        blackoutTimer?.tolerance = 0.5
    }

    func stopBlackoutMonitor() {
        blackoutTimer?.invalidate()
        blackoutTimer = nil
        blackoutCheckInFlight = false
    }

    func checkBlackout() {
        guard blackoutPolicy.shouldMonitor, !blackoutCheckInFlight else { return }
        let generation = blackoutGeneration
        blackoutCheckInFlight = true
        readBrightness { [weak self] value in
            guard let self, generation == self.blackoutGeneration else { return }
            self.blackoutCheckInFlight = false
            guard self.blackoutPolicy.shouldMonitor else { return }

            guard let value else { return }
            if value <= 0.01 {
                self.dimmed = true
                return
            }

            self.runDisplay(["black"]) { [weak self] blackResult in
                DispatchQueue.main.async {
                    guard
                        let self,
                        generation == self.blackoutGeneration,
                        self.blackoutPolicy.shouldMonitor
                    else { return }
                    self.dimmed = blackResult.succeeded
                    if !blackResult.succeeded { NSSound.beep() }
                }
            }
        }
    }

    func readBrightness(done: @escaping (Double?) -> Void) {
        runDisplay(["brightness"]) { result in
            let value = result.succeeded
                ? Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
                : nil
            DispatchQueue.main.async { done(value) }
        }
    }

    func endSharingSession(terminateLocalApp: Bool) {
        advanceBlackoutGeneration()
        connectPending = false
        blackoutPolicy.disconnect()
        stopBlackoutMonitor()
        if disconnectPending {
            if !terminateLocalApp { finalizeDisconnect() }
            return
        }
        disconnectPending = true

        if terminateLocalApp,
           let application = NSWorkspace.shared.runningApplications
               .first(where: { $0.bundleIdentifier == "com.apple.ScreenSharing" }) {
            application.terminate()
            let fallback = DispatchWorkItem { [weak self] in self?.finalizeDisconnect() }
            disconnectFallback = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: fallback)
        } else {
            finalizeDisconnect()
        }
    }

    func finalizeDisconnect() {
        guard disconnectPending else { return }
        disconnectPending = false
        disconnectFallback?.cancel()
        disconnectFallback = nil
        runDisplay(["disconnect"]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                let blackStatus = result.output
                    .split(whereSeparator: \.isWhitespace)
                    .first(where: { $0.hasPrefix("black_status=") })
                    .flatMap { Int($0.dropFirst("black_status=".count)) }
                if let blackStatus {
                    self.dimmed = blackStatus == 0
                } else if result.succeeded {
                    self.dimmed = true
                }
                if !result.succeeded { NSSound.beep() }
            }
        }
    }

    @objc func screenSharingTerminated(_ notification: Notification) {
        guard
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            application.bundleIdentifier == "com.apple.ScreenSharing",
            disconnectPending || connectPending || blackoutPolicy.sessionActive
        else { return }
        endSharingSession(terminateLocalApp: false)
    }

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

    @objc func quitApp() { NSApplication.shared.terminate(nil) }

    func run(_ args: [String], done: @escaping (String) -> Void) {
        runCommand(args) { done($0.output) }
    }

    func runCommand(
        _ args: [String],
        shouldStart: (() -> Bool)? = nil,
        done: @escaping (CommandResult) -> Void
    ) {
        runChecked(args, on: .global(), shouldStart: shouldStart, done: done)
    }

    func runDisplay(
        _ args: [String],
        shouldStart: (() -> Bool)? = nil,
        done: @escaping (CommandResult) -> Void
    ) {
        runChecked(args, on: displayCommandQueue, shouldStart: shouldStart, done: done)
    }

    private func runChecked(
        _ args: [String],
        on queue: DispatchQueue,
        shouldStart: (() -> Bool)? = nil,
        done: @escaping (CommandResult) -> Void
    ) {
        queue.async {
            if let shouldStart {
                let mayStart = Thread.isMainThread
                    ? shouldStart()
                    : DispatchQueue.main.sync(execute: shouldStart)
                guard mayStart else {
                    done(CommandResult(output: "", status: -2))
                    return
                }
            }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = [ctlPath] + args
            let outPipe = Pipe()
            p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
            do {
                try p.run()
            } catch {
                done(CommandResult(output: "", status: -1))
                return
            }
            let output = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            done(CommandResult(
                output: String(data: output, encoding: .utf8) ?? "",
                status: p.terminationStatus
            ))
        }
    }
}

@main
struct DevScreenApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
