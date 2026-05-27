import Foundation
import SwiftUI

@Observable
@MainActor
final class AppState {
    var meetingState: MeetingState = .idle
    var currentPlatform: Platform?
    var recentActivity: [ActivityEntry] = []
    var permissionsGranted: Bool = false
    var extensionConnected: Bool = false

    /// Whether MacWhisper itself currently shows an active recording row in its
    /// sidebar. Populated by the 2s polling loop in AppDelegate. Distinct from
    /// `meetingState == .recording`, which reflects *intent* (we've sent or are
    /// retrying the start command).
    var macWhisperObservedRecording: Bool = false

    /// When set, MacWhisper's "Record Meeting" submenu does not contain a menu
    /// item matching the platform's expected title (subtle rename detected).
    /// Surface via the status bar alert overlay and a popover warning row.
    var macWhisperMenuItemMissing: Platform?

    // Version tracking
    let appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    var extensionVersion: String?
    var latestReleaseVersion: String?

    var appUpdateAvailable: Bool {
        guard let latest = latestReleaseVersion else { return false }
        return latest.compare(appVersion, options: .numeric) == .orderedDescending
    }

    var extensionVersionMismatch: Bool {
        guard let extVer = extensionVersion else { return false }
        return extVer != appVersion
    }

    var showOnboarding: Bool { !permissionsGranted }

    /// True only when both *intent* is recording AND MacWhisper's sidebar
    /// confirms an active recording row. Prevents the UI from claiming
    /// "Recording" while the AX start command is still retrying.
    var isRecording: Bool {
        guard case .recording = meetingState else { return false }
        return macWhisperObservedRecording
    }

    /// Intent says we should be recording, but MacWhisper hasn't confirmed yet.
    var isStartingRecording: Bool {
        guard case .recording = meetingState else { return false }
        return !macWhisperObservedRecording
    }

    var isDetecting: Bool {
        if case .detecting = meetingState { return true }
        return false
    }

    var isError: Bool {
        if case .error = meetingState { return true }
        return false
    }

    var activePlatform: Platform? {
        switch meetingState {
        case .detecting(let p, _), .recording(let p): p
        default: nil
        }
    }

    var statusDescription: String {
        switch meetingState {
        case .idle: "Idle - No meeting detected"
        case .detecting(let platform, _): "Detecting \(platform.displayName)..."
        case .recording(let platform):
            macWhisperObservedRecording
                ? "Recording \(platform.displayName)"
                : "Starting \(platform.displayName)..."
        case .error(let kind): "Error: \(kind.userDescription)"
        }
    }

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let platform: Platform?
    }

    func addActivity(_ message: String, platform: Platform? = nil) {
        let entry = ActivityEntry(timestamp: Date(), message: message, platform: platform)
        recentActivity.insert(entry, at: 0)
        if recentActivity.count > 50 {
            recentActivity = Array(recentActivity.prefix(50))
        }
    }

    func updateState(_ newState: MeetingState) {
        meetingState = newState
        switch newState {
        case .recording(let platform):
            currentPlatform = platform
        case .idle:
            currentPlatform = nil
            // Drop stale observation when we leave any recording intent.
            macWhisperObservedRecording = false
        case .error:
            macWhisperObservedRecording = false
        default:
            break
        }
    }
}
