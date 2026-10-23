import Foundation

/// Measures how long a user-interactive thread waits to be scheduled.
///
/// Every interval, a ping is sent to a user-interactive queue and timed until it runs. When the
/// CPU is saturated, or the system is stuck paging memory back in, that wait grows — the same
/// stall that makes apps beachball. It runs off the main thread so this app's own UI work
/// never counts as system lag.
public final class ResponsivenessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var latencies: [Double] = []
    private var inFlight: [UInt64] = []
    private let window: Int
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "nobeachballs.probe.timer", qos: .userInteractive)
    private let target = DispatchQueue(label: "nobeachballs.probe.target", qos: .userInteractive)

    public init(interval: TimeInterval = 0.25, window: Int = 8) {
        self.interval = interval
        self.window = window
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let sent = DispatchTime.now().uptimeNanoseconds
            self.lock.withLock { self.inFlight.append(sent) }
            self.target.async {
                self.record(Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6)
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func record(_ latency: Double) {
        lock.withLock {
            if !inFlight.isEmpty { inFlight.removeFirst() }
            latencies.append(latency)
            if latencies.count > window { latencies.removeFirst(latencies.count - window) }
        }
    }

    /// 75th percentile scheduling delay over the window, in milliseconds.
    /// A ping that hasn't run yet counts as at least as late as it already is.
    public var latencyMs: Double {
        lock.withLock {
            let stalled = inFlight.first.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1e6 } ?? 0
            guard !latencies.isEmpty else { return stalled }
            let sorted = latencies.sorted()
            return max(stalled, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.75))])
        }
    }
}
