import AppKit
import ApplicationServices

@MainActor
final class PermissionManager {

    // MARK: - Checks

    /// Check if Accessibility permission is granted (non-prompting).
    func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Check if Screen Recording permission is granted.
    /// Tests by reading window names from CGWindowListCopyWindowInfo —
    /// without permission, other processes' window titles come back nil.
    func isScreenRecordingGranted() -> Bool {
        let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let pid = ProcessInfo.processInfo.processIdentifier
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID != pid,
                  let name = window[kCGWindowName as String] as? String,
                  !name.isEmpty else { continue }
            return true
        }
        // Finder/menu-bar windows are always on-screen; if none have names,
        // screen recording is not granted. An empty list means no windows at
        // all (unusual), so assume permission is fine.
        return windowList.isEmpty
    }

    /// Return status for every permission the app requires.
    func checkAll() -> [Permission: Bool] {
        [
            .accessibility: isAccessibilityGranted(),
            .screenRecording: isScreenRecordingGranted()
        ]
    }

    // MARK: - Actions

    /// Show the system prompt asking the user to grant Accessibility.
    func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings > Privacy & Security > Accessibility.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings > Privacy & Security > Screen Recording.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
