import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct BlackoutPolicyTests {
    static func main() {
        var policy = BlackoutPolicy()

        expect(!policy.shouldMonitor, "a disconnected app must not monitor brightness")

        policy.connect()
        expect(policy.sessionActive, "connect should mark the sharing session active")
        expect(policy.shouldMonitor, "connect should enable blackout enforcement")

        policy.restore()
        expect(policy.sessionActive, "restoring brightness should not end screen sharing")
        expect(!policy.shouldMonitor, "restoring brightness should pause blackout enforcement")

        policy.black()
        expect(policy.shouldMonitor, "blacking the display during sharing should resume enforcement")

        policy.disconnect()
        expect(!policy.sessionActive, "disconnect should end the sharing session")
        expect(!policy.shouldMonitor, "disconnect should stop blackout enforcement")

        policy.black()
        expect(!policy.shouldMonitor, "a one-shot blackout while disconnected must not start monitoring")

        print("BlackoutPolicyTests passed")
    }
}
