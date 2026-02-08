import AppKit
import CoreAudio
import Foundation
import IOKit.pwr_mgt
import os

/// Detects FaceTime calls by combining two signals:
/// 1. IOPMAssertion - FaceTime process holds a PreventUserIdleSystemSleep assertion during calls
/// 2. CGWindowList - FaceTime window is on-screen
///
/// Both conditions must be true for positive detection.
/// FaceTime is not available as a per-app recording target in MacWhisper,
/// so it uses "All System Audio" fallback (handled by InjectedMacWhisperController).
final class FaceTimeDetector: MeetingDetector, WindowListConsumer, @unchecked Sendable {
    private let onSignal: @Sendable (MeetingSignal) -> Void
    private let pollQueue = DispatchQueue(label: "com.macwhisperauto.facetime.poll")

    private let _isEnabled = OSAllocatedUnfairLock(initialState: false)
    private let _assertionActive = OSAllocatedUnfairLock(initialState: false)
    private let _windowVisible = OSAllocatedUnfairLock(initialState: false)
    private let _lastActive = OSAllocatedUnfairLock(initialState: false)

    private var assertionPollTimer: DispatchSourceTimer?
    private static let pollInterval: TimeInterval = 3.0
    private static let faceTimeBundleID = "com.apple.FaceTime"

    var isEnabled: Bool { _isEnabled.withLock { $0 } }

    init(onSignal: @escaping @Sendable (MeetingSignal) -> Void) {
        self.onSignal = onSignal
    }

    deinit {
        stop()
    }

    func start() {
        _isEnabled.withLock { $0 = true }
        startAssertionPolling()
        DetectionLogger.shared.detection("FaceTimeDetector started", platform: .faceTime)
    }

    func stop() {
        _isEnabled.withLock { $0 = false }
        stopAssertionPolling()
        DetectionLogger.shared.detection("FaceTimeDetector stopped", platform: .faceTime)
    }

    // MARK: - WindowListConsumer

    func processWindowList(_ windows: [WindowInfo]) {
        guard isEnabled else { return }

        let visible = windows.contains { window in
            window.ownerName == "FaceTime" && window.windowLayer == 0
        }

        _windowVisible.withLock { $0 = visible }
        evaluateAndEmit()
    }

    // MARK: - IOPMAssertion Polling

    private func startAssertionPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.pollInterval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            self?.pollAssertions()
        }
        timer.resume()
        assertionPollTimer = timer
    }

    private func stopAssertionPolling() {
        assertionPollTimer?.cancel()
        assertionPollTimer = nil
    }

    private func pollAssertions() {
        let active = Self.isFaceTimeCallAssertionPresent()
        _assertionActive.withLock { $0 = active }
        evaluateAndEmit()
    }

    /// Check if FaceTime has a power assertion indicating an active call.
    /// During FaceTime calls, the process holds PreventUserIdleSystemSleep assertions.
    static func isFaceTimeCallAssertionPresent() -> Bool {
        guard let pid = findFaceTimePID() else { return false }

        var assertionsByProcess: Unmanaged<CFDictionary>?
        IOPMCopyAssertionsByProcess(&assertionsByProcess)
        guard let dict = assertionsByProcess?.takeRetainedValue() as? [String: [[String: Any]]] else {
            return false
        }

        for (_, assertions) in dict {
            for assertion in assertions {
                guard let assertPID = assertion["AssertPID"] as? Int32,
                      assertPID == pid else { continue }
                if let type = assertion["AssertType"] as? String,
                   type == "PreventUserIdleSystemSleep" {
                    return true
                }
            }
        }
        // Fallback: check by process name
        for (_, assertions) in dict {
            for assertion in assertions {
                if let name = assertion["AssertName"] as? String,
                   name.contains("FaceTime"),
                   let type = assertion["AssertType"] as? String,
                   type == "PreventUserIdleSystemSleep" {
                    return true
                }
            }
        }
        return false
    }

    private static func findFaceTimePID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: faceTimeBundleID)
            .first?.processIdentifier
    }

    // MARK: - Signal Evaluation

    private func evaluateAndEmit() {
        guard isEnabled else { return }

        let assertionActive = _assertionActive.withLock { $0 }
        let windowVisible = _windowVisible.withLock { $0 }
        let active = assertionActive && windowVisible

        let lastActive = _lastActive.withLock { old -> Bool in
            let was = old
            old = active
            return was
        }

        if active != lastActive {
            DetectionLogger.shared.detection(
                "FaceTime call \(active ? "detected" : "ended") (assertion=\(assertionActive), window=\(windowVisible))",
                platform: .faceTime, signal: .iopmAssertion, active: active
            )
            let signal = MeetingSignal(
                platform: .faceTime,
                isActive: active,
                confidence: .high,
                source: .iopmAssertion,
                timestamp: Date()
            )
            onSignal(signal)
        }
    }
}
