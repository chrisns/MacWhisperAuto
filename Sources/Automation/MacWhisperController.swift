import AppKit
import ApplicationServices
import Foundation

final class MacWhisperController: Sendable {
    private let axQueue = DispatchQueue(label: "com.macwhisperauto.ax-automation")
    private let bundleID = "com.goodsnooze.MacWhisper"
    private let axTimeout: Float = 5.0

    // MARK: - Public API

    /// Start recording for a platform (runs on AX queue).
    func startRecording(for platform: Platform, completion: @escaping @Sendable (Result<Void, AXError>) -> Void) {
        axQueue.async { [self] in
            let result = performStartRecording(platform: platform)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stop recording (runs on AX queue).
    func stopRecording(completion: @escaping @Sendable (Result<Void, AXError>) -> Void) {
        axQueue.async { [self] in
            let result = performStopRecording()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Check if MacWhisper is currently recording.
    func checkRecordingStatus(completion: @escaping @Sendable (Bool) -> Void) {
        axQueue.async { [self] in
            let isRecording = performCheckRecording()
            DispatchQueue.main.async { completion(isRecording) }
        }
    }

    /// Launch MacWhisper if not running (background, no activation).
    func launchIfNeeded(completion: @escaping @Sendable (Bool) -> Void) {
        if findMacWhisperApp() != nil {
            completion(true)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            DetectionLogger.shared.error(.automation, "MacWhisper not installed")
            completion(false)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [self] _, error in
            if let error {
                DetectionLogger.shared.error(.automation, "Failed to launch MacWhisper: \(error.localizedDescription)")
                completion(false)
                return
            }
            // Wait for MacWhisper to become accessible
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                completion(self.findMacWhisperApp() != nil)
            }
        }
    }

    /// Force-quit MacWhisper.
    func forceQuit() -> Bool {
        guard let app = findMacWhisperApp() else { return false }
        return app.forceTerminate()
    }

    /// Force-quit MacWhisper, relaunch, and wait for it to become AX-accessible.
    func forceQuitAndRelaunch(completion: @escaping @Sendable (Bool) -> Void) {
        DetectionLogger.shared.automation("Force quitting MacWhisper for relaunch", action: "forceQuitRelaunch")
        let didQuit = forceQuit()
        if !didQuit {
            DetectionLogger.shared.automation("MacWhisper was not running, launching fresh", action: "forceQuitRelaunch")
        }
        // Wait for process to fully exit before relaunching
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            self.launchIfNeeded { launched in
                if launched {
                    DetectionLogger.shared.automation("MacWhisper relaunched successfully", action: "forceQuitRelaunch")
                } else {
                    DetectionLogger.shared.error(.automation, "MacWhisper relaunch failed")
                }
                completion(launched)
            }
        }
    }

    // MARK: - Private helpers

    private func findMacWhisperApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private func createAppElement() -> Result<AXUIElement, AXError> {
        guard let app = findMacWhisperApp() else {
            return .failure(.macWhisperNotRunning)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, axTimeout)
        return .success(element)
    }

    /// Start recording - find "Record [Platform]" button in MacWhisper windows and press it.
    /// FaceTime uses a fallback path since it isn't a per-app recording target.
    private func performStartRecording(platform: Platform) -> Result<Void, AXError> {
        switch createAppElement() {
        case .failure(let error):
            return .failure(error)
        case .success(let appElement):
            // FaceTime isn't available as a per-app target in MacWhisper.
            // Use "All System Audio" fallback via the App Audio screen.
            if platform == .faceTime {
                return performStartFaceTimeRecording(appElement: appElement)
            }

            let buttonName = platform.macWhisperButtonName
            DetectionLogger.shared.automation("Starting recording: looking for '\(buttonName)'", action: "startRecording")

            let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
            for window in windows {
                if let button = AccessibilityHelper.findByDescription(window, description: buttonName) {
                    DetectionLogger.shared.automation("Found '\(buttonName)' - pressing", action: "startRecording")
                    let result = AccessibilityHelper.press(button)
                    switch result {
                    case .success:
                        DetectionLogger.shared.automation(
                            "Recording started for \(platform.displayName)", action: "startRecording"
                        )
                    case .failure(let error):
                        DetectionLogger.shared.error(.automation, "Failed to press '\(buttonName)': \(error)")
                    }
                    return result
                }
            }
            return .failure(.elementNotFound(description: buttonName))
        }
    }

    /// FaceTime fallback: Navigate through App Audio > All System Audio.
    /// FaceTime isn't a per-app recording target in MacWhisper, so we search for
    /// "Record All System Audio" or "All System Audio" buttons instead.
    private func performStartFaceTimeRecording(appElement: AXUIElement) -> Result<Void, AXError> {
        DetectionLogger.shared.automation(
            "FaceTime: navigating to All System Audio fallback", action: "startRecording"
        )

        let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
        for window in windows {
            // Look for "Record All System Audio" button
            if let button = AccessibilityHelper.findByDescription(window, description: "Record All System Audio") {
                DetectionLogger.shared.automation(
                    "Found 'Record All System Audio' - pressing", action: "startRecording"
                )
                let result = AccessibilityHelper.press(button)
                if case .success = result {
                    DetectionLogger.shared.automation(
                        "Recording started for FaceTime (All System Audio)", action: "startRecording"
                    )
                }
                return result
            }
            // Alternative: look for "All System Audio" button
            if let button = AccessibilityHelper.findByDescription(window, description: "All System Audio") {
                DetectionLogger.shared.automation(
                    "Found 'All System Audio' - pressing", action: "startRecording"
                )
                let result = AccessibilityHelper.press(button)
                if case .success = result {
                    DetectionLogger.shared.automation(
                        "Recording started for FaceTime (All System Audio)", action: "startRecording"
                    )
                }
                return result
            }
        }
        return .failure(.elementNotFound(description: "Record All System Audio / All System Audio"))
    }

    /// Stop recording - find "Stop Recording" in extras menu bar and press it.
    private func performStopRecording() -> Result<Void, AXError> {
        DetectionLogger.shared.automation("Stopping recording", action: "stopRecording")

        switch createAppElement() {
        case .failure(let error):
            return .failure(error)
        case .success(let appElement):
            // Primary: extras menu bar (kAXExtrasMenuBarAttribute = "AXExtrasMenuBar")
            if let extrasMenuBar: AXUIElement = AccessibilityHelper.attribute(
                appElement, "AXExtrasMenuBar"
            ) {
                if let stopItem = AccessibilityHelper.findMenuItemByTitle(
                    extrasMenuBar, title: "Stop Recording"
                ) {
                    let result = AccessibilityHelper.press(stopItem)
                    switch result {
                    case .success:
                        DetectionLogger.shared.automation("Recording stopped", action: "stopRecording")
                    case .failure(let error):
                        DetectionLogger.shared.error(
                            .automation, "Failed to press Stop Recording: \(error)"
                        )
                    }
                    return result
                }
            }
            // Fallback: regular menu bar
            if let menuBar: AXUIElement = AccessibilityHelper.attribute(
                appElement, kAXMenuBarAttribute
            ) {
                if let stopItem = AccessibilityHelper.findMenuItemByTitle(
                    menuBar, title: "Stop Recording"
                ) {
                    return AccessibilityHelper.press(stopItem)
                }
            }
            return .failure(.elementNotFound(description: "Stop Recording"))
        }
    }

    /// Check if recording - look for "Recording ..." menu item in extras menu bar.
    private func performCheckRecording() -> Bool {
        switch createAppElement() {
        case .failure:
            return false
        case .success(let appElement):
            if let extrasMenuBar: AXUIElement = AccessibilityHelper.attribute(
                appElement, "AXExtrasMenuBar"
            ) {
                return AccessibilityHelper.findMenuItemWithTitlePrefix(
                    extrasMenuBar, prefix: "Recording"
                ) != nil
            }
            return false
        }
    }
}
