import Foundation
import os

/// Parses browser extension WebSocket messages into MeetingSignals.
/// Handles heartbeats (full state) and individual meeting events.
/// Malformed messages are logged and discarded (NFR14).
///
/// Multi-connection grace period: When multiple browser profiles connect
/// simultaneously, one may report 0 meetings while another has an active
/// meeting. Inactive signals are suppressed for `inactiveGracePeriod`
/// seconds after the last active meeting was seen from ANY connection.
final class ExtensionMessageHandler: Sendable {
    let onSignal: @Sendable (MeetingSignal) -> Void
    let onConnectionStateChanged: @Sendable (Bool) -> Void

    /// Only emit inactive after no connection has reported meetings for this long.
    /// Must exceed the heartbeat interval (~20s) to survive interleaved heartbeats.
    private static let inactiveGracePeriod: TimeInterval = 30.0

    /// Thread-safe timestamp of last heartbeat/event with active meetings.
    private let _lastActiveMeeting = OSAllocatedUnfairLock<Date?>(initialState: nil)

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
            emitInactiveIfGracePeriodElapsed()
            return
        }

        DetectionLogger.shared.webSocket(
            "Heartbeat: \(meetings.count) active meeting(s)"
        )

        if meetings.isEmpty {
            emitInactiveIfGracePeriodElapsed()
        } else {
            _lastActiveMeeting.withLock { $0 = Date() }
            emitSignal(platform: .browser, isActive: true)
        }
    }

    private func handleMeetingEvent(_ json: [String: Any], isActive: Bool) {
        if let url = json["url"] as? String {
            DetectionLogger.shared.webSocket(
                "Meeting \(isActive ? "detected" : "ended"): \(url)"
            )
        }

        if isActive {
            _lastActiveMeeting.withLock { $0 = Date() }
            emitSignal(platform: .browser, isActive: true)
        } else {
            emitInactiveIfGracePeriodElapsed()
        }
    }

    /// Only emit inactive if no connection has reported active meetings recently.
    private func emitInactiveIfGracePeriodElapsed() {
        let lastActive = _lastActiveMeeting.withLock { $0 }
        if let lastActive {
            let elapsed = Date().timeIntervalSince(lastActive)
            if elapsed < Self.inactiveGracePeriod {
                DetectionLogger.shared.webSocket(
                    "Suppressing inactive signal (last active \(Int(elapsed))s ago)"
                )
                return
            }
        }
        emitSignal(platform: .browser, isActive: false)
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
