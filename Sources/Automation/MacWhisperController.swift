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

    /// AXDescription used by per-platform Record buttons in MacWhisper's main
    /// window. These exist regardless of whether MacWhisper's own meeting
    /// detection has fired, so they're our last-resort fallback when the
    /// status-menu extra doesn't expose a Record item.
    private static let windowButtonDescription: [Platform: String] = [
        .teams: "Record Teams",
        .zoom: "Record Zoom",
        .slack: "Record Slack",
        .chime: "Record Chime",
        .browser: "Record Comet"
    ]

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

    /// Start recording. Tries paths in order:
    ///   1. New flat menu-extra item ("Record <Platform> Meeting")
    ///   2. Legacy "Record Meeting > <Platform>" submenu
    ///   3. In-window per-platform Record button (AXDescription "Record <Platform>")
    /// FaceTime has no platform-specific entry — it falls through to a
    /// window-based "Record All System Audio" fallback (in the +FaceTime extension).
    private func performStartRecording(platform: Platform) -> Result<Void, AXError> {
        switch createAppElement() {
        case .failure(let error):
            return .failure(error)
        case .success(let appElement):
            // Pre-check: if MacWhisper is already recording (user started it
            // manually, or a previous attempt succeeded), don't try to start a
            // second recording — that's how we end up with duplicate files.
            if performCheckRecording() {
                DetectionLogger.shared.automation(
                    "MacWhisper is already recording — treating start as no-op",
                    action: "startRecording"
                )
                return .success(())
            }
            if let menuTitle = platform.macWhisperMenuTitle {
                let menuResult = performStartRecordingViaMenu(
                    appElement: appElement, menuTitle: menuTitle, platform: platform
                )
                if case .success = menuResult { return menuResult }

                // Final fallback: in-window "Record <Platform>" button by AXDescription.
                // Exists in MacWhisper's main window regardless of MacWhisper's own
                // meeting detection state, so this catches the case where our
                // detector fired but MacWhisper's didn't.
                if let buttonDesc = Self.windowButtonDescription[platform] {
                    if let result = pressWindowRecordButton(
                        appElement: appElement, description: buttonDesc, platform: platform
                    ) {
                        return result
                    }
                }
                return menuResult
            }
            return performStartFaceTimeRecording(appElement: appElement)
        }
    }

    /// Press the in-window "Record <Platform>" button by AXDescription.
    /// Returns `nil` when the button isn't present (caller should propagate
    /// the upstream error). Returns success/failure when the button was found.
    private func pressWindowRecordButton(
        appElement: AXUIElement, description: String, platform: Platform
    ) -> Result<Void, AXError>? {
        let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
        for window in windows {
            guard let button = AccessibilityHelper.findByDescription(
                window, description: description
            ) else { continue }
            DetectionLogger.shared.automation(
                "Falling back to in-window '\(description)' button", action: "startRecording"
            )
            let result = AccessibilityHelper.press(button)
            if case .success = result {
                DetectionLogger.shared.automation(
                    "Recording started for \(platform.displayName) via window button",
                    action: "startRecording"
                )
            }
            return result
        }
        return nil
    }

    /// Drive the status-menu extra to start recording. MacWhisper has shipped
    /// two layouts for this menu over time:
    ///
    /// 1. **Flat (current)** — a single top-level item "Record <Platform> Meeting"
    ///    (e.g. "Record Teams Meeting") sits directly in the menu extra. Only
    ///    one platform's item shows at a time, picked by MacWhisper's own
    ///    meeting detection.
    /// 2. **Submenu (older)** — a "Record Meeting" item expands to a submenu
    ///    containing per-platform leaves ("Teams", "Zoom", ...).
    ///
    /// Try the flat layout first, fall back to the submenu layout, then log
    /// the items we actually saw so misses are easy to diagnose.
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

        // Layout 1: flat "Record <Platform> Meeting" at the top level.
        // Match "Record " (with trailing space) to avoid hitting "Recording <Platform> Meeting"
        // (which is the status indicator that appears while recording is active).
        let menuTitleLower = menuTitle.lowercased()
        if let item = AccessibilityHelper.findMenuItemMatching(menuExtra, maxDepth: 4) { title in
            let lc = title.lowercased()
            return lc.hasPrefix("record ") && lc.contains(menuTitleLower)
        } {
            let foundTitle: String = AccessibilityHelper.attribute(item, kAXTitleAttribute) ?? ""
            DetectionLogger.shared.automation(
                "Pressing top-level '\(foundTitle)' item", action: "startRecording"
            )
            let result = AccessibilityHelper.press(item)
            if case .success = result {
                DetectionLogger.shared.automation(
                    "Recording started for \(platform.displayName) via '\(foundTitle)'",
                    action: "startRecording"
                )
                return result
            }
            AXUIElementPerformAction(menuExtra, kAXCancelAction as CFString)
            return result
        }

        // Layout 2: legacy "Record Meeting" → <Platform> submenu.
        if let recordMeeting = AccessibilityHelper.findMenuItemByFuzzyTitle(
            menuExtra, title: "Record Meeting"
        ) {
            DetectionLogger.shared.automation(
                "Falling back to legacy Record Meeting submenu", action: "startRecording"
            )
            let expandErr = AXUIElementPerformAction(recordMeeting, kAXPressAction as CFString)
            if expandErr == .success {
                Thread.sleep(forTimeInterval: 0.3)
                if let platformItem = AccessibilityHelper.findMenuItemByFuzzyTitle(
                    recordMeeting, title: menuTitle
                ) {
                    let result = AccessibilityHelper.press(platformItem)
                    if case .success = result {
                        DetectionLogger.shared.automation(
                            "Recording started for \(platform.displayName) (legacy submenu)",
                            action: "startRecording"
                        )
                        return result
                    }
                    AXUIElementPerformAction(menuExtra, kAXCancelAction as CFString)
                    return result
                }
            }
        }

        let seen = AccessibilityHelper.enumerateMenuItemTitles(menuExtra)
        DetectionLogger.shared.error(
            .automation,
            "No 'Record \(menuTitle) Meeting' or 'Record Meeting > \(menuTitle)' found. Menu items: \(seen.joined(separator: ", "))"
        )
        AXUIElementPerformAction(menuExtra, kAXCancelAction as CFString)
        return .failure(.elementNotFound(
            description: "Record \(menuTitle) Meeting (saw: \(seen.joined(separator: ", ")))"
        ))
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

    /// Stop recording. Current MacWhisper exposes a top-level "Stop Recording"
    /// menu item in its status-menu extra — try that first. Older versions
    /// instead surfaced a "Finish Recording" dialog (triggered by clicking the
    /// active recording row in the sidebar), so we keep that path as a fallback.
    private func performStopRecording() -> Result<Void, AXError> {
        DetectionLogger.shared.automation("Stopping recording", action: "stopRecording")

        switch createAppElement() {
        case .failure(let error):
            return .failure(error)
        case .success(let appElement):
            if let result = pressStopRecordingMenuItem(appElement) {
                return result
            }

            // Try in-window "Stop" button (AXDescription "Stop",
            // help="Stop the meeting recording") — present on the recording
            // meta-window in current MacWhisper.
            let windows = AccessibilityHelper.arrayAttribute(appElement, kAXWindowsAttribute)
            for window in windows {
                guard let stopButton = AccessibilityHelper.findByDescription(
                    window, description: "Stop"
                ) else { continue }
                let help: String = AccessibilityHelper.attribute(stopButton, kAXHelpAttribute) ?? ""
                guard help.lowercased().contains("stop") && help.lowercased().contains("recording") else {
                    continue
                }
                DetectionLogger.shared.automation(
                    "Pressing in-window Stop button", action: "stopRecording"
                )
                let result = AccessibilityHelper.press(stopButton)
                if case .success = result {
                    DetectionLogger.shared.automation(
                        "Recording stopped via in-window Stop", action: "stopRecording"
                    )
                    return result
                }
            }

            // Legacy path: existing "Finish Recording" dialog.
            if let result = pressFinishDialogButton(appElement) {
                return result
            }

            // Legacy path: trigger the dialog by selecting the active recording
            // row, then press Finish on the resulting dialog.
            for window in windows {
                if let activeRow = findActiveRecordingRow(window) {
                    DetectionLogger.shared.automation(
                        "Found active recording row, selecting to trigger stop dialog",
                        action: "stopRecording"
                    )
                    AXUIElementPerformAction(activeRow, kAXPressAction as CFString)
                    Thread.sleep(forTimeInterval: 0.5)
                    if let result = pressFinishDialogButton(appElement) {
                        return result
                    }
                }
            }

            // No dialog, no active recording row, no menu item — MacWhisper
            // isn't recording. Treat stop as idempotent so the app's state
            // still clears to idle.
            DetectionLogger.shared.automation(
                "No active recording found — treating stop as no-op", action: "stopRecording"
            )
            return .success(())
        }
    }

    /// Find and press the top-level "Stop Recording" item in MacWhisper's
    /// status-menu extra. Returns `nil` when the item isn't present (caller
    /// should fall through to legacy stop paths).
    private func pressStopRecordingMenuItem(
        _ appElement: AXUIElement
    ) -> Result<Void, AXError>? {
        guard let extras: AXUIElement =
                AccessibilityHelper.attribute(appElement, kAXExtrasMenuBarAttribute),
              let menuExtra = AccessibilityHelper.arrayAttribute(
                extras, kAXChildrenAttribute
              ).first else {
            return nil
        }
        // Passive read first — if "Stop Recording" isn't present, we're not
        // recording (or this MacWhisper version uses the dialog instead).
        guard AccessibilityHelper.findMenuItemByTitle(
            menuExtra, title: "Stop Recording", maxDepth: 4
        ) != nil else {
            return nil
        }
        DetectionLogger.shared.automation(
            "Opening MacWhisper menu extra to press Stop Recording", action: "stopRecording"
        )
        let openErr = AXUIElementPerformAction(menuExtra, kAXPressAction as CFString)
        guard openErr == .success else { return nil }
        Thread.sleep(forTimeInterval: 0.3)
        guard let stopItem = AccessibilityHelper.findMenuItemByTitle(
            menuExtra, title: "Stop Recording"
        ) else {
            AXUIElementPerformAction(menuExtra, kAXCancelAction as CFString)
            return nil
        }
        let result = AccessibilityHelper.press(stopItem)
        if case .success = result {
            DetectionLogger.shared.automation(
                "Recording stopped via menu extra", action: "stopRecording"
            )
        }
        return result
    }

    /// Check if MacWhisper is currently recording. Prefers a passive read of
    /// the status-menu extra (no menu open required — no menu-bar flash) and
    /// falls back to scanning the sidebar.
    ///
    /// In the current MacWhisper, the menu extra contains either a
    /// "Recording <Platform> Meeting" indicator + a "Stop Recording" action
    /// when recording is active, or "Record <Platform> Meeting" when idle.
    private func performCheckRecording() -> Bool {
        switch createAppElement() {
        case .failure:
            return false
        case .success(let appElement):
            // Passive menu-extra read — does not require opening the menu.
            if let extras: AXUIElement =
                    AccessibilityHelper.attribute(appElement, kAXExtrasMenuBarAttribute),
               let menuExtra = AccessibilityHelper.arrayAttribute(
                    extras, kAXChildrenAttribute
               ).first {
                let recordingItem = AccessibilityHelper.findMenuItemMatching(
                    menuExtra, maxDepth: 4
                ) { title in
                    if title == "Stop Recording" { return true }
                    return title.lowercased().hasPrefix("recording ")
                }
                if recordingItem != nil { return true }
            }

            // Fallback: sidebar scan (legacy MacWhisper layout).
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
