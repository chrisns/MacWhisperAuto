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
    let onExtensionVersionReceived: @Sendable (String) -> Void

    /// Only emit inactive after no connection has reported meetings for this long.
    /// Must exceed the heartbeat interval (~20s) to survive interleaved heartbeats.
    private static let inactiveGracePeriod: TimeInterval = 30.0

    /// Last heartbeat/event with active meetings, and the platform it mapped to.
    /// The inactive signal must name the same platform, because the state
    /// machine ignores an inactive signal from a different platform.
    private struct LastActive {
        var date: Date?
        var platform: Platform = .browser
    }

    /// Thread-safe state of the last heartbeat/event with active meetings.
    private let _lastActive = OSAllocatedUnfairLock<LastActive>(initialState: LastActive())

    /// Pick the platform whose MacWhisper Record item to press for a browser meeting:
    ///   1. `macwhisper_source` from the extension, when a custom URL rule sets it explicitly;
    ///   2. else the browser app that owns the WebSocket connection ("Google Chrome", "Comet");
    ///   3. else Comet, the historical default.
    static func platform(forSource source: String?, browserName: String?) -> Platform {
        for candidate in [source, browserName] {
            guard let name = candidate?.lowercased(), !name.isEmpty else { continue }
            if name.contains("chrome") { return .chrome }
            if name.contains("comet") { return .browser }
        }
        return .browser
    }

    init(
        onSignal: @escaping @Sendable (MeetingSignal) -> Void,
        onConnectionStateChanged: @escaping @Sendable (Bool) -> Void,
        onExtensionVersionReceived: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.onSignal = onSignal
        self.onConnectionStateChanged = onConnectionStateChanged
        self.onExtensionVersionReceived = onExtensionVersionReceived
    }

    /// Process a raw WebSocket message (JSON data). `browserName` is the app that
    /// owns the connection (e.g. "Google Chrome"), when the server could resolve it.
    func handleMessage(_ data: Data, browserName: String? = nil) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            DetectionLogger.shared.error(.webSocket, "Malformed WebSocket message (not valid JSON)")
            return
        }

        switch type {
        case "heartbeat":
            handleHeartbeat(json, browserName: browserName)
        case "meeting_detected":
            handleMeetingEvent(json, isActive: true, browserName: browserName)
        case "meeting_ended":
            handleMeetingEvent(json, isActive: false, browserName: browserName)
        default:
            DetectionLogger.shared.webSocket("Unknown message type: \(type)")
        }
    }

    /// Heartbeat reconstructs full state from a single message (FR38).
    private func handleHeartbeat(_ json: [String: Any], browserName: String?) {
        // Extract extension version from heartbeat
        if let version = json["extension_version"] as? String {
            onExtensionVersionReceived(version)
        }

        guard let meetings = json["active_meetings"] as? [[String: Any]] else {
            emitInactiveIfGracePeriodElapsed()
            return
        }

        DetectionLogger.shared.webSocket(
            "Heartbeat: \(meetings.count) active meeting(s)"
        )

        if let first = meetings.first {
            markActive(Self.platform(
                forSource: first["macwhisper_source"] as? String, browserName: browserName
            ))
        } else {
            emitInactiveIfGracePeriodElapsed()
        }
    }

    private func handleMeetingEvent(_ json: [String: Any], isActive: Bool, browserName: String?) {
        if let url = json["url"] as? String {
            DetectionLogger.shared.webSocket(
                "Meeting \(isActive ? "detected" : "ended"): \(url) (browser: \(browserName ?? "unknown"))"
            )
        }

        if isActive {
            markActive(Self.platform(
                forSource: json["macwhisper_source"] as? String, browserName: browserName
            ))
        } else {
            emitInactiveIfGracePeriodElapsed()
        }
    }

    private func markActive(_ platform: Platform) {
        _lastActive.withLock { $0 = LastActive(date: Date(), platform: platform) }
        emitSignal(platform: platform, isActive: true)
    }

    /// Only emit inactive if no connection has reported active meetings recently.
    private func emitInactiveIfGracePeriodElapsed() {
        let state = _lastActive.withLock { $0 }
        if let lastActive = state.date {
            let elapsed = Date().timeIntervalSince(lastActive)
            if elapsed < Self.inactiveGracePeriod {
                DetectionLogger.shared.webSocket(
                    "Suppressing inactive signal (last active \(Int(elapsed))s ago)"
                )
                return
            }
        }
        emitSignal(platform: state.platform, isActive: false)
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
