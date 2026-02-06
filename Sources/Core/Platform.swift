import Foundation

enum Platform: String, CaseIterable, Sendable {
    case teams, zoom, slack, faceTime, chime, browser

    var macWhisperButtonName: String {
        switch self {
        case .teams: "Record Teams"
        case .zoom: "Record Zoom"
        case .slack: "Record Slack"
        case .faceTime: "Record FaceTime"
        case .chime: "Record Chime"
        case .browser: "Record Comet"
        }
    }

    var displayName: String {
        switch self {
        case .teams: "Microsoft Teams"
        case .zoom: "Zoom"
        case .slack: "Slack"
        case .faceTime: "FaceTime"
        case .chime: "Amazon Chime"
        case .browser: "Browser"
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
        case .browser: [] // browser detection is via WebSocket extension, not NSWorkspace
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
