import Foundation

func expectLocalDisplay(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct LocalDisplayPolicyTests {
    static func main() {
        var policy = LocalDisplayPolicy()

        expectLocalDisplay(!policy.observe(viewerCount: 0, autoSleepEnabled: true), "startup with no viewers must not sleep the display")
        expectLocalDisplay(!policy.observe(viewerCount: 1, autoSleepEnabled: true), "the first viewer observation must not sleep the display")
        expectLocalDisplay(policy.shouldPollFrequently, "a possible viewer must enable fast confirmation polling")
        expectLocalDisplay(!policy.observe(viewerCount: 1, autoSleepEnabled: true), "a confirmed viewer must not sleep the display")
        expectLocalDisplay(!policy.observe(viewerCount: 2, autoSleepEnabled: true), "an additional viewer must not sleep the display")
        expectLocalDisplay(!policy.observe(viewerCount: 1, autoSleepEnabled: true), "one of multiple viewers disconnecting must not sleep the display")
        expectLocalDisplay(!policy.observe(viewerCount: 0, autoSleepEnabled: true), "the first idle observation must confirm the disconnect")
        expectLocalDisplay(policy.shouldPollFrequently, "disconnect confirmation must keep fast polling active")
        expectLocalDisplay(policy.observe(viewerCount: 0, autoSleepEnabled: true), "a confirmed final-viewer disconnect should sleep the display")
        expectLocalDisplay(!policy.shouldPollFrequently, "fast polling must stop after a confirmed disconnect")
        expectLocalDisplay(!policy.observe(viewerCount: 0, autoSleepEnabled: true), "repeated idle checks must not sleep the display again")

        var briefConnection = LocalDisplayPolicy()
        expectLocalDisplay(!briefConnection.observe(viewerCount: 1, autoSleepEnabled: true), "a brief port connection must not count as a session")
        expectLocalDisplay(!briefConnection.observe(viewerCount: 0, autoSleepEnabled: true), "a one-sample port connection must not sleep the display")

        var disabledPolicy = LocalDisplayPolicy()
        expectLocalDisplay(!disabledPolicy.observe(viewerCount: 1, autoSleepEnabled: false), "a viewer connecting while disabled must not sleep the display")
        expectLocalDisplay(!disabledPolicy.observe(viewerCount: 1, autoSleepEnabled: false), "a viewer session can still be confirmed while disabled")
        expectLocalDisplay(!disabledPolicy.observe(viewerCount: 0, autoSleepEnabled: false), "the first idle observation while disabled must not sleep the display")
        expectLocalDisplay(!disabledPolicy.observe(viewerCount: 0, autoSleepEnabled: false), "disconnecting while disabled must not sleep the display")

        expectLocalDisplay(!policy.observe(viewerCount: -1, autoSleepEnabled: true), "invalid negative counts should be treated as idle without sleeping")
        expectLocalDisplay(policy.viewerCount == 0, "viewer counts should be normalized at the policy boundary")

        print("LocalDisplayPolicyTests passed")
    }
}
