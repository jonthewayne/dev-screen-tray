struct LocalLockedWakePolicy {
    private(set) var isScreenLocked = false
    private(set) var isScreenSaverActive = false
    private(set) var isDisplaySleeping = false

    var shouldSleepDisplay: Bool {
        !isDisplaySleeping && (isScreenLocked || isScreenSaverActive)
    }

    mutating func screensDidWake() {
        isDisplaySleeping = false
    }

    mutating func screensDidSleep() {
        isDisplaySleeping = true
    }

    mutating func screenDidLock() {
        isScreenLocked = true
    }

    mutating func screenDidUnlock() {
        isScreenLocked = false
        isScreenSaverActive = false
    }

    mutating func screenSaverDidStart() {
        isScreenSaverActive = true
    }

    mutating func screenSaverDidStop() {
        isScreenSaverActive = false
    }
}

enum LocalLockedWakeAction: Equatable {
    case sleepDisplay
    case waitForViewerDisconnect
    case cancel

    static func nextAction(
        generationIsCurrent: Bool,
        autoSleepEnabled: Bool,
        shouldSleepDisplay: Bool,
        viewerCount: Int?
    ) -> Self {
        guard generationIsCurrent, autoSleepEnabled, shouldSleepDisplay else {
            return .cancel
        }
        guard let viewerCount else {
            return .cancel
        }
        return viewerCount == 0 ? .sleepDisplay : .waitForViewerDisconnect
    }
}
