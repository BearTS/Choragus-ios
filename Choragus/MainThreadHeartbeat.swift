/// Background-queue main-thread responsiveness probe.
///
/// A serial timer on a utility queue dispatches a tiny block to main
/// every `pulseInterval`. The delivery delay (`scheduled → executed`
/// minus `pulseInterval`) is the time main was blocked when the pulse
/// landed. When the measured delay exceeds `stallThreshold`, the probe
/// logs the magnitude so it can be cross-referenced with the
/// `[KARAOKE-FRAME]` probe and the SonosKit diagnostic stream.
///
/// Compiled in `#if DEBUG` only — release builds drop the type
/// entirely so there's no runtime cost to ship.
import Foundation
import SonosKit

#if DEBUG
final class MainThreadHeartbeat: @unchecked Sendable {
    static let shared = MainThreadHeartbeat()

    /// 100 ms cadence. Below this the probe itself drives so many
    /// main-queue wake-ups that CA::Transaction observers fire on
    /// every cycle, inflating the very CPU usage the probe is meant
    /// to measure. 100 ms still catches the 50 ms+ stalls flagged by
    /// `stallThresholdMs` — a stall longer than 100 ms surfaces on the
    /// next pulse with full magnitude.
    private let pulseInterval: DispatchTimeInterval = .milliseconds(100)
    /// Below this we'd see noise from normal scheduler jitter
    /// (~16-25 ms when main is busy laying out a frame). 50 ms is
    /// already 3 missed v-syncs — anything above is a real stall.
    private let stallThresholdMs: Double = 50.0

    private let queue = DispatchQueue(label: "main-thread-heartbeat",
                                      qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastLoggedAt: Date = .distantPast

    private init() {}

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.pulseInterval,
                       repeating: self.pulseInterval,
                       leeway: .milliseconds(2))
            t.setEventHandler { [weak self] in
                self?.pulse()
            }
            self.timer = t
            t.resume()
        }
    }

    private func pulse() {
        let scheduledAt = Date()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let delayMs = Date().timeIntervalSince(scheduledAt) * 1000.0
            guard delayMs > self.stallThresholdMs else { return }
            // Coalesce — if a single 200 ms stall keeps the main
            // thread blocked, every queued pulse fires back-to-back
            // when main resumes and we'd get a stream of N near-
            // duplicate log lines for one event. Drop secondaries
            // within 50 ms of the prior log so we keep one line per
            // distinct stall.
            let now = Date()
            if now.timeIntervalSince(self.lastLoggedAt) < 0.050 { return }
            self.lastLoggedAt = now
            sonosDebugLog(String(format: "[MAIN-STALL] %.1fms", delayMs))
        }
    }
}
#endif
