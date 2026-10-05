import Foundation

enum Platform: String, CaseIterable, Sendable {
    case teams, zoom, slack, faceTime, chime, browser, chrome

    /// Title of the platform's item under MacWhisper's status-menu "Record Meeting" submenu.
    /// `nil` means the platform is not exposed in the menu and must use a window-based fallback.
    var macWhisperMenuTitle: String? {
        switch self {
        case .teams: "Teams"
        case .zoom: "Zoom"
        case .slack: "Slack"
        case .chime: "Chime"
        case .browser: "Comet"
        case .chrome: "Chrome"
        case .faceTime: nil
        }
    }

    var displayName: String {
        switch self {
        case .teams: "Microsoft Teams"
        case .zoom: "Zoom"
        case .slack: "Slack"
        case .faceTime: "FaceTime"
        case .chime: "Amazon Chime"
        case .browser: "Comet"
        case .chrome: "Chrome"
        }
    }

    /// Bundle identifiers for native apps (used by AppMonitor).
    var bundleIdentifiers: [String] {
        switch self {
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        case .zoom: ["us.zoom.xos"]
        case .slack: ["com.tinyspeck.slackmacgap"]
        case .faceTime: ["com.apple.FaceTime"]
        case .chime: ["com.amazon.Amazon-Chime"]
        // Browser detection is via the WebSocket extension, not NSWorkspace.
        // Must stay empty: a bundle ID here would treat any open browser as a meeting.
        case .browser, .chrome: []
        }
    }

    /// Initialize from a bundle identifier, if it matches a known platform.
    static func from(bundleIdentifier: String) -> Platform? {
        for platform in Platform.allCases {
            if platform.bundleIdentifiers.contains(bundleIdentifier) {
                return platform
            }
        }
        return nil
    }

    /// All bundle identifiers across all platforms (for quick set-membership checks).
    static let allBundleIdentifiers: Set<String> = {
        var ids = Set<String>()
        for platform in Platform.allCases {
            ids.formUnion(platform.bundleIdentifiers)
        }
        return ids
    }()
}
