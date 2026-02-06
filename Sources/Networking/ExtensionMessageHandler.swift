import Foundation

/// Parses browser extension WebSocket messages into MeetingSignals.
/// Handles heartbeats (full state) and individual meeting events.
/// Malformed messages are logged and discarded (NFR14).
final class ExtensionMessageHandler: Sendable {
    let onSignal: @Sendable (MeetingSignal) -> Void
    let onConnectionStateChanged: @Sendable (Bool) -> Void

    init(
        onSignal: @escaping @Sendable (MeetingSignal) -> Void,
        onConnectionStateChanged: @escaping @Sendable (Bool) -> Void
    ) {
        self.onSignal = onSignal
        self.onConnectionStateChanged = onConnectionStateChanged
    }

    /// Process a raw WebSocket message (JSON data).
    func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            DetectionLogger.shared.error(.webSocket, "Malformed WebSocket message (not valid JSON)")
            return
        }

        switch type {
        case "heartbeat":
            handleHeartbeat(json)
        case "meeting_detected":
            handleMeetingEvent(json, isActive: true)
        case "meeting_ended":
            handleMeetingEvent(json, isActive: false)
        default:
            DetectionLogger.shared.webSocket("Unknown message type: \(type)")
        }
    }

    /// Heartbeat reconstructs full state from a single message (FR38).
    private func handleHeartbeat(_ json: [String: Any]) {
        guard let meetings = json["active_meetings"] as? [[String: Any]] else {
            // Heartbeat with no active meetings = all browser meetings ended
            emitSignal(platform: .browser, isActive: false)
            return
        }

        if meetings.isEmpty {
            emitSignal(platform: .browser, isActive: false)
        } else {
            // Emit active signal for browser platform
            // We treat all browser meetings as a single "browser" platform signal
            emitSignal(platform: .browser, isActive: true)
        }

        DetectionLogger.shared.webSocket(
            "Heartbeat: \(meetings.count) active meeting(s)"
        )
    }

    private func handleMeetingEvent(_ json: [String: Any], isActive: Bool) {
        if let url = json["url"] as? String {
            DetectionLogger.shared.webSocket(
                "Meeting \(isActive ? "detected" : "ended"): \(url)"
            )
        }

        emitSignal(platform: .browser, isActive: isActive)
    }

    private func emitSignal(platform: Platform, isActive: Bool) {
        let signal = MeetingSignal(
            platform: platform,
            isActive: isActive,
            confidence: .high,
            source: .webSocket,
            timestamp: Date()
        )
        onSignal(signal)
    }
}
