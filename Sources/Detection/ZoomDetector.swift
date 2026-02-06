import Foundation
import os

/// Detects Zoom meetings by matching window titles via CGWindowList.
/// Looks for "Zoom Meeting" or "Zoom Webinar" windows.
final class ZoomDetector: MeetingDetector, WindowListConsumer, @unchecked Sendable {
    private let onSignal: @Sendable (MeetingSignal) -> Void
    private let _isEnabled = OSAllocatedUnfairLock(initialState: false)
    private let _lastActive = OSAllocatedUnfairLock(initialState: false)

    var isEnabled: Bool { _isEnabled.withLock { $0 } }

    init(onSignal: @escaping @Sendable (MeetingSignal) -> Void) {
        self.onSignal = onSignal
    }

    func start() {
        _isEnabled.withLock { $0 = true }
        DetectionLogger.shared.detection("ZoomDetector started", platform: .zoom)
    }

    func stop() {
        _isEnabled.withLock { $0 = false }
        DetectionLogger.shared.detection("ZoomDetector stopped", platform: .zoom)
    }

    func processWindowList(_ windows: [WindowInfo]) {
        guard isEnabled else { return }

        let active = windows.contains { window in
            window.ownerName == "zoom.us" && (
                window.windowName.contains("Zoom Meeting") ||
                window.windowName.contains("Zoom Webinar")
            )
        }

        let lastActive = _lastActive.withLock { old -> Bool in
            let was = old
            old = active
            return was
        }

        // Only emit on state change to avoid flooding the state machine
        if active != lastActive {
            DetectionLogger.shared.detection(
                "Zoom meeting window \(active ? "found" : "gone")",
                platform: .zoom, signal: .cgWindowList, active: active
            )
            let signal = MeetingSignal(
                platform: .zoom,
                isActive: active,
                confidence: .high,
                source: .cgWindowList,
                timestamp: Date()
            )
            onSignal(signal)
        }
    }
}
