import AppKit
import ApplicationServices
import Foundation

/// Controls MacWhisper recording via cross-process Accessibility API.
/// Requires Accessibility permission in System Settings.
final class MacWhisperController: Sendable {
    private let axQueue = DispatchQueue(label: "com.macwhisperauto.ax-automation")
    private let bundleID = "com.goodsnooze.MacWhisper"
    private let axTimeout: Float = 5.0

    // MARK: - Public API

    /// Start recording for a platform (runs on AX queue).
    func startRecording(
        for platform: Platform,
        completion: @escaping @Sendable (Result<Void, AXError>) -> Void
    ) {
        axQueue.async { [self] in
            let result = performStartRecording(platform: platform)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Manual recording by raw button name (e.g. "Record Chrome", "Record All System Audio").
    func manualRecord(
        buttonName: String,
        completion: @escaping @Sendable (Result<Void, AXError>) -> Void
    ) {
        axQueue.async { [self] in
            let result = performManualRecord(buttonName: buttonName)
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
    /// Returns `.macWhisperNotInstalled` when MacWhisper isn't installed at all,
    /// `.macWhisperNotRunning` when launch was attempted but the app didn't
    /// become accessible within the wait window (transient — caller can retry).
    func launchIfNeeded(completion: @escaping @Sendable (Result<Void, AXError>) -> Void) {
        if findMacWhisperApp() != nil {
            completion(.success(()))
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            DetectionLogger.shared.error(.automation, "MacWhisper not installed")
            completion(.failure(.macWhisperNotInstalled))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [self] _, error in
            if let error {
                DetectionLogger.shared.error(
                    .automation, "Failed to launch MacWhisper: \(error.localizedDescription)"
                )
                completion(.failure(.macWhisperNotRunning))
                return
            }
            // Wait for MacWhisper to become accessible
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if self.findMacWhisperApp() != nil {
                    completion(.success(()))
                } else {
                    completion(.failure(.macWhisperNotRunning))
                }
            }
        }
    }

    /// Launch MacWhisper in background on app startup so it's ready when needed.
    func launchInBackground() {
        launchIfNeeded { result in
            switch result {
            case .success:
                DetectionLogger.shared.automation(
                    "MacWhisper launched at startup", action: "launchBackground"
                )
            case .failure(let error):
                DetectionLogger.shared.error(
                    .automation, "Failed to launch MacWhisper at startup: \(error)"
                )
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
        DetectionLogger.shared.automation(
            "Force quitting MacWhisper for relaunch", action: "forceQuitRelaunch"
        )
        let didQuit = forceQuit()
        if !didQuit {
            DetectionLogger.shared.automation(
                "MacWhisper was not running, launching fresh", action: "forceQuitRelaunch"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            self.launchIfNeeded { result in
                switch result {
                case .success:
                    DetectionLogger.shared.automation(
                        "MacWhisper relaunched successfully", action: "forceQuitRelaunch"
                    )
                    completion(true)
                case .failure(let error):
                    DetectionLogger.shared.error(.automation, "MacWhisper relaunch failed: \(error)")
                    completion(false)
                }
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

    /// Start recording via MacWhisper's status-menu "Record Meeting" submenu.
    /// FaceTime falls through to a window-based fallback because the menu has no FaceTime item.
    private func performStartRecording(platform: Platform) -> Result<Void, AXError> {
        switch createAppElement() {
        case .failure(let error):
            return .failure(error)
        case .success(let appElement):
            if let menuTitle = platform.macWhisperMenuTitle {
                return performStartRecordingViaMenu(
                    appElement: appElement, menuTitle: menuTitle, platform: platform
                )
            }
            return performStartFaceTimeRecording(appElement: appElement)
        }
    }

    /// Navigate the status-menu extra → "Record Meeting" submenu → <platform> item.
    private func performStartRecordingViaMenu(
        appElement: AXUIElement, menuTitle: String, platform: Platform
    ) -> Result<Void, AXError> {
        guard let extras: AXUIElement =
                AccessibilityHelper.attribute(appElement, kAXExtrasMenuBarAttribute) else {
            return .failure(.elementNotFound(description: "MacWhisper menu extra"))
        }
        let items = AccessibilityHelper.arrayAttribute(extras, kAXChildrenAttribute)
        guard let menuExtra = items.first else {
            return .failure(.elementNotFound(description: "MacWhisper menu extra"))
        }

        DetectionLogger.shared.automation(
            "Opening MacWhisper menu extra", action: "startRecording"
        )
        let openErr = AXUIElementPerformAction(menuExtra, kAXPressAction as CFString)
        guard openErr == .success else {
            return .failure(.actionFailed(
                element: "AXMenuExtra", action: "AXPress", code: openErr.rawValue
            ))
        }
        Thread.sleep(forTimeInterval: 0.3)

        guard let recordMeeting = AccessibilityHelper.findMenuItemByFuzzyTitle(
            menuExtra, title: "Record Meeting"
        ) else {
            let seen = AccessibilityHelper.enumerateMenuItemTitles(menuExtra)
            DetectionLogger.shared.error(
                .automation,
                "'Record Meeting' menu item not found. Top-level items: \(seen.joined(separator: ", "))"
            )
            AXUIElementPerformAction(menuExtra, kAXCancelAction as CFString)
            return .failure(.elementNotFound(
                description: "Record Meeting (saw: \(seen.joined(separator: ", ")))"
            ))
        }

        DetectionLogger.shared.automation(
            "Expanding Record Meeting submenu", action: "startRecording"
        )
        let expandErr = AXUIElementPerformAction(recordMeeting, kAXPressAction as CFString)
        guard expandErr == .success else {
            AXUIElementPerformAction(menuExtra, kAXCancelAction as CFString)
            return .failure(.actionFailed(
                element: "AXMenuItem:Record Meeting", action: "AXPress", code: expandErr.rawValue
            ))
        }
        Thread.sleep(forTimeInterval: 0.3)

        guard let platformItem = AccessibilityHelper.findMenuItemByFuzzyTitle(
            recordMeeting, title: menuTitle
        ) else {
            let seen = AccessibilityHelper.enumerateMenuItemTitles(recordMeeting)
            DetectionLogger.shared.error(
                .automation,
                "'\(menuTitle)' menu item not found under Record Meeting. Submenu items: \(seen.joined(separator: ", "))"
            )
            AXUIElementPerformAction(menuExtra, kAXCancelAction as CFString)
            return .failure(.elementNotFound(
                description: "\(menuTitle) (Record Meeting submenu has: \(seen.joined(separator: ", ")))"
            ))
        }

        DetectionLogger.shared.automation(
            "Pressing '\(menuTitle)' menu item", action: "startRecording"
        )
        let result = AccessibilityHelper.press(platformItem)
        switch result {
        case .success:
            DetectionLogger.shared.automation(
                "Recording started for \(platform.displayName)", action: "startRecording"
            )
        case .failure(let error):
            AXUIElementPerformAction(menuExtra, kAXCancelAction as CFString)
            DetectionLogger.shared.error(
                .automation, "Failed to press '\(menuTitle)': \(error)"
            )
        }
        return result
    }

    /// Manual recording by raw button name.
    private func performManualRecord(buttonName: String) -> Result<Void, AXError> {
        switch createAppElement() {
        case .failure(let error):
            return .failure(error)
        case .success(let appElement):
            DetectionLogger.shared.automation(
                "Manual record: looking for '\(buttonName)'", action: "manualRecord"
            )

            let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
            for window in windows {
                if let button = AccessibilityHelper.findByDescription(
                    window, description: buttonName
                ) {
                    DetectionLogger.shared.automation(
                        "Found '\(buttonName)' - pressing", action: "manualRecord"
                    )
                    let result = AccessibilityHelper.press(button)
                    if case .success = result {
                        DetectionLogger.shared.automation(
                            "Manual recording started: \(buttonName)", action: "manualRecord"
                        )
                    }
                    return result
                }
            }
            return .failure(.elementNotFound(description: buttonName))
        }
    }

    /// FaceTime fallback: use "Record All System Audio" or "All System Audio".
    private func performStartFaceTimeRecording(
        appElement: AXUIElement
    ) -> Result<Void, AXError> {
        DetectionLogger.shared.automation(
            "FaceTime: navigating to All System Audio fallback", action: "startRecording"
        )

        let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
        for window in windows {
            if let button = AccessibilityHelper.findByDescription(
                window, description: "Record All System Audio"
            ) {
                let result = AccessibilityHelper.press(button)
                if case .success = result {
                    DetectionLogger.shared.automation(
                        "Recording started for FaceTime (All System Audio)",
                        action: "startRecording"
                    )
                }
                return result
            }
            if let button = AccessibilityHelper.findByDescription(
                window, description: "All System Audio"
            ) {
                let result = AccessibilityHelper.press(button)
                if case .success = result {
                    DetectionLogger.shared.automation(
                        "Recording started for FaceTime (All System Audio)",
                        action: "startRecording"
                    )
                }
                return result
            }
        }
        return .failure(
            .elementNotFound(description: "Record All System Audio / All System Audio")
        )
    }

    /// Stop recording — press "Finish" on an existing finish-recording dialog,
    /// or find the active recording in the sidebar to trigger the dialog first.
    private func performStopRecording() -> Result<Void, AXError> {
        DetectionLogger.shared.automation("Stopping recording", action: "stopRecording")

        switch createAppElement() {
        case .failure(let error):
            return .failure(error)
        case .success(let appElement):
            // Step 1: Check for an existing "Finish Recording" dialog
            if let result = pressFinishDialogButton(appElement) {
                return result
            }

            // Step 2: Find the active recording row in the sidebar and select it
            // to trigger the finish-recording dialog
            let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
            for window in windows {
                if let activeRow = findActiveRecordingRow(window) {
                    DetectionLogger.shared.automation(
                        "Found active recording row, selecting to trigger stop dialog",
                        action: "stopRecording"
                    )
                    // Selecting the row triggers the "Finish Recording?" dialog
                    AXUIElementPerformAction(activeRow, kAXPressAction as CFString)
                    // Give the dialog time to appear
                    Thread.sleep(forTimeInterval: 0.5)

                    if let result = pressFinishDialogButton(appElement) {
                        return result
                    }
                }
            }

            // No dialog and no active recording row — MacWhisper isn't recording.
            // Treat stop as idempotent so the app's state still clears to idle.
            DetectionLogger.shared.automation(
                "No active recording found — treating stop as no-op", action: "stopRecording"
            )
            return .success(())
        }
    }

    /// Find and press the "Finish" button on a finish-recording dialog.
    private func pressFinishDialogButton(_ appElement: AXUIElement) -> Result<Void, AXError>? {
        let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
        for window in windows {
            let subrole: String? = AccessibilityHelper.attribute(window, kAXSubroleAttribute)
            guard subrole == "AXSystemDialog" else { continue }

            if let finishButton = AccessibilityHelper.findByDescription(
                window, description: "Finish"
            ) {
                let result = AccessibilityHelper.press(finishButton)
                switch result {
                case .success:
                    DetectionLogger.shared.automation(
                        "Recording stopped via Finish button", action: "stopRecording"
                    )
                case .failure(let error):
                    DetectionLogger.shared.error(
                        .automation, "Failed to press Finish: \(error)"
                    )
                }
                return result
            }
        }
        return nil
    }

    /// Find the active recording row in the sidebar (the cell containing "Meeting - ..." text).
    private func findActiveRecordingRow(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 15 else { return nil }
        let role: String = AccessibilityHelper.attribute(element, kAXRoleAttribute) ?? ""
        if role == "AXCell" {
            for child in AccessibilityHelper.arrayAttribute(element, kAXChildrenAttribute) {
                let value: String = AccessibilityHelper.attribute(child, kAXValueAttribute) ?? ""
                if value.hasPrefix("Meeting") {
                    return element
                }
            }
        }
        for child in AccessibilityHelper.arrayAttribute(element, kAXChildrenAttribute) {
            if let found = findActiveRecordingRow(child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// Check if recording — look for an active recording row in the sidebar.
    private func performCheckRecording() -> Bool {
        switch createAppElement() {
        case .failure:
            return false
        case .success(let appElement):
            let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
            for window in windows {
                if findActiveRecordingRow(window) != nil {
                    return true
                }
            }
            return false
        }
    }
}
