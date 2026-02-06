import Foundation
import os

/// Detects Amazon Chime meetings by matching "Amazon Chime: Meeting Controls" window title via CGWindowList.
final class ChimeDetector: MeetingDetector, WindowListConsumer, @unchecked Sendable {
    private let onSignal: @Sendable (MeetingSignal) -> Void
    private let _isEnabled = OSAllocatedUnfairLock(initialState: false)
    private let _lastActive = OSAllocatedUnfairLock(initialState: false)

    var isEnabled: Bool { _isEnabled.withLock { $0 } }

    init(onSignal: @escaping @Sendable (MeetingSignal) -> Void) {
        self.onSignal = onSignal
    }

    func start() {
        _isEnabled.withLock { $0 = true }
        DetectionLogger.shared.detection("ChimeDetector started", platform: .chime)
    }

    func stop() {
        _isEnabled.withLock { $0 = false }
        DetectionLogger.shared.detection("ChimeDetector stopped", platform: .chime)
    }

    func processWindowList(_ windows: [WindowInfo]) {
        guard isEnabled else { return }

        let active = windows.contains { window in
            window.ownerName == "Amazon Chime" &&
            window.windowName == "Amazon Chime: Meeting Controls"
        }

        let lastActive = _lastActive.withLock { old -> Bool in
            let was = old
            old = active
            return was
        }

        if active != lastActive {
            DetectionLogger.shared.detection(
                "Chime meeting window \(active ? "found" : "gone")",
                platform: .chime, signal: .cgWindowList, active: active
            )
            let signal = MeetingSignal(
                platform: .chime,
                isActive: active,
                confidence: .high,
                source: .cgWindowList,
                timestamp: Date()
            )
            onSignal(signal)
        }
    }
}
