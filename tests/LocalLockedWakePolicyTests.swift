import Foundation

func expectLockedWake(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct LocalLockedWakePolicyTests {
    static func main() {
        var policy = LocalLockedWakePolicy()

        expectLockedWake(!policy.shouldSleepDisplay, "an unlocked, awake Mac must not arm display sleep")
        policy.screenDidLock()
        expectLockedWake(policy.shouldSleepDisplay, "locking the current session should arm display sleep")

        policy.screensDidSleep()
        expectLockedWake(!policy.shouldSleepDisplay, "a display that is already asleep must not receive another sleep request")
        policy.screensDidWake()
        expectLockedWake(policy.shouldSleepDisplay, "a locked session should re-arm after its display wakes")

        policy.screenDidUnlock()
        expectLockedWake(!policy.shouldSleepDisplay, "unlocking must cancel a pending display-sleep action")
        policy.screensDidWake()
        expectLockedWake(!policy.shouldSleepDisplay, "an unlocked wake must remain visible for active use")

        policy.screenSaverDidStart()
        expectLockedWake(policy.shouldSleepDisplay, "starting a screen saver should arm display sleep")
        expectLockedWake(policy.shouldSleepDisplay, "an active screen saver should be eligible for display sleep")
        policy.screenSaverDidStop()
        expectLockedWake(!policy.shouldSleepDisplay, "dismissing an unlocked screen saver must cancel display sleep")

        policy.screenDidLock()
        expectLockedWake(policy.shouldSleepDisplay, "a locked session should arm display sleep again")
        policy.screenSaverDidStart()
        expectLockedWake(policy.shouldSleepDisplay, "a screen saver while locked should remain eligible")
        policy.screenSaverDidStop()
        expectLockedWake(policy.shouldSleepDisplay, "leaving the login prompt locked should keep display sleep armed")
        policy.screenDidUnlock()
        expectLockedWake(!policy.shouldSleepDisplay, "unlocking after a screen saver must clear all locked state")

        expectLockedWake(
            LocalLockedWakeAction.nextAction(
                generationIsCurrent: true,
                autoSleepEnabled: true,
                shouldSleepDisplay: true,
                viewerCount: 1
            ) == .waitForViewerDisconnect,
            "an incoming viewer must suppress the fired lock-wake sleep"
        )
        expectLockedWake(
            LocalLockedWakeAction.nextAction(
                generationIsCurrent: false,
                autoSleepEnabled: true,
                shouldSleepDisplay: true,
                viewerCount: 0
            ) == .cancel,
            "a cancelled timer generation must not request display sleep"
        )
        expectLockedWake(
            LocalLockedWakeAction.nextAction(
                generationIsCurrent: true,
                autoSleepEnabled: false,
                shouldSleepDisplay: true,
                viewerCount: 0
            ) == .cancel,
            "disabling the setting before the action must prevent display sleep"
        )

        print("LocalLockedWakePolicyTests passed")
    }
}
