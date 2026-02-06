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

    var showOnboarding: Bool { !permissionsGranted }

    var isRecording: Bool {
        if case .recording = meetingState { return true }
        return false
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
        case .recording(let platform): "Recording \(platform.displayName)"
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
        default:
            break
        }
    }
}
