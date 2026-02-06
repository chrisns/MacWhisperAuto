import AppKit
import Foundation

/// Tracks which meeting-relevant apps are currently running.
/// Uses NSWorkspace launch/terminate notifications (event-driven, no polling).
/// The CGWindowListScanner uses this to skip polling when no relevant apps are running.
@MainActor
final class AppMonitor {
    private(set) var runningPlatforms: Set<Platform> = []

    var onChange: ((Set<Platform>) -> Void)?

    init() {
        scanRunningApps()
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleAppLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        // Initial scan
        scanRunningApps()
        DetectionLogger.shared.detection(
            "AppMonitor started - running platforms: \(runningPlatforms.map(\.rawValue))"
        )
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Check if any meeting-relevant app is currently running.
    var hasRelevantApps: Bool {
        !runningPlatforms.isEmpty
    }

    // MARK: - Private

    private func scanRunningApps() {
        var platforms = Set<Platform>()
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier,
               let platform = Platform.from(bundleIdentifier: bundleID) {
                platforms.insert(platform)
            }
        }
        let changed = platforms != runningPlatforms
        runningPlatforms = platforms
        if changed {
            onChange?(runningPlatforms)
        }
    }

    @objc private func handleAppLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let platform = Platform.from(bundleIdentifier: bundleID) else { return }

        let inserted = runningPlatforms.insert(platform).inserted
        if inserted {
            DetectionLogger.shared.detection(
                "\(platform.displayName) launched",
                platform: platform, signal: .nsWorkspace, active: true
            )
            onChange?(runningPlatforms)
        }
    }

    @objc private func handleAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let platform = Platform.from(bundleIdentifier: bundleID) else { return }

        let removed = runningPlatforms.remove(platform) != nil
        if removed {
            DetectionLogger.shared.detection(
                "\(platform.displayName) terminated",
                platform: platform, signal: .nsWorkspace, active: false
            )
            onChange?(runningPlatforms)
        }
    }
}
