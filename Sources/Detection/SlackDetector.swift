import Foundation
import os

/// Detects Slack huddles by matching "huddle" in window titles via CGWindowList.
final class SlackDetector: MeetingDetector, WindowListConsumer, @unchecked Sendable {
    private let onSignal: @Sendable (MeetingSignal) -> Void
    private let _isEnabled = OSAllocatedUnfairLock(initialState: false)
    private let _lastActive = OSAllocatedUnfairLock(initialState: false)

    var isEnabled: Bool { _isEnabled.withLock { $0 } }

    init(onSignal: @escaping @Sendable (MeetingSignal) -> Void) {
        self.onSignal = onSignal
    }

    func start() {
        _isEnabled.withLock { $0 = true }
        DetectionLogger.shared.detection("SlackDetector started", platform: .slack)
    }

    func stop() {
        _isEnabled.withLock { $0 = false }
        DetectionLogger.shared.detection("SlackDetector stopped", platform: .slack)
    }

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

        if active != lastActive {
            DetectionLogger.shared.detection(
                "Slack huddle window \(active ? "found" : "gone")",
                platform: .slack, signal: .cgWindowList, active: active
            )
            let signal = MeetingSignal(
                platform: .slack,
                isActive: active,
                confidence: .high,
                source: .cgWindowList,
                timestamp: Date()
            )
            onSignal(signal)
        }
    }
}
