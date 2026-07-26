struct BlackoutPolicy {
    private(set) var sessionActive = false
    private(set) var enforcementEnabled = false

    var shouldMonitor: Bool {
        sessionActive && enforcementEnabled
    }

    mutating func connect() {
        sessionActive = true
        enforcementEnabled = true
    }

    mutating func restore() {
        enforcementEnabled = false
    }

    mutating func black() {
        enforcementEnabled = sessionActive
    }

    mutating func disconnect() {
        sessionActive = false
        enforcementEnabled = false
    }
}
