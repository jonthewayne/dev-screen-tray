struct LocalDisplayPolicy {
    private(set) var viewerCount = 0
    private var consecutiveViewerObservations = 0
    private var consecutiveIdleObservations = 0
    private var confirmedSession = false

    var shouldPollFrequently: Bool {
        viewerCount > 0 || confirmedSession
    }

    mutating func observe(viewerCount newViewerCount: Int, autoSleepEnabled: Bool) -> Bool {
        viewerCount = max(0, newViewerCount)

        if viewerCount > 0 {
            consecutiveIdleObservations = 0
            consecutiveViewerObservations += 1
            if consecutiveViewerObservations >= 2 {
                confirmedSession = true
            }
            return false
        }

        consecutiveViewerObservations = 0
        guard confirmedSession else {
            consecutiveIdleObservations = 0
            return false
        }

        consecutiveIdleObservations += 1
        guard consecutiveIdleObservations >= 2 else { return false }

        confirmedSession = false
        consecutiveIdleObservations = 0
        return autoSleepEnabled
    }
}
