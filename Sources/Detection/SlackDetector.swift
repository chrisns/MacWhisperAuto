import AppKit
import Foundation
import IOKit.pwr_mgt
import os

/// Detects Slack huddles via two complementary paths:
/// 1. CGWindowList: "huddle" in window titles (needs Screen Recording permission).
/// 2. Network UDP + IOPM assertion (AND-gated): Slack holds many UDP sockets AND
///    a PreventUserIdleDisplaySleep/SystemSleep assertion during huddles. The UDP
///    count must stay above threshold for several consecutive polls to filter
///    transient bursts from notification sounds, voice-message previews, etc.
final class SlackDetector: MeetingDetector, WindowListConsumer, @unchecked Sendable {
    private let onSignal: @Sendable (MeetingSignal) -> Void
    private let _isEnabled = OSAllocatedUnfairLock(initialState: false)
    private let _lastActive = OSAllocatedUnfairLock(initialState: false)

    // Poll-queue-confined state (only touched from pollQueue)
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "com.macwhisperauto.slack.poll")
    private var consecutiveOverThreshold = 0
    private var lastNetworkActive = false
    private var peakUDPDuringActive = 0
    private var activeSince: Date?

    private static let pollInterval: TimeInterval = 3.0
    private static let udpSocketThreshold = 4          // fire when count > 4 (i.e. >= 5)
    private static let sustainedPollsRequired = 2      // ~3-6s sustained over-threshold
    private static let slackBundleID = "com.tinyspeck.slackmacgap"
    private static let falsePositiveDurationCutoff: TimeInterval = 60.0

    var isEnabled: Bool { _isEnabled.withLock { $0 } }

    init(onSignal: @escaping @Sendable (MeetingSignal) -> Void) {
        self.onSignal = onSignal
    }

    deinit {
        stop()
    }

    func start() {
        _isEnabled.withLock { $0 = true }
        startPolling()
        DetectionLogger.shared.detection("SlackDetector started", platform: .slack)
    }

    func stop() {
        _isEnabled.withLock { $0 = false }
        pollTimer?.cancel()
        pollTimer = nil
        DetectionLogger.shared.detection("SlackDetector stopped", platform: .slack)
    }

    // MARK: - Combined UDP + IOPM polling

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollOnce() {
        guard isEnabled else { return }

        let udpCount = Self.countSlackUDPSockets()
        let overThreshold = udpCount > Self.udpSocketThreshold
        let (iopmActive, assertionNames) = Self.slackAssertions()

        if overThreshold {
            consecutiveOverThreshold += 1
        } else {
            consecutiveOverThreshold = 0
        }
        let sustained = consecutiveOverThreshold >= Self.sustainedPollsRequired
        let active = sustained && iopmActive

        // Per-poll diagnostic - so future tuning is data-driven.
        DetectionLogger.shared.detection(
            "Slack poll udp=\(udpCount) consec=\(consecutiveOverThreshold) iopm=\(iopmActive) sustained=\(sustained) active=\(active)",
            platform: .slack, signal: .networkUDP
        )

        if active {
            peakUDPDuringActive = max(peakUDPDuringActive, udpCount)
        }

        let was = lastNetworkActive
        lastNetworkActive = active
        let changed = active != was

        // Edge logs only on transitions (active/inactive summaries)
        if changed {
            if active {
                activeSince = Date()
                let endpoints = Self.slackUDPEndpoints(limit: 10).joined(separator: ",")
                let names = assertionNames.joined(separator: "|")
                DetectionLogger.shared.detection(
                    "Slack ACTIVE udp=\(udpCount) peak=\(peakUDPDuringActive) iopm=[\(names)] endpoints=[\(endpoints)]",
                    platform: .slack, signal: .networkUDP, active: true
                )
            } else {
                let duration = activeSince.map { Date().timeIntervalSince($0) } ?? 0
                let likelyFP = duration < Self.falsePositiveDurationCutoff
                DetectionLogger.shared.detection(
                    "Slack INACTIVE duration=\(String(format: "%.1f", duration))s peak=\(peakUDPDuringActive) likelyFalsePositive=\(likelyFP)",
                    platform: .slack, signal: .networkUDP, active: false
                )
                activeSince = nil
                peakUDPDuringActive = 0
            }
        }

        // Emit on transition OR while active (heartbeat — recovers stuck idle state)
        if changed || active {
            onSignal(MeetingSignal(
                platform: .slack,
                isActive: active,
                confidence: .high,
                source: .networkUDP,
                timestamp: Date()
            ))
        }
    }

    // MARK: - lsof helpers

    static func countSlackUDPSockets() -> Int {
        let output = runLsof()
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        return max(0, lines.count - 1)
    }

    /// Remote-address column from each UDP socket row, truncated to `limit`.
    /// Diagnostic only — used in the active-edge log line.
    static func slackUDPEndpoints(limit: Int) -> [String] {
        let output = runLsof()
        var endpoints: [String] = []
        for (i, line) in output.components(separatedBy: "\n").enumerated() {
            if i == 0 || line.isEmpty { continue } // skip header
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if let name = cols.last {
                endpoints.append(String(name))
                if endpoints.count >= limit { break }
            }
        }
        return endpoints
    }

    private static func runLsof() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-i", "UDP", "-n", "-P", "-c", "Slack"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - IOPM assertion check

    /// Returns (anyHeld, assertionNames) for Slack-held idle-sleep assertions.
    /// During huddles Slack typically holds PreventUserIdleDisplaySleep and/or
    /// PreventUserIdleSystemSleep. Notification sounds / previews do not.
    static func slackAssertions() -> (Bool, [String]) {
        guard let pid = NSRunningApplication
            .runningApplications(withBundleIdentifier: slackBundleID)
            .first?.processIdentifier
        else { return (false, []) }

        var assertionsByProcess: Unmanaged<CFDictionary>?
        IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard let dict = assertionsByProcess?.takeRetainedValue()
                as? [String: [[String: Any]]]
        else { return (false, []) }

        var names: [String] = []
        for (_, assertions) in dict {
            for assertion in assertions {
                guard let assertPID = assertion["AssertPID"] as? Int32,
                      assertPID == pid,
                      let type = assertion["AssertType"] as? String
                else { continue }
                if type == "PreventUserIdleDisplaySleep" ||
                   type == "PreventUserIdleSystemSleep" {
                    let name = (assertion["AssertName"] as? String) ?? type
                    names.append(name)
                }
            }
        }
        return (!names.isEmpty, names)
    }

    // MARK: - CGWindowList Detection

    func processWindowList(_ windows: [WindowInfo]) {
        guard isEnabled else { return }

        let active = windows.contains { window in
            window.ownerName == "Slack" &&
            window.windowName.localizedCaseInsensitiveContains("huddle")
        }

        let lastActive = _lastActive.withLock { old -> Bool in
            let was = old
            old = active
            return was
        }

        let changed = active != lastActive
        if changed {
            DetectionLogger.shared.detection(
                "Slack huddle window \(active ? "found" : "gone")",
                platform: .slack, signal: .cgWindowList, active: active
            )
        }
        if changed || active {
            onSignal(MeetingSignal(
                platform: .slack,
                isActive: active,
                confidence: .high,
                source: .cgWindowList,
                timestamp: Date()
            ))
        }
    }
}
